#!/usr/bin/env python3
"""Generate six-digit GitHub TOTP codes from saved profiles or setup key text.

A setup key (secret/seed) is Base32 text, not a password or a six-digit code.
Saved-profile commands require Windows Credential Manager.
The now command can also calculate from --setup-key without saving it or requiring --account.
No command exports a stored setup key or disables GitHub 2FA.
"""

from __future__ import annotations

import argparse
import base64
import getpass
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time
from typing import Any
from urllib.parse import parse_qs, unquote, urlparse
import warnings

import totp_store as store


ToolError = store.StoreError
DEFAULT_PROFILE = store.DEFAULT_PROFILE
EXPECTED_ISSUER = "GitHub"
EXPECTED_DIGITS = 6
EXPECTED_PERIOD = 30
EXPECTED_ALGORITHM = "SHA1"
RECORD_VERSION = 1
SAFE_WINDOW_SECONDS = 5
MAX_ENROLLMENT_INPUT_LENGTH = 4096
MAX_QR_IMAGE_BYTES = 25 * 1024 * 1024
MAX_ACCOUNT_LENGTH = 100
HELP_TEXT_WIDTH = 180
HELP_COLUMN = 32
ONE_TIME_KEY_HINT = (
    "For a code without saving a seed, run "
    "'python github/totp.py now --setup-key BASE32_SETUP_KEY' "
    "(WARNING: the key may be visible in process listings and shell history)."
)


class SemanticHelpFormatter(argparse.RawTextHelpFormatter):
    """Preserve authored sentences, clauses and examples independently of terminal width."""

    def __init__(self, prog: str) -> None:
        super().__init__(prog, width=HELP_COLUMN + HELP_TEXT_WIDTH, max_help_position=HELP_COLUMN)


class SafeArgumentParser(argparse.ArgumentParser):
    """Keep argument errors actionable without echoing setup keys or QR payloads."""

    def __init__(self, *args, **kwargs):
        kwargs.setdefault("formatter_class", SemanticHelpFormatter)
        super().__init__(*args, **kwargs)

    def error(self, message: str) -> None:
        if message.startswith("unrecognized arguments:"):
            message = (
                "unrecognized argument(s); use exact option names. A setup key "
                "must follow --setup-key on enroll or now, not be a positional argument"
            )
        elif message.startswith("argument command: invalid choice:"):
            message = (
                "unknown command; choose a command listed by --help. To calculate "
                "from a setup key, use now --setup-key BASE32_SETUP_KEY"
            )
        elif message.startswith("ambiguous option:"):
            message = "ambiguous option; use the full option name or an alias listed by --help"
        elif "ignored explicit argument" in message:
            message = f"{message.partition(': ')[0]}: this flag does not take a value"
        super().error(
            f"{message}\nRun 'python github/{self.prog} --help' for usage and examples."
        )


def enrollment_hint(profile: str) -> str:
    return (
        "To save a seed with hidden input, run "
        f"'python github/totp.py enroll --name {profile} --account GITHUB_LOGIN'.\n"
        "To import a local QR image, run "
        f"'python github/totp.py import-qr --name {profile} IMAGE'."
    )


def normalize_account(raw: str) -> str:
    """Validate a GitHub login without accepting terminal control characters."""
    account = str(raw or "").strip()
    if not account:
        raise ToolError("GitHub account is empty")
    if len(account) > MAX_ACCOUNT_LENGTH or not re.fullmatch(
        r"[A-Za-z0-9][A-Za-z0-9-]*", account
    ):
        raise ToolError(
            "GitHub account must contain only letters, digits or '-' and start "
            f"with a letter or digit (maximum {MAX_ACCOUNT_LENGTH} characters)"
        )
    return account


def _load_pyotp():
    try:
        import pyotp
    except ImportError as error:
        raise ToolError(
            "Missing dependency 'pyotp'; install with: python -m pip install "
            "-r github/requirements.txt"
        ) from error
    return pyotp


def _single_query_value(
    params: dict[str, list[str]], name: str, default: str | None = None
) -> str | None:
    values = params.get(name, [])
    if len(values) > 1:
        raise ToolError(f"otpauth URI contains multiple {name} values")
    if not values:
        return default
    value = values[0].strip()
    if not value:
        raise ToolError(f"otpauth URI contains an empty {name} value")
    return value


