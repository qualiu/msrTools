"""Tests for the GitHub TOTP command without accessing real credentials."""

from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor
from contextlib import redirect_stderr, redirect_stdout
import errno
import io
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import totp
import totp_store as store


SECRET_A = "JBSWY3DPEHPK3PXP"
SECRET_B = "MFRGGZDFMZTWQ2LK"
RFC_6238_SECRET = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"


def github_uri(account: str, secret: str = SECRET_A) -> str:
    return (
        f"otpauth://totp/GitHub%3A{account}?secret={secret}&issuer=GitHub"
        "&algorithm=SHA1&digits=6&period=30"
    )


class FakeKeyringError(Exception):
    pass


class FakeKeyring:
    def __init__(self) -> None:
        self.credentials: dict[tuple[str, str], str] = {}

    def get_password(self, service: str, username: str) -> str | None:
        return self.credentials.get((service, username))

    def set_password(self, service: str, username: str, password: str) -> None:
        self.credentials[(service, username)] = password

    def delete_password(self, service: str, username: str) -> None:
        del self.credentials[(service, username)]


class GitHubTotpTests(unittest.TestCase):
    def setUp(self) -> None:
        self.lock_directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.lock_directory.cleanup)
        self.lock_path = Path(self.lock_directory.name) / "store.lock"
        self.lock_path_patch = mock.patch.object(
            store,
            "_lock_file_path",
            return_value=self.lock_path,
        )
        self.lock_path_patch.start()
        self.addCleanup(self.lock_path_patch.stop)
        self.keyring = FakeKeyring()
        self.keyring_patch = mock.patch.object(
            store,
            "_load_keyring",
            return_value=(self.keyring, FakeKeyringError),
        )
        self.keyring_patch.start()
        self.addCleanup(self.keyring_patch.stop)

    def invoke(self, *arguments: str) -> tuple[int, str, str]:
        stdout = io.StringIO()
        stderr = io.StringIO()
        with (
            mock.patch.object(sys, "argv", ["totp.py", *arguments]),
            mock.patch.object(totp.time, "perf_counter", side_effect=[10.0, 10.125]),
            mock.patch.object(totp, "wait_for_safe_window"),
            redirect_stdout(stdout),
            redirect_stderr(stderr),
        ):
            try:
                result = totp.main()
            except SystemExit as error:
                result = error.code
        return result, stdout.getvalue(), stderr.getvalue()

    def enroll_record(
        self,
        profile: str,
        account: str,
        secret: str = SECRET_A,
        replace: bool = False,
    ) -> None:
        record = totp.parse_enrollment(secret, expected_account=account)
        totp.write_registered_record(profile, record, replace=replace)

    def test_profile_names_are_normalized_and_namespaced(self) -> None:
        self.assertEqual(store.normalize_profile(" Work_1 "), "work_1")
        self.assertEqual(
            store.credential_name_for_profile("Work_1"),
            "github.com/profile/work_1",
        )
        with self.assertRaisesRegex(totp.ToolError, "Profile name"):
            store.normalize_profile("bad/profile")

    def test_setup_key_is_canonicalized(self) -> None:
        self.assertEqual(totp.normalize_secret("jbsw-y3dp ehpk3pxp="), SECRET_A)
        with self.assertRaisesRegex(totp.ToolError, "valid Base32"):
            totp.normalize_secret("not-a-base32-key!")

    def test_rfc_6238_sha1_vector_is_used(self) -> None:
        self.assertEqual(
            totp.generate_code_from_setup_key(RFC_6238_SECRET, timestamp=59),
            "287082",
        )

    def test_bare_key_requires_explicit_account(self) -> None:
        with self.assertRaisesRegex(totp.ToolError, "add --account"):
            totp.parse_enrollment(SECRET_A)
        record = totp.parse_enrollment(SECRET_A, expected_account="Octocat")
        self.assertEqual(record["account"], "Octocat")
        self.assertEqual(record["issuer"], "GitHub")

    def test_uri_supplies_account_and_enforces_github_parameters(self) -> None:
        record = totp.parse_enrollment(github_uri("Octocat"))
        self.assertEqual(record["account"], "Octocat")
        with self.assertRaisesRegex(totp.ToolError, "selected GitHub account"):
            totp.parse_enrollment(
                github_uri("Octocat"), expected_account="DifferentUser"
            )
        with self.assertRaisesRegex(totp.ToolError, "issuer is not GitHub"):
            totp.parse_enrollment(
                github_uri("Octocat").replace("issuer=GitHub", "issuer=Example")
            )

    def test_direct_setup_key_enrollment_is_stored_and_registered(self) -> None:
        result, stdout, stderr = self.invoke(
            "enroll",
            "--name",
            "Work",
            "--account",
            "Octocat",
            "--setup-key",
            SECRET_A,
        )

        self.assertEqual(result, 0)
        self.assertIn("profile=work account=Octocat", stdout)
        self.assertIn("WARNING: --setup-key", stderr)
        self.assertIn("ELAPSED: 0.125 s", stderr)
        self.assertNotIn(SECRET_A, stdout + stderr)

        payload = self.keyring.credentials[
            (store.SERVICE_NAME, "github.com/profile/work")
        ]
        self.assertEqual(json.loads(payload)["secret"], SECRET_A)
        registry_payloads = [
            value
            for (service, name), value in self.keyring.credentials.items()
            if service == store.SERVICE_NAME
            and name.startswith(store.PROFILE_REGISTRY_PREFIX)
        ]
        self.assertEqual(registry_payloads, ['{"profile":"work","version":1}'])
        self.assertNotIn(SECRET_A, "".join(registry_payloads))

    def test_decoded_uri_can_be_enrolled_from_stdin(self) -> None:
        with mock.patch.object(sys, "stdin", io.StringIO(github_uri("Octocat"))):
            result, stdout, _stderr = self.invoke(
                "enroll", "--name", "personal", "--stdin"
            )
        self.assertEqual(result, 0)
        self.assertIn("account=Octocat", stdout)

    def test_malformed_uri_is_a_safe_cli_error(self) -> None:
        for uri in ("otpauth://[", f"otpauth://[?secret={SECRET_A}"):
            with self.subTest(uri=uri):
                with mock.patch.object(sys, "stdin", io.StringIO(uri)):
                    result, stdout, stderr = self.invoke("enroll", "--stdin")
                self.assertEqual(result, 1)
                self.assertEqual(stdout, "")
                self.assertIn("ERROR: otpauth URI is malformed", stderr)
                self.assertNotIn("Traceback", stderr)
                self.assertNotIn(SECRET_A, stderr)
                self.assertEqual(self.keyring.credentials, {})

    def test_hidden_prompt_rejects_echo_fallback(self) -> None:
        input_stream = io.StringIO(SECRET_A)
        with (
            mock.patch.object(sys, "stdin", input_stream),
            mock.patch.object(input_stream, "isatty", return_value=True),
            mock.patch.object(
                totp.getpass, "getpass", side_effect=totp.getpass.fallback_getpass
            ),
        ):
            result, stdout, stderr = self.invoke("enroll", "--account", "Octocat")
        self.assertEqual(result, 1)
        self.assertEqual(stdout, "")
        self.assertIn("ERROR: Unable to hide enrollment input", stderr)
        self.assertNotIn(SECRET_A, stderr)
        self.assertEqual(input_stream.tell(), 0)
        self.assertEqual(self.keyring.credentials, {})

    def test_hidden_prompt_accepts_hidden_input_and_handles_eof(self) -> None:
        with mock.patch.object(sys.stdin, "isatty", return_value=True):
            with mock.patch.object(totp.getpass, "getpass", return_value=SECRET_A):
                self.assertEqual(totp.read_enrollment_input(False), SECRET_A)
            with mock.patch.object(totp.getpass, "getpass", side_effect=EOFError):
                result, stdout, stderr = self.invoke(
                    "enroll", "--account", "Octocat"
                )
        self.assertEqual(result, 1)
        self.assertEqual(stdout, "")
        self.assertIn("ERROR: Enrollment input ended", stderr)
        self.assertEqual(self.keyring.credentials, {})

    def test_concurrent_writers_cannot_overwrite_a_new_profile(self) -> None:
        original = totp.parse_enrollment(SECRET_A, expected_account="Octocat")
        replacement = totp.parse_enrollment(SECRET_B, expected_account="DifferentUser")
        for writer, replace in (
            (totp.write_record, False),
            (totp.write_record, True),
            (totp.write_registered_record, False),
            (totp.write_registered_record, True),
        ):
            with self.subTest(writer=writer.__name__, replace=replace):
                profile = f"{writer.__name__}-{replace}".casefold()
                first_read = threading.Event()
                second_read = threading.Event()
                release_first = threading.Event()
                original_get = self.keyring.get_password
                credential_name = store.credential_name_for_profile(profile)

                def gated_get(service: str, username: str) -> str | None:
                    payload = original_get(service, username)
                    if username == credential_name:
                        if not first_read.is_set():
                            first_read.set()
                            if not release_first.wait(5):
                                raise AssertionError("First credential reader stalled")
                        else:
                            second_read.set()
                    return payload

                with (
                    mock.patch.object(
                        self.keyring, "get_password", side_effect=gated_get
                    ),
                    ThreadPoolExecutor(max_workers=2) as executor,
                ):
                    first = executor.submit(writer, profile, original, False)
                    try:
                        self.assertTrue(first_read.wait(5))
                        second = executor.submit(
                            writer, profile, replacement, replace
                        )
                        self.assertFalse(second_read.wait(0.1))
                    finally:
                        release_first.set()
                    first.result(timeout=5)
                    message = "Refusing to change" if replace else "already configured"
                    with self.assertRaisesRegex(totp.ToolError, message):
                        second.result(timeout=5)
                self.assertEqual(totp.read_record(profile)["account"], "Octocat")
                self.assertEqual(totp.read_record(profile)["secret"], SECRET_A)

    def test_concurrent_profile_registrations_keep_both_markers(self) -> None:
        first_scan = threading.Event()
        second_scan = threading.Event()
        release_first = threading.Event()
        original_scan = store._read_profile_registry

        def gated_scan(keyring, keyring_error):
            snapshot = original_scan(keyring, keyring_error)
            if not first_scan.is_set():
                first_scan.set()
                if not release_first.wait(5):
                    raise AssertionError("First registry scan stalled")
            else:
                second_scan.set()
            return snapshot

        with (
            mock.patch.object(store, "_read_profile_registry", side_effect=gated_scan),
            ThreadPoolExecutor(max_workers=2) as executor,
        ):
            first = executor.submit(store.register_profile, "personal")
            try:
                self.assertTrue(first_scan.wait(5))
                second = executor.submit(store.register_profile, "work")
                self.assertFalse(second_scan.wait(0.1))
            finally:
                release_first.set()
            self.assertTrue(first.result(timeout=5))
            self.assertTrue(second.result(timeout=5))
        self.assertEqual(store.registered_profiles(), ["default", "personal", "work"])

    def test_delete_cannot_unregister_a_concurrent_reenrollment(self) -> None:
        self.enroll_record("work", "Octocat")
        seed_deleted = threading.Event()
        enrollment_read = threading.Event()
        release_delete = threading.Event()
        original_delete = store.delete_payload
        original_read = store.read_payload

        def paused_delete(profile: str) -> bool:
            removed = original_delete(profile)
            seed_deleted.set()
            if not release_delete.wait(5):
                raise AssertionError("Seed deletion stalled")
            return removed

        def tracked_read(profile: str) -> str | None:
            enrollment_read.set()
            return original_read(profile)

        with (
            mock.patch.object(store, "delete_payload", side_effect=paused_delete),
            mock.patch.object(store, "read_payload", side_effect=tracked_read),
            redirect_stdout(io.StringIO()),
            ThreadPoolExecutor(max_workers=2) as executor,
        ):
            deletion = executor.submit(
                totp.command_delete, argparse.Namespace(profile="work", yes=True)
            )
            try:
                self.assertTrue(seed_deleted.wait(5))
                enrollment = executor.submit(
                    self.enroll_record, "work", "DifferentUser", SECRET_B
                )
                self.assertFalse(enrollment_read.wait(0.1))
            finally:
                release_delete.set()
            self.assertEqual(deletion.result(timeout=5), 0)
            enrollment.result(timeout=5)
        self.assertEqual(totp.read_record("work")["account"], "DifferentUser")
        self.assertEqual(store.registered_profiles(), ["default", "work"])

    def test_registry_failure_keeps_seed_and_releases_lock_for_repair(self) -> None:
        with mock.patch.object(
            store, "register_profile", side_effect=totp.ToolError("Registry unavailable")
        ):
            with self.assertRaisesRegex(totp.ToolError, "was saved, but registry"):
                self.enroll_record("work", "Octocat")
        self.assertEqual(totp.read_record("work")["secret"], SECRET_A)
        self.assertEqual(store.registered_profiles(), ["default"])
        result, stdout, _stderr = self.invoke("register", "--name", "work")
        self.assertEqual(result, 0)
        self.assertIn("account=Octocat registered", stdout)
        self.assertEqual(store.registered_profiles(), ["default", "work"])

    def test_storage_lock_errors_do_not_write_credentials(self) -> None:
        with mock.patch.object(
            store, "_set_file_lock", side_effect=OSError(errno.EIO, "I/O failure")
        ):
            with self.assertRaisesRegex(totp.ToolError, "Unable to acquire"):
                self.enroll_record("work", "Octocat")
        self.assertEqual(self.keyring.credentials, {})
        blocking_file = Path(self.lock_directory.name) / "not-a-directory"
        blocking_file.write_text("fixture", encoding="ascii")
        with mock.patch.object(
            store, "_lock_file_path", return_value=blocking_file / "store.lock"
        ):
            with self.assertRaisesRegex(totp.ToolError, "Unable to open"):
                self.enroll_record("work", "Octocat")
        self.assertEqual(self.keyring.credentials, {})
        self.enroll_record("work", "Octocat")

    def test_storage_lock_is_nested_and_thread_wait_is_bounded(self) -> None:
        with mock.patch.object(store, "STORE_LOCK_TIMEOUT_SECONDS", 0.05):
            with store.storage_transaction():
                with store.storage_transaction():
                    with ThreadPoolExecutor(max_workers=1) as executor:
                        enrollment = executor.submit(
                            self.enroll_record, "work", "Octocat"
                        )
                        with self.assertRaisesRegex(totp.ToolError, "Timed out"):
                            enrollment.result(timeout=5)
        self.assertEqual(self.keyring.credentials, {})
        with self.assertRaisesRegex(ValueError, "fixture failure"):
            with store.storage_transaction():
                with store.storage_transaction():
                    raise ValueError("fixture failure")
        self.enroll_record("work", "Octocat")

    def start_lock_holder(self, mode: str) -> subprocess.Popen[str]:
        ready_path = Path(self.lock_directory.name) / f"ready-{mode}"
        child_code = """
from pathlib import Path
import sys
sys.path.insert(0, sys.argv[1])
import totp_store as store
store._lock_file_path = lambda: Path(sys.argv[2])
with store.storage_transaction():
    Path(sys.argv[3]).write_text("ready", encoding="ascii")
    sys.stdin.readline()
"""
        process = subprocess.Popen(
            [
                sys.executable, "-B", "-c", child_code,
                str(Path(store.__file__).resolve().parent),
                str(self.lock_path), str(ready_path),
            ],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        )
        self.addCleanup(self.cleanup_lock_holder, process)
        deadline = time.monotonic() + 5
        while not ready_path.exists():
            if process.poll() is not None:
                self.fail(f"Lock holder exited: {process.communicate(timeout=5)}")
            if time.monotonic() >= deadline:
                self.fail("Lock holder did not become ready")
            time.sleep(0.01)
        return process

    def cleanup_lock_holder(self, process: subprocess.Popen[str]) -> None:
        if process.poll() is None:
            process.kill()
            process.communicate(timeout=5)
        for stream in (process.stdin, process.stdout, process.stderr):
            if stream is not None:
                stream.close()

    def test_storage_lock_blocks_processes_and_releases_after_exit(self) -> None:
        for mode in ("normal", "terminated"):
            with self.subTest(mode=mode):
                process = self.start_lock_holder(mode)
                with mock.patch.object(store, "STORE_LOCK_TIMEOUT_SECONDS", 0.1):
                    with self.assertRaisesRegex(totp.ToolError, "Timed out"):
                        self.enroll_record("work", "Octocat")
                self.assertEqual(self.keyring.credentials, {})
                if mode == "normal":
                    stdout, stderr = process.communicate(input="\n", timeout=5)
                    self.assertEqual(process.returncode, 0)
                else:
                    process.terminate()
                    stdout, stderr = process.communicate(timeout=5)
                self.assertEqual((stdout, stderr), ("", ""))
                with store.storage_transaction():
                    pass
                self.assertEqual(self.lock_path.read_bytes(), b"\0")

    def test_qr_import_uses_decoded_uri_without_exposing_it(self) -> None:
        uri = github_uri("Octocat")
        with mock.patch.object(totp, "decode_qr_image", return_value=uri):
            result, stdout, stderr = self.invoke(
                "import-qr", "--name", "personal", "unused.png"
            )
        self.assertEqual(result, 0)
        self.assertIn("profile=personal account=Octocat", stdout)
        self.assertNotIn(uri, stdout + stderr)

    def test_existing_profile_requires_replace(self) -> None:
        self.enroll_record("work", "Octocat")
        replacement = totp.parse_enrollment(SECRET_B, expected_account="Octocat")
        with self.assertRaisesRegex(totp.ToolError, "already configured"):
            totp.write_registered_record("work", replacement, replace=False)

    def test_replace_allows_same_account(self) -> None:
        self.enroll_record("work", "Octocat")
        self.enroll_record("work", "octocat", secret=SECRET_B, replace=True)
        self.assertEqual(totp.read_record("work")["secret"], SECRET_B)

    def test_replace_rejects_different_account(self) -> None:
        self.enroll_record("work", "Octocat")
        replacement = totp.parse_enrollment(SECRET_B, expected_account="DifferentUser")
        with self.assertRaisesRegex(totp.ToolError, "Refusing to change"):
            totp.write_registered_record("work", replacement, replace=True)
        self.assertEqual(totp.read_record("work")["account"], "Octocat")
        self.assertEqual(totp.read_record("work")["secret"], SECRET_A)

    def test_default_profile_is_used_when_now_has_no_selector(self) -> None:
        self.enroll_record("default", "Octocat")
        with mock.patch.object(totp, "generate_code", return_value="123456"):
            result, stdout, stderr = self.invoke("now")
        self.assertEqual(result, 0)
        self.assertEqual(stdout, "123456\n")
        self.assertEqual(stderr, "ELAPSED: 0.125 s\n")

    def test_named_profile_now_writes_only_code_to_stdout(self) -> None:
        self.enroll_record("work", "Octocat")
        with mock.patch.object(totp, "generate_code", return_value="234567"):
            result, stdout, stderr = self.invoke("now", "--name", "work")
        self.assertEqual(result, 0)
        self.assertEqual(stdout, "234567\n")
        self.assertEqual(stderr, "ELAPSED: 0.125 s\n")

    def test_now_all_maps_profiles_on_stderr_and_codes_on_stdout(self) -> None:
        self.enroll_record("default", "DefaultUser")
        self.enroll_record("work", "WorkUser", secret=SECRET_B)

        def code_for_record(record: dict[str, object], _timestamp: int) -> str:
            return "111111" if record["account"] == "DefaultUser" else "222222"

        with (
            mock.patch.object(totp, "generate_code", side_effect=code_for_record),
            mock.patch.object(totp.time, "time", return_value=1_700_000_000),
        ):
            result, stdout, stderr = self.invoke("now", "--all")
        self.assertEqual(result, 0)
        self.assertEqual(stdout, "111111\n222222\n")
        self.assertIn("TOTP[1]: profile=default account=DefaultUser", stderr)
        self.assertIn("TOTP[2]: profile=work account=WorkUser", stderr)
        self.assertTrue(stderr.endswith("ELAPSED: 0.125 s\n"))

    def test_one_time_setup_key_is_not_saved(self) -> None:
        with mock.patch.object(
            totp, "generate_code_from_setup_key", return_value="345678"
        ):
            result, stdout, stderr = self.invoke("now", "--setup-key", SECRET_A)
        self.assertEqual(result, 0)
        self.assertEqual(stdout, "345678\n")
        self.assertIn("this calculation does not save it", stderr)
        self.assertNotIn(SECRET_A, stderr)
        self.assertEqual(self.keyring.credentials, {})

    def test_clipboard_receives_only_generated_code(self) -> None:
        self.enroll_record("default", "Octocat")
        with (
            mock.patch.object(totp, "generate_code", return_value="456789"),
            mock.patch.object(totp, "copy_totp_codes_to_clipboard") as copy,
        ):
            result, stdout, stderr = self.invoke("now", "--copy")
        self.assertEqual(result, 0)
        self.assertEqual(stdout, "456789\n")
        copy.assert_called_once_with(["456789"])
        self.assertIn("clipboard history or sync may retain", stderr)

    def test_profiles_lists_accounts_without_codes(self) -> None:
        self.enroll_record("work", "Octocat")
        result, stdout, stderr = self.invoke("profiles")
        self.assertEqual(result, 0)
        self.assertEqual(stdout, "CONFIGURED: profile=work account=Octocat\n")
        self.assertFalse(re.search(r"\b\d{6}\b", stdout))
        self.assertEqual(stderr, "ELAPSED: 0.125 s\n")

    def test_delete_removes_seed_and_registry(self) -> None:
        self.enroll_record("work", "Octocat")
        result, stdout, _stderr = self.invoke("delete", "--name", "work", "--yes")
        self.assertEqual(result, 0)
        self.assertIn("profile=work removed", stdout)
        self.assertIsNone(store.read_payload("work"))
        self.assertEqual(store.registered_profiles(), ["default"])

    def test_error_is_on_stderr_and_includes_elapsed_time(self) -> None:
        result, stdout, stderr = self.invoke("now", "--name", "missing")
        self.assertEqual(result, 1)
        self.assertEqual(stdout, "")
        self.assertIn("ERROR: GitHub TOTP profile 'missing'", stderr)
        self.assertTrue(stderr.endswith("ELAPSED: 0.125 s\n"))

    def test_missing_profile_error_offers_saved_and_temporary_paths(self) -> None:
        for arguments, profile in (((), "default"), (("--name", "missing"), "missing")):
            with self.subTest(profile=profile):
                result, stdout, stderr = self.invoke("now", *arguments)
                self.assertEqual(result, 1)
                self.assertEqual(stdout, "")
                self.assertIn(f"profile '{profile}' is not configured", stderr)
                self.assertIn(f"enroll --name {profile} --account GITHUB_LOGIN", stderr)
                self.assertIn(f"import-qr --name {profile} IMAGE", stderr)
                self.assertIn("now --setup-key BASE32_SETUP_KEY", stderr)
                self.assertIn("process listings and shell history", stderr)
                self.assertIn("profiles", stderr)
                self.assertIn("now --name PROFILE", stderr)

    def test_missing_metadata_commands_explain_enrollment_and_discovery(self) -> None:
        for arguments in (
            ("status", "--name", "missing"),
            ("register", "--name", "missing"),
            ("profiles",),
            ("now", "--all"),
        ):
            with self.subTest(arguments=arguments):
                result, stdout, stderr = self.invoke(*arguments)
                self.assertEqual(result, 1)
                self.assertIn("enroll --name", stderr)
                self.assertIn("import-qr --name", stderr)
                if arguments[0] == "now":
                    self.assertEqual(stdout, "")
                    self.assertIn("register --name PROFILE", stderr)
                    self.assertIn("now --setup-key", stderr)
                    self.assertIn("Do not combine --all and --setup-key", stderr)
                if arguments[0] == "register":
                    self.assertIn("does not import or recover a seed", stderr)
                if arguments[0] == "profiles":
                    self.assertIn("not an inventory", stderr)

    def test_stale_registration_offers_restoration_before_removal(self) -> None:
        store.register_profile("stale")
        result, stdout, stderr = self.invoke("now", "--all")
        self.assertEqual(result, 1)
        self.assertEqual(stdout, "")
        self.assertIn("restore each missing seed", stderr)
        self.assertIn("delete --name PROFILE --yes", stderr)
        self.assertIn("No codes were emitted", stderr)
        result, stdout, stderr = self.invoke("profiles")
        self.assertEqual(result, 1)
        self.assertIn("profile=stale", stdout)
        self.assertIn("restore its seed", stderr)
        self.assertIn("delete --name stale --yes", stderr)

    def test_delete_confirmation_includes_selected_profile_and_preserves_seed(self) -> None:
        self.enroll_record("work", "Octocat")
        result, stdout, stderr = self.invoke("delete", "--name", "work")
        self.assertEqual(result, 1)
        self.assertEqual(stdout, "")
        self.assertIn("delete --name work --yes", stderr)
        self.assertIn("does not disable GitHub 2FA", stderr)
        self.assertEqual(totp.read_record("work")["secret"], SECRET_A)

    def test_existing_profile_error_suggests_using_it_before_replacing(self) -> None:
        self.enroll_record("work", "Octocat")
        result, stdout, stderr = self.invoke(
            "enroll", "--name", "work", "--account", "Octocat", "--setup-key", SECRET_B
        )
        self.assertEqual(result, 1)
        self.assertEqual(stdout, "")
        self.assertIn("now --name work", stderr)
        self.assertIn("--replace only", stderr)
        self.assertNotIn(SECRET_B, stderr)
        self.assertEqual(totp.read_record("work")["secret"], SECRET_A)

    def test_corrupt_record_errors_name_the_profile_without_printing_payload(self) -> None:
        record = totp.parse_enrollment(SECRET_A, expected_account="Octocat")
        for payload in (
            f"invalid-json:{SECRET_A}",
            json.dumps({**record, "digits": 7}),
            json.dumps({**record, "secret": ""}),
        ):
            with self.subTest(payload_kind="json" if payload.startswith("{") else "text"):
                self.keyring.credentials[
                    (store.SERVICE_NAME, store.credential_name_for_profile("broken"))
                ] = payload
                result, stdout, stderr = self.invoke("now", "--name", "broken")
                self.assertEqual(result, 1)
                self.assertEqual(stdout, "")
                self.assertIn("Stored GitHub TOTP profile 'broken'", stderr)
                self.assertIn("verify the original credential", stderr)
                self.assertNotIn(SECRET_A, stderr)

    def test_setup_key_errors_explain_secret_text_without_echoing_it(self) -> None:
        for value in (github_uri("Octocat"), "123456", "", "A" * 7):
            with self.subTest(input_kind="uri" if value.startswith("otpauth") else "text"):
                result, stdout, stderr = self.invoke("now", "--setup-key", value)
                self.assertEqual(result, 1)
                self.assertEqual(stdout, "")
                self.assertIn("setup key", stderr)
                self.assertNotIn(SECRET_A, stderr)
                self.assertNotIn("Traceback", stderr)
        result, _stdout, stderr = self.invoke("now", "--setup-key", github_uri("Octocat"))
        self.assertEqual(result, 1)
        self.assertIn("Base32", stderr)
        self.assertIn("use enroll", stderr)

    def test_usage_errors_hide_secret_values_and_keep_actionable_details(self) -> None:
        for arguments, detail in (
            ((), "required: command"),
            ((SECRET_A,), "unknown command"),
            (("now", SECRET_A), "unrecognized argument"),
            (("now", "--secret", SECRET_A), "unrecognized argument"),
            (("enroll", "--s", SECRET_A), "ambiguous option"),
            (("enroll", "--s=" + SECRET_A), "ambiguous option"),
            (("now", "--all=" + SECRET_A), "does not take a value"),
            (("now", "--copy=" + SECRET_A), "does not take a value"),
            (("--help=" + github_uri("Octocat"),), "does not take a value"),
            (("now", "--setup-key", SECRET_A, "--all"), "not allowed with argument"),
            (("enroll", "--setup-key", SECRET_A, "--stdin"), "not allowed with argument"),
            (("now", "--setup-key"), "expected one argument"),
            (("now", "--name", "bad/profile"), "Profile name"),
            (("import-qr",), "required: image"),
        ):
            with self.subTest(detail=detail, argument_count=len(arguments)):
                result, stdout, stderr = self.invoke(*arguments)
                self.assertEqual(result, 2)
                self.assertEqual(stdout, "")
                self.assertIn(detail, stderr)
                self.assertIn("--help' for usage and examples", stderr)
                self.assertNotIn(SECRET_A, stderr)
                self.assertNotIn("Traceback", stderr)
        self.assertEqual(self.keyring.credentials, {})

    def test_short_help_does_not_echo_attached_text_or_access_storage(self) -> None:
        result, stdout, stderr = self.invoke("now", "-h" + SECRET_A)
        self.assertEqual(result, 0)
        self.assertIn("Examples:", stdout)
        self.assertNotIn(SECRET_A, stdout + stderr)
        self.assertEqual(self.keyring.credentials, {})

    def test_all_command_help_has_examples_and_does_not_load_credentials(self) -> None:
        for command, expected in (
            (None, ("setup key (secret/seed)", "No command exports", "Exit status:")),
            ("enroll", ("input hidden", "--account", "--stdin", "Base32")),
            ("import-qr", ("No image is uploaded", "25 MiB", "decoded URI")),
            ("status", ("not a live GitHub", "metadata", "return 1")),
            ("now", ("without saving", "mutually exclusive", "stdout", "stderr")),
            ("profiles", ("not an inventory", "stale", "register")),
            ("register", ("does not import", "recover", "already-stored")),
            ("delete", ("does not disable GitHub 2FA", "cannot be undone", "--yes")),
        ):
            with self.subTest(command=command), mock.patch.object(
                store, "_load_keyring", side_effect=AssertionError("Help accessed credentials")
            ):
                arguments = (command, "--help") if command else ("--help",)
                result, stdout, stderr = self.invoke(*arguments)
                self.assertEqual(result, 0)
                normalized = " ".join(stdout.split())
                self.assertIn("Examples", normalized)
                for fragment in expected:
                    self.assertIn(fragment.casefold(), normalized.casefold())
                self.assertEqual(stderr, "ELAPSED: 0.125 s\n")
        self.assertEqual(self.keyring.credentials, {})

    def test_existing_unambiguous_option_abbreviations_still_work(self) -> None:
        with mock.patch.object(
            totp, "generate_code_from_setup_key", return_value="345678"
        ):
            result, stdout, stderr = self.invoke("now", "--setup", SECRET_A)
        self.assertEqual(result, 0)
        self.assertEqual(stdout, "345678\n")
        self.assertNotIn(SECRET_A, stderr)
        self.assertEqual(self.keyring.credentials, {})

    def test_help_layout_is_stable_across_terminal_widths_and_help_aliases(self) -> None:
        for command in (None, "enroll", "import-qr", "status", "now", "profiles", "register", "delete"):
            baseline = None
            for columns in (24, 40, 80, 240):
                for flag in ("-h", "--help"):
                    with (
                        self.subTest(command=command, columns=columns, flag=flag),
                        mock.patch.dict(os.environ, {"COLUMNS": str(columns)}),
                        mock.patch.object(store, "_load_keyring", side_effect=AssertionError("Help accessed credentials")),
                    ):
                        arguments = (command, flag) if command else (flag,)
                        result, stdout, stderr = self.invoke(*arguments)
                        self.assertEqual(result, 0)
                        self.assertEqual(stderr, "ELAPSED: 0.125 s\n")
                        if baseline is None:
                            baseline = stdout
                        self.assertEqual(stdout, baseline)

    def test_help_preserves_semantic_lines_and_description_width(self) -> None:
        parser = totp.build_parser()
        subparsers = next(action for action in parser._actions if isinstance(action, argparse._SubParsersAction))
        sentences = {
            "root": "The now command can also calculate from --setup-key without saving it or requiring --account.",
            "enroll": "Save a GitHub TOTP seed in Windows Credential Manager and register its local profile.",
            "import-qr": "Decode one local QR image on this machine, validate its GitHub TOTP URI and save/register the selected profile.",
            "status": "Validate a saved profile and its TOTP parameters, printing only local profile/account metadata.",
            "now": "With no selector, use the saved default profile; --name selects a saved profile.",
            "profiles": "List the configured default profile and registered named profiles with account metadata only.",
            "register": "Register an already-stored named profile so profiles and now --all can discover it.",
            "delete": "Remove only the selected profile's local seed and registry markers after explicit --yes confirmation.",
        }
        for command, command_parser in {"root": parser, **subparsers.choices}.items():
            with self.subTest(command=command):
                rendered_lines = command_parser.format_help().splitlines()
                self.assertIn(sentences[command], rendered_lines)
                self.assertLessEqual(max(map(len, rendered_lines)), 212)
                texts = [command_parser.description, command_parser.epilog]
                actions = list(command_parser._actions)
                for action in command_parser._actions:
                    actions.extend(getattr(action, "_choices_actions", ()))
                texts.extend(action.help for action in actions)
                for text in texts:
                    if not text or text == argparse.SUPPRESS:
                        continue
                    for semantic_line in text.splitlines():
                        self.assertLessEqual(len(semantic_line), 180)
                        if semantic_line.strip():
                            self.assertTrue(any(semantic_line in line for line in rendered_lines), semantic_line)
                for action in actions:
                    if not action.help or action.help == argparse.SUPPRESS:
                        continue
                    fragments = action.help.splitlines()
                    positions = [next(line.index(fragment) for line in rendered_lines if line.endswith(fragment)) for fragment in fragments]
                    self.assertEqual(len(set(positions)), 1)

    def test_qr_input_error_does_not_echo_a_decoded_uri(self) -> None:
        with mock.patch.dict(sys.modules, {"PIL": mock.Mock(), "zxingcpp": mock.Mock()}):
            result, stdout, stderr = self.invoke("import-qr", github_uri("Octocat"))
        self.assertEqual(result, 1)
        self.assertEqual(stdout, "")
        self.assertIn("local image", stderr)
        self.assertNotIn(SECRET_A, stderr)
        self.assertIn("enroll", stderr)

    def test_registry_diagnostics_distinguish_capacity_and_corruption(self) -> None:
        with mock.patch.object(store, "MAX_REGISTERED_PROFILES", 0):
            with self.assertRaisesRegex(totp.ToolError, "local seed is no longer needed"):
                store.register_profile("work")
        self.keyring.credentials[(store.SERVICE_NAME, store.registry_credential_name(0))] = (
            f"malformed:{SECRET_A}"
        )
        result, stdout, stderr = self.invoke("now", "--all")
        self.assertEqual(result, 1)
        self.assertEqual(stdout, "")
        self.assertIn("profile registry slot 0 is invalid", stderr)
        self.assertIn("register cannot repair malformed markers", stderr)
        self.assertIn("do not delete seed records blindly", stderr)
        self.assertNotIn(SECRET_A, stderr)

    def test_qr_path_failures_are_safe_runtime_errors(self) -> None:
        for failure in (OSError(SECRET_A), ValueError(SECRET_A)):
            with (
                self.subTest(error_type=type(failure).__name__),
                mock.patch.dict(sys.modules, {"PIL": mock.Mock(), "zxingcpp": mock.Mock()}),
                mock.patch.object(totp, "Path", side_effect=failure),
            ):
                result, stdout, stderr = self.invoke("import-qr", "fixture.png")
                self.assertEqual(result, 1)
                self.assertEqual(stdout, "")
                self.assertIn("check the local path and file permissions", stderr)
                self.assertNotIn(SECRET_A, stderr)
                self.assertNotIn("Traceback", stderr)

    def test_clipboard_failure_suggests_printing_without_copying(self) -> None:
        with mock.patch.dict(totp.os.environ, {"SystemRoot": ""}):
            result, stdout, stderr = self.invoke(
                "now", "--setup-key", SECRET_A, "--clipboard"
            )
        self.assertEqual(result, 1)
        self.assertEqual(stdout, "")
        self.assertIn("omit --clipboard/--copy", stderr)
        self.assertIn("print codes without copying", stderr)
        self.assertNotIn(SECRET_A, stderr)


if __name__ == "__main__":
    unittest.main()