def normalize_secret(raw: str) -> str:
    """Validate and return a canonical, unpadded Base32 seed."""
    secret = re.sub(r"[\s-]+", "", str(raw or "")).rstrip("=").upper()
    if not secret:
        raise ToolError("TOTP setup key is empty; paste the complete Base32 secret text")
    if not re.fullmatch(r"[A-Z2-7]+", secret):
        raise ToolError(
            "TOTP setup key is not valid Base32; use the secret text containing "
            "A-Z and 2-7, not a password, recovery code, or six-digit code. "
            "To import an otpauth URI, use enroll with hidden input or --stdin"
        )
    try:
        decoded = base64.b32decode(secret + "=" * ((-len(secret)) % 8), casefold=False)
    except Exception as error:
        raise ToolError(
            "TOTP setup key is not valid Base32; paste the complete original setup key"
        ) from error
    if len(decoded) < 10:
        raise ToolError(
            "TOTP setup key is unexpectedly short; paste the complete original "
            "setup key, not a six-digit code"
        )
    return secret


def parse_enrollment(value: str, expected_account: str | None = None) -> dict[str, Any]:
    """Validate a GitHub setup key or otpauth URI without logging it."""
    raw = str(value or "").strip()
    if not raw:
        raise ToolError("Enrollment input is empty; provide a setup key or otpauth URI")
    if len(raw) > MAX_ENROLLMENT_INPUT_LENGTH:
        raise ToolError(
            f"Enrollment input exceeds {MAX_ENROLLMENT_INPUT_LENGTH} characters; "
            "supply only one setup key or otpauth URI"
        )

    if not raw.casefold().startswith("otpauth://"):
        if expected_account is None:
            raise ToolError(
                "A bare setup key has no account metadata; add --account GITHUB_LOGIN "
                "with the actual GitHub login, not the local profile name"
            )
        account = normalize_account(expected_account)
        return {
            "version": RECORD_VERSION,
            "issuer": EXPECTED_ISSUER,
            "account": account,
            "digits": EXPECTED_DIGITS,
            "period": EXPECTED_PERIOD,
            "algorithm": EXPECTED_ALGORITHM,
            "secret": normalize_secret(raw),
        }

    try:
        parsed = urlparse(raw)
    except ValueError as error:
        raise ToolError(
            "otpauth URI is malformed; copy the complete decoded GitHub TOTP URI"
        ) from error
    if parsed.scheme.casefold() != "otpauth" or parsed.netloc.casefold() != "totp":
        raise ToolError(
            "Enrollment input is not an otpauth://totp URI; use a complete GitHub "
            "TOTP URI, or supply a bare setup key with --account GITHUB_LOGIN"
        )

    params = parse_qs(parsed.query, keep_blank_values=True)
    secret_value = _single_query_value(params, "secret")
    if secret_value is None:
        raise ToolError("otpauth URI does not contain a TOTP setup key")

    digits_value = _single_query_value(params, "digits", str(EXPECTED_DIGITS))
    period_value = _single_query_value(params, "period", str(EXPECTED_PERIOD))
    algorithm_value = _single_query_value(params, "algorithm", EXPECTED_ALGORITHM)
    try:
        digits = int(digits_value)
        period = int(period_value)
    except (TypeError, ValueError) as error:
        raise ToolError("otpauth URI has invalid digits or period") from error
    algorithm = str(algorithm_value).replace("-", "").upper()
    if (digits, period, algorithm) != (
        EXPECTED_DIGITS,
        EXPECTED_PERIOD,
        EXPECTED_ALGORITHM,
    ):
        raise ToolError(
            "Only GitHub-compatible 6-digit, SHA-1, 30-second TOTP is allowed"
        )

    label = unquote(parsed.path.lstrip("/")).strip()
    if not label:
        raise ToolError("otpauth URI does not contain an account label")
    if ":" in label:
        label_issuer, label_account = label.rsplit(":", 1)
    else:
        label_issuer, label_account = "", label
    label_issuer = label_issuer.strip()
    label_account = normalize_account(label_account)

    query_issuer = _single_query_value(params, "issuer")
    if query_issuer and query_issuer.casefold() != EXPECTED_ISSUER.casefold():
        raise ToolError("otpauth URI issuer is not GitHub")
    if label_issuer and label_issuer.casefold() != EXPECTED_ISSUER.casefold():
        raise ToolError("otpauth URI label issuer is not GitHub")
    if not query_issuer and not label_issuer:
        raise ToolError("otpauth URI does not identify GitHub as the issuer")
    if (
        expected_account is not None
        and label_account.casefold() != normalize_account(expected_account).casefold()
    ):
        raise ToolError(
            "otpauth URI account does not match the selected GitHub account"
        )

    return {
        "version": RECORD_VERSION,
        "issuer": EXPECTED_ISSUER,
        "account": label_account,
        "digits": digits,
        "period": period,
        "algorithm": algorithm,
        "secret": normalize_secret(secret_value),
    }


def validate_record(record: Any, expected_account: str | None = None) -> dict[str, Any]:
    """Validate a decrypted credential record before using its seed."""
    if not isinstance(record, dict):
        raise ToolError("Stored GitHub TOTP credential has an invalid format")
    expected = {
        "version": RECORD_VERSION,
        "issuer": EXPECTED_ISSUER,
        "digits": EXPECTED_DIGITS,
        "period": EXPECTED_PERIOD,
        "algorithm": EXPECTED_ALGORITHM,
    }
    for name, expected_value in expected.items():
        if record.get(name) != expected_value:
            raise ToolError(f"Stored GitHub TOTP credential has invalid {name}")
    try:
        account = normalize_account(str(record.get("account", "")))
    except ToolError as error:
        raise ToolError("Stored GitHub TOTP credential has invalid account") from error
    if (
        expected_account
        and account.casefold() != normalize_account(expected_account).casefold()
    ):
        raise ToolError("Stored GitHub TOTP credential has invalid account")
    secret = normalize_secret(str(record.get("secret", "")))
    return {**expected, "account": account, "secret": secret}


def read_record(profile: str) -> dict[str, Any] | None:
    profile = store.normalize_profile(profile)
    payload = store.read_payload(profile)
    if payload is None:
        return None
    try:
        record = json.loads(payload)
    except (TypeError, json.JSONDecodeError) as error:
        raise ToolError(
            f"Stored GitHub TOTP profile '{profile}' is not valid JSON; verify the "
            "original credential before explicitly deleting or re-enrolling"
        ) from error
    try:
        return validate_record(record)
    except ToolError as error:
        raise ToolError(
            f"Stored GitHub TOTP profile '{profile}' is invalid: {error}; verify "
            "the original credential before explicitly deleting or re-enrolling"
        ) from error


def write_record(profile: str, record: dict[str, Any], replace: bool) -> None:
    profile = store.normalize_profile(profile)
    validated = validate_record(record)
    with store.storage_transaction():
        existing = store.read_payload(profile)
        if existing is not None and not replace:
            raise ToolError(
                f"GitHub TOTP profile '{profile}' is already configured; run "
                f"'python github/totp.py now --name {profile}' to use it. Use "
                "--replace only while GitHub is displaying a newly generated setup key"
            )
        if existing is not None:
            try:
                existing_record = validate_record(json.loads(existing))
            except (TypeError, json.JSONDecodeError, ToolError) as error:
                raise ToolError(
                    f"Stored GitHub TOTP profile '{profile}' cannot be safely "
                    "replaced; delete it explicitly before enrolling again"
                ) from error
            if existing_record["account"].casefold() != validated["account"].casefold():
                raise ToolError(
                    f"Refusing to change GitHub TOTP profile '{profile}' from account "
                    f"{existing_record['account']} to {validated['account']}; use a "
                    "different --name, or delete the old profile explicitly before "
                    "repurposing it"
                )
        payload = json.dumps(validated, separators=(",", ":"), sort_keys=True)
        store.write_payload(profile, payload)


def write_registered_record(
    profile: str, record: dict[str, Any], replace: bool
) -> None:
    """Save a seed and make the selected profile discoverable by --all."""
    profile = store.normalize_profile(profile)
    with store.storage_transaction():
        write_record(profile, record, replace=replace)
        try:
            store.register_profile(profile)
        except ToolError as error:
            raise ToolError(
                f"GitHub TOTP profile '{profile}' was saved, but registry update "
                f"failed; run 'python github/totp.py register --name {profile}': {error}"
            ) from error


def decode_qr_image(image_path: str) -> str:
    """Decode exactly one local QR image without printing its payload."""
    try:
        from PIL import Image
        import zxingcpp
    except ImportError as error:
        raise ToolError(
            "QR import requires Pillow and zxing-cpp; install with: python -m "
            "pip install -r github/requirements.txt"
        ) from error

    try:
        path = Path(image_path).expanduser().resolve()
        if not path.is_file():
            raise ToolError(
                "QR image must be an existing local image file; pass its path to "
                "import-qr. For decoded URI text, use enroll with hidden input or --stdin"
            )
        if path.stat().st_size > MAX_QR_IMAGE_BYTES:
            raise ToolError("QR image exceeds 25 MiB; provide a smaller local image")
    except (OSError, ValueError) as error:
        raise ToolError(
            "QR image path could not be read; check the local path and file permissions"
        ) from error
    try:
        with Image.open(path) as image:
            results = [
                result for result in zxingcpp.read_barcodes(image) if result.text
            ]
    except OSError as error:
        raise ToolError(
            "QR image could not be opened; use a readable, supported image such as PNG/JPEG"
        ) from error
    if not results:
        raise ToolError(
            "QR image contains no readable QR code; use a clear image of the full GitHub QR"
        )
    if len(results) > 1:
        raise ToolError(
            "QR image contains multiple codes; provide an image with exactly one readable QR code"
        )
    return results[0].text


def build_totp(record: dict[str, Any]):
    pyotp = _load_pyotp()
    return pyotp.TOTP(
        record["secret"],
        digits=record["digits"],
        interval=record["period"],
        digest=hashlib.sha1,
    )


def generate_code(record: dict[str, Any], timestamp: int | None = None) -> str:
    totp = build_totp(record)
    code = totp.now() if timestamp is None else totp.at(timestamp)
    if not re.fullmatch(r"\d{6}", code):
        raise ToolError("GitHub TOTP did not generate a six-digit code")
    return code


def generate_code_from_setup_key(setup_key: str, timestamp: int | None = None) -> str:
    """Generate a GitHub-compatible code without storing the supplied seed."""
    record = {
        "secret": normalize_secret(setup_key),
        "digits": EXPECTED_DIGITS,
        "period": EXPECTED_PERIOD,
    }
    return generate_code(record, timestamp=timestamp)


def copy_totp_codes_to_clipboard(codes: list[str]) -> None:
    """Copy only TOTP codes through stdin to the Windows clipboard utility."""
    if os.name != "nt":
        raise ToolError(
            "--clipboard requires Windows; omit --clipboard/--copy to print codes without copying"
        )
    system_root = os.environ.get("SystemRoot")
    if not system_root:
        raise ToolError(
            "Unable to locate the Windows clipboard utility; omit --clipboard/--copy "
            "to print codes without copying"
        )
    clip_executable = Path(system_root) / "System32" / "clip.exe"
    if not clip_executable.is_file():
        raise ToolError(
            "Unable to locate the Windows clipboard utility; omit --clipboard/--copy "
            "to print codes without copying"
        )
    payload = "\r\n".join(codes)
    try:
        result = subprocess.run(
            [str(clip_executable)],
            input=payload,
            encoding="ascii",
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            check=False,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        )
    except OSError as error:
        raise ToolError(
            "Unable to copy TOTP code to the Windows clipboard; retry without "
            "--clipboard/--copy to print codes without copying"
        ) from error
    if result.returncode != 0:
        raise ToolError(
            "Unable to copy TOTP code to the Windows clipboard; retry without "
            "--clipboard/--copy to print codes without copying"
        )


def emit_totp_codes(codes: list[str], copy_to_clipboard: bool = False) -> None:
    """Write only codes to stdout and all supporting information elsewhere."""
    if not codes or any(not re.fullmatch(r"\d{6}", code) for code in codes):
        raise ToolError("Refusing to emit invalid TOTP output")
    if copy_to_clipboard:
        copy_totp_codes_to_clipboard(codes)
        noun = "code" if len(codes) == 1 else "codes"
        print(
            f"WARNING: copied {len(codes)} TOTP {noun} to the Windows clipboard; "
            "clipboard history or sync may retain them",
            file=sys.stderr,
        )
    for code in codes:
        print(code, file=sys.stdout)


def wait_for_safe_window(period: int) -> None:
    remaining = period - int(time.time()) % period
    if remaining <= SAFE_WINDOW_SECONDS:
        time.sleep(remaining + 1)


def read_enrollment_input(
    from_stdin: bool, setup_key_argument: str | None = None
) -> str:
    """Read an enrollment payload from one explicitly selected input source."""
    if setup_key_argument is not None:
        if from_stdin:
            raise ToolError("Choose either --setup-key or stdin enrollment, not both")
        if len(setup_key_argument) > MAX_ENROLLMENT_INPUT_LENGTH:
            raise ToolError(
                f"Enrollment input exceeds {MAX_ENROLLMENT_INPUT_LENGTH} characters; "
                "supply only one setup key"
            )
        return normalize_secret(setup_key_argument)

    if from_stdin:
        if sys.stdin.isatty():
            raise ToolError(
                "stdin enrollment requires redirected input; omit --stdin for a "
                "hidden prompt"
            )
        value = sys.stdin.read(MAX_ENROLLMENT_INPUT_LENGTH + 1)
        if len(value) > MAX_ENROLLMENT_INPUT_LENGTH:
            raise ToolError(
                f"Enrollment input exceeds {MAX_ENROLLMENT_INPUT_LENGTH} characters; "
                "supply only one setup key or otpauth URI"
            )
        return value.lstrip("\ufeff")

    if not sys.stdin.isatty():
        raise ToolError(
            "enroll requires an interactive terminal or explicit --setup-key or "
            "--stdin input; --stdin requires redirected setup key or URI text, "
            "while --setup-key may expose the key in process listings and shell history"
        )
    try:
        with warnings.catch_warnings():
            warnings.simplefilter("error", getpass.GetPassWarning)
            return getpass.getpass(
                "Paste GitHub setup key or otpauth URI (input hidden): "
            )
    except getpass.GetPassWarning as error:
        raise ToolError(
            "Unable to hide enrollment input; use an interactive terminal with "
            "hidden input support or explicit --stdin"
        ) from error
    except EOFError as error:
        raise ToolError("Enrollment input ended before a setup key was read") from error


def command_enroll(args: argparse.Namespace) -> int:
    expected_account = (
        normalize_account(args.account) if args.account is not None else None
    )
    if args.setup_key is not None:
        print(
            "WARNING: --setup-key exposes the TOTP seed to process listings and "
            "shell history; prefer the hidden enroll prompt",
            file=sys.stderr,
        )
    value = read_enrollment_input(args.stdin, args.setup_key)
    record = parse_enrollment(value, expected_account=expected_account)
    write_registered_record(args.profile, record, replace=args.replace)
    print(
        f"OK: GitHub TOTP profile={args.profile} account={record['account']} saved "
        "in Windows Credential Manager; run "
        f"'python github/totp.py now --name {args.profile}' to generate a code"
    )
    return 0


def command_import_qr(args: argparse.Namespace) -> int:
    expected_account = (
        normalize_account(args.account) if args.account is not None else None
    )
    record = parse_enrollment(
        decode_qr_image(args.image), expected_account=expected_account
    )
    write_registered_record(args.profile, record, replace=args.replace)
    print(
        f"OK: GitHub QR for profile={args.profile} account={record['account']} was "
        "validated and saved in Windows Credential Manager; protect or delete "
        "the QR image"
    )
    return 0


def command_status(args: argparse.Namespace) -> int:
    record = read_record(args.profile)
    if record is None:
        print(f"MISSING: GitHub TOTP profile={args.profile} is not configured")
        print(enrollment_hint(args.profile), file=sys.stderr)
        return 1
    generate_code(record)
    print(
        f"CONFIGURED: profile={args.profile} issuer=GitHub "
        f"account={record['account']} storage=Windows-Credential-Manager"
    )
    return 0


def command_now(args: argparse.Namespace) -> int:
    copy_to_clipboard = bool(getattr(args, "clipboard", False))
    if getattr(args, "all", False):
        return command_now_all(copy_to_clipboard=copy_to_clipboard)
    setup_key_argument = getattr(args, "setup_key", None)
    if setup_key_argument is not None:
        print(
            "WARNING: --setup-key exposes the TOTP seed to process listings and "
            "shell history; this calculation does not save it",
            file=sys.stderr,
        )
        setup_key = normalize_secret(setup_key_argument)
        wait_for_safe_window(EXPECTED_PERIOD)
        emit_totp_codes(
            [generate_code_from_setup_key(setup_key)],
            copy_to_clipboard=copy_to_clipboard,
        )
        return 0

    profile = args.profile or DEFAULT_PROFILE
    record = read_record(profile)
    if record is None:
        raise ToolError(
            f"GitHub TOTP profile '{profile}' is not configured.\n"
            f"{enrollment_hint(profile)}\n{ONE_TIME_KEY_HINT}\n"
            "For an existing named profile, run 'python github/totp.py profiles', "
            "then 'python github/totp.py now --name PROFILE'. No seed is exported."
        )
    wait_for_safe_window(record["period"])
    emit_totp_codes([generate_code(record)], copy_to_clipboard=copy_to_clipboard)
    return 0


def command_now_all(copy_to_clipboard: bool = False) -> int:
    records: list[tuple[str, dict[str, Any]]] = []
    stale_profiles: list[str] = []
    for profile in store.registered_profiles():
        record = read_record(profile)
        if record is None:
            if profile != DEFAULT_PROFILE:
                stale_profiles.append(profile)
            continue
        records.append((profile, record))
    if stale_profiles:
        names = ", ".join(stale_profiles)
        raise ToolError(
            f"Registered profile(s) have no stored credential: {names}; restore "
            "each missing seed with enroll or import-qr using the same --name, "
            "or remove only its stale local registration with "
            "'python github/totp.py delete --name PROFILE --yes'. "
            "No codes were emitted; this does not disable GitHub 2FA"
        )
    if not records:
        raise ToolError(
            "No registered GitHub TOTP profiles are configured. "
            f"{enrollment_hint(DEFAULT_PROFILE)} If a named seed already exists, "
            "run 'python github/totp.py register --name PROFILE' to repair its "
            f"discovery metadata. {ONE_TIME_KEY_HINT} Do not combine --all and --setup-key"
        )

    wait_for_safe_window(EXPECTED_PERIOD)
    timestamp = int(time.time())
    output = [
        (profile, record["account"], generate_code(record, timestamp))
        for profile, record in records
    ]
    for index, (profile, account, _code) in enumerate(output, start=1):
        print(
            f"TOTP[{index}]: profile={profile} account={account}",
            file=sys.stderr,
        )
    emit_totp_codes(
        [code for _profile, _account, code in output],
        copy_to_clipboard=copy_to_clipboard,
    )
    return 0


def command_profiles(_args: argparse.Namespace) -> int:
    configured = 0
    stale = 0
    for profile in store.registered_profiles():
        record = read_record(profile)
        if record is None:
            if profile != DEFAULT_PROFILE:
                print(f"MISSING: profile={profile} is registered but has no credential")
                print(
                    f"profile={profile}: restore its seed with enroll/import-qr, "
                    "or remove its stale registration with "
                    f"'python github/totp.py delete --name {profile} --yes'",
                    file=sys.stderr,
                )
                stale += 1
            continue
        print(f"CONFIGURED: profile={profile} account={record['account']}")
        configured += 1
    if configured == 0 and stale == 0:
        print("MISSING: no registered GitHub TOTP profiles are configured")
        print(
            f"{enrollment_hint(DEFAULT_PROFILE)} If a named seed already exists, "
            "run 'python github/totp.py register --name PROFILE'; profiles is "
            "not an inventory of every Windows Credential Manager entry",
            file=sys.stderr,
        )
        return 1
    return 1 if stale else 0


def command_register(args: argparse.Namespace) -> int:
    with store.storage_transaction():
        record = read_record(args.profile)
        if record is None:
            raise ToolError(
                f"GitHub TOTP profile '{args.profile}' is not configured; nothing "
                "was registered. register only repairs discovery metadata; it "
                f"does not import or recover a seed. {enrollment_hint(args.profile)}"
            )
        if args.profile == DEFAULT_PROFILE:
            print(f"REGISTERED: profile={args.profile} is the built-in default")
        elif store.register_profile(args.profile):
            print(
                f"OK: profile={args.profile} account={record['account']} registered "
                "for profiles and now --all"
            )
        else:
            print(f"REGISTERED: profile={args.profile} account={record['account']}")
    return 0


def command_delete(args: argparse.Namespace) -> int:
    if not args.yes:
        raise ToolError(
            "delete requires --yes; this removes only the local stored seed and "
            "registration, and does not disable GitHub 2FA. To confirm, run "
            f"'python github/totp.py delete --name {args.profile} --yes'"
        )
    with store.storage_transaction():
        removed = store.delete_payload(args.profile)
        try:
            unregistered = store.unregister_profile(args.profile)
        except ToolError as error:
            if removed:
                raise ToolError(
                    f"The local seed for profile '{args.profile}' was removed, but "
                    f"registry cleanup failed: {error}"
                ) from error
            raise
    if removed:
        print(
            f"OK: local GitHub TOTP profile={args.profile} removed from "
            "Windows Credential Manager"
        )
    elif unregistered:
        print(f"OK: stale GitHub TOTP profile={args.profile} registration removed")
    else:
        print(f"MISSING: GitHub TOTP profile={args.profile} is not configured")
    return 0


def profile_argument(value: str) -> str:
    try:
        return store.normalize_profile(value)
    except ToolError as error:
        raise argparse.ArgumentTypeError(str(error)) from error


def account_argument(value: str) -> str:
    try:
        return normalize_account(value)
    except ToolError as error:
        raise argparse.ArgumentTypeError(str(error)) from error


def add_profile_argument(parser: Any, default: str | None = DEFAULT_PROFILE) -> None:
    default_help = (
        f"default: {DEFAULT_PROFILE}"
        if default is not None
        else f"uses {DEFAULT_PROFILE} when no selector is provided"
    )
    parser.add_argument(
        "--profile",
        "--name",
        dest="profile",
        default=default,
        type=profile_argument,
        help=(
            f"local alias, not a GitHub login ({default_help})\n"
            "normalized to lowercase, maximum 64 characters\n"
            "start with a letter or digit; then use letters, digits, '-' or '_'"
        ),
    )


def add_enrollment_account_argument(parser: argparse.ArgumentParser) -> None:
    parser.add_argument(
        "--account",
        type=account_argument,
        metavar="GITHUB_LOGIN",
        help=(
            "actual GitHub login; required for a bare setup key; not the local profile alias\n"
            "otherwise used to verify the account in an otpauth URI or QR image"
        ),
    )


def build_parser() -> argparse.ArgumentParser:
    parser = SafeArgumentParser(
        prog="totp.py",
        description=__doc__,
        epilog=(
            "Examples (run from the repository root; replace uppercase placeholders):\n"
            "  python github/totp.py enroll --name personal --account GITHUB_LOGIN\n"
            "  python github/totp.py import-qr --name personal IMAGE\n"
            "  python github/totp.py now --name personal\n"
            "  python github/totp.py now --setup-key BASE32_SETUP_KEY\n"
            "  python github/totp.py now --all\n"
            "\n"
            "enroll uses hidden input by default; --stdin accepts redirected text.\n"
            "--setup-key accepts Base32 secret text, not an otpauth URI.\n"
            "Supplying a key on the command line may expose it in process listings/history.\n"
            "Successful now output contains only codes on stdout.\n"
            "Diagnostics, profile/account mappings, clipboard warnings and elapsed time use stderr.\n"
            "Exit status: 0 = success; 1 = runtime/missing credential; 2 = usage error.\n"
            "Use COMMAND --help for full option names, aliases and examples."
        ),
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    enroll_parser = subparsers.add_parser(
        "enroll",
        help="save a GitHub setup key or decoded otpauth URI in a local profile",
        description=(
            "Save a GitHub TOTP seed in Windows Credential Manager and register its local profile.\n"
            "By default, prompt for a setup key or decoded otpauth URI with input hidden; refuse input if hiding is unavailable.\n"
            "Bare Base32 keys require --account; URI metadata supplies the account."
        ),
        epilog=(
            "Examples:\n"
            "  python github/totp.py enroll --name personal --account GITHUB_LOGIN\n"
            "  Get-Content -Raw -LiteralPath .\\protected-input.txt | "
            "python github/totp.py enroll --name personal --account GITHUB_LOGIN --stdin\n"
            "  python github/totp.py enroll --name personal --account GITHUB_LOGIN "
            "--setup-key BASE32_SETUP_KEY\n"
            "\n"
            "Prefer the hidden prompt; protect redirected input and its source.\n"
            "This saves an existing seed; it does not configure GitHub remotely."
        ),
    )
    add_profile_argument(enroll_parser)
    add_enrollment_account_argument(enroll_parser)
    enroll_input = enroll_parser.add_mutually_exclusive_group()
    enroll_input.add_argument(
        "--stdin",
        "--setup-key-stdin",
        dest="stdin",
        action="store_true",
        help=(
            "read a Base32 setup key or decoded otpauth URI from redirected stdin (not a QR image)\n"
            "maximum 4096 characters; mutually exclusive with --setup-key"
        ),
    )
    enroll_input.add_argument(
        "--setup-key",
        metavar="BASE32_SETUP_KEY",
        help=(
            "read a Base32 setup key directly from this argument\n"
            "WARNING: the seed may be visible in process listings and shell history"
        ),
    )
    enroll_parser.add_argument(
        "--replace",
        action="store_true",
        help=(
            "replace a seed only for the same GitHub account, while GitHub displays its new setup key\n"
            "not needed to generate codes from an existing profile"
        ),
    )
    enroll_parser.set_defaults(handler=command_enroll)

    qr_parser = subparsers.add_parser(
        "import-qr",
        help="decode and save one local GitHub enrollment QR image",
        description=(
            "Decode one local QR image on this machine, validate its GitHub TOTP URI and save/register the selected profile.\n"
            "The account comes from the QR; --account optionally checks it.\n"
            "No image is uploaded."
        ),
        epilog=(
            "Examples:\n"
            "  python github/totp.py import-qr --name personal IMAGE\n"
            "  python github/totp.py import-qr --name personal --account GITHUB_LOGIN IMAGE\n"
            "\n"
            "Protect the image: it contains a long-lived seed.\n"
            "For decoded URI text, use enroll with hidden input or --stdin instead of import-qr."
        ),
    )
    add_profile_argument(qr_parser)
    add_enrollment_account_argument(qr_parser)
    qr_parser.add_argument(
        "image",
        help="local image path (such as PNG/JPEG), at most 25 MiB, with exactly one readable QR",
    )
    qr_parser.add_argument(
        "--replace",
        action="store_true",
        help=(
            "replace a seed only for the same GitHub account, while GitHub displays its new enrollment QR\n"
            "not needed for normal code generation"
        ),
    )
    qr_parser.set_defaults(handler=command_import_qr)

    status_parser = subparsers.add_parser(
        "status",
        help="validate a saved profile without printing its seed or code",
        description=(
            "Validate a saved profile and its TOTP parameters, printing only local profile/account metadata.\n"
            "Do not print its seed or code.\n"
            "This is not a live GitHub authentication check; missing or invalid credentials return 1."
        ),
        epilog="Examples:\n  python github/totp.py status --name personal",
    )
    add_profile_argument(status_parser)
    status_parser.set_defaults(handler=command_status)

    now_parser = subparsers.add_parser(
        "now",
        help="print codes from saved profiles or one temporary setup key",
        description=(
            "Print current six-digit TOTP codes.\n"
            "With no selector, use the saved default profile; --name selects a saved profile.\n"
            "--setup-key accepts Base32 secret text for one calculation without saving or requiring --account.\n"
            "It does not export a setup key or open a hidden prompt."
        ),
        epilog=(
            "Examples:\n"
            "  python github/totp.py now\n"
            "  python github/totp.py now --name personal\n"
            "  python github/totp.py now --setup-key BASE32_SETUP_KEY\n"
            "  python github/totp.py now --all --clipboard\n"
            "\n"
            "--name, --all and --setup-key are mutually exclusive.\n"
            "--name all selects a profile literally named all; it does not mean --all.\n"
            "Use enroll for hidden input and saved storage; --setup-key may expose the key in process listings/history.\n"
            "stdout contains only codes; diagnostics, --all mappings and elapsed time go to stderr.\n"
            "Generation may wait up to six seconds near a 30-second boundary."
        ),
    )
    now_selector = now_parser.add_mutually_exclusive_group()
    add_profile_argument(now_selector, default=None)
    now_selector.add_argument(
        "--all",
        action="store_true",
        help=(
            "read the default and registered named profiles\n"
            "output one synchronized code each (default first, then sorted names); map accounts on stderr\n"
            "fail without emitting codes if a registered seed is missing"
        ),
    )
    now_selector.add_argument(
        "--setup-key",
        metavar="BASE32_SETUP_KEY",
        help=(
            "generate one current code from a Base32 setup key without saving it\n"
            "no --account needed; not an otpauth URI\n"
            "WARNING: visible in process listings and shell history"
        ),
    )
    now_parser.add_argument(
        "--clipboard",
        "--copy",
        action="store_true",
        help=(
            "also copy only the returned code(s) to the Windows clipboard; does not copy a setup key\n"
            "clipboard history or sync may retain the codes"
        ),
    )
    now_parser.set_defaults(handler=command_now)

    profiles_parser = subparsers.add_parser(
        "profiles",
        help="list the default and registered local profiles without seeds or codes",
        description=(
            "List the configured default profile and registered named profiles with account metadata only.\n"
            "This is not an inventory of all Windows Credential Manager entries.\n"
            "Missing named seeds are reported as stale registrations; no configured profiles or any stale registration returns 1."
        ),
        epilog=(
            "Examples:\n"
            "  python github/totp.py profiles\n"
            "  python github/totp.py register --name EXISTING_PROFILE\n"
            "\n"
            "enroll/import-qr register profiles automatically.\n"
            "register repairs discovery metadata only when that profile's seed is already stored."
        ),
    )
    profiles_parser.set_defaults(handler=command_profiles)

    register_parser = subparsers.add_parser(
        "register",
        help="repair registry metadata for an existing stored profile",
        description=(
            "Register an already-stored named profile so profiles and now --all can discover it.\n"
            "This does not import, generate, export or recover a seed.\n"
            "The default profile is always implicit and needs no marker."
        ),
        epilog=(
            "Examples:\n"
            "  python github/totp.py register --name EXISTING_PROFILE\n"
            "\n"
            "Use enroll or import-qr to save a seed that is not already stored."
        ),
    )
    add_profile_argument(register_parser)
    register_parser.set_defaults(handler=command_register)

    delete_parser = subparsers.add_parser(
        "delete",
        help="remove a local seed and registration; does not disable GitHub 2FA",
        description=(
            "Remove only the selected profile's local seed and registry markers after explicit --yes confirmation.\n"
            "If the seed is already missing, remove its stale registration.\n"
            "This does not disable GitHub 2FA, delete other profiles or change another machine."
        ),
        epilog=(
            "Examples:\n"
            "  python github/totp.py delete --name personal --yes\n"
            "\n"
            "Deleting a seed cannot be undone by register; re-enrollment requires the original setup key/QR or a new GitHub enrollment."
        ),
    )
    add_profile_argument(delete_parser)
    delete_parser.add_argument(
        "--yes",
        action="store_true",
        help="confirm removal of this local seed and all its profile registry markers",
    )
    delete_parser.set_defaults(handler=command_delete)
    return parser


def main() -> int:
    started_at = time.perf_counter()
    try:
        args = build_parser().parse_args()
        try:
            return args.handler(args)
        except (ToolError, KeyboardInterrupt) as error:
            if isinstance(error, KeyboardInterrupt):
                print("ERROR: cancelled", file=sys.stderr)
            else:
                print(f"ERROR: {error}", file=sys.stderr)
            return 1
    finally:
        print(
            f"ELAPSED: {time.perf_counter() - started_at:.3f} s",
            file=sys.stderr,
        )


if __name__ == "__main__":
    sys.exit(main())
