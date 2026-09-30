"""Store named GitHub TOTP records in Windows Credential Manager."""

from __future__ import annotations

from collections.abc import Iterator
from contextlib import contextmanager
import errno
import json
import os
from pathlib import Path
import re
import threading
import time
from typing import Any, BinaryIO


SERVICE_NAME = "msrTools.GitHubTOTP"
PROFILE_CREDENTIAL_PREFIX = "github.com/profile/"
PROFILE_REGISTRY_PREFIX = "github.com/profile-registry/"
DEFAULT_PROFILE = "default"
MAX_PROFILE_LENGTH = 64
MAX_REGISTERED_PROFILES = 64
PROFILE_REGISTRY_VERSION = 1
STORE_LOCK_TIMEOUT_SECONDS = 10.0
_thread_lock = threading.RLock()
_transaction_state = threading.local()


class StoreError(Exception):
    """A storage error that is safe to show to the user."""


def _lock_file_path() -> Path:
    if os.name == "nt":
        root = os.environ.get("LOCALAPPDATA")
        if not root:
            raise StoreError("Unable to locate the local application data directory")
    else:
        root = os.environ.get("XDG_STATE_HOME") or Path.home() / ".local" / "state"
    return Path(root) / "msrTools" / "GitHubTOTP" / "store.lock"


def _set_file_lock(lock_file: BinaryIO, unlock: bool = False) -> None:
    lock_file.seek(0)
    if os.name == "nt":
        import msvcrt

        mode = msvcrt.LK_UNLCK if unlock else msvcrt.LK_NBLCK
        msvcrt.locking(lock_file.fileno(), mode, 1)
    else:
        import fcntl

        mode = fcntl.LOCK_UN if unlock else fcntl.LOCK_EX | fcntl.LOCK_NB
        fcntl.flock(lock_file.fileno(), mode)


@contextmanager
def _process_lock(deadline: float) -> Iterator[None]:
    path = _lock_file_path()
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        lock_file = path.open("a+b")
    except OSError as error:
        raise StoreError("Unable to open the GitHub TOTP storage lock") from error
    with lock_file:
        try:
            lock_file.seek(0, os.SEEK_END)
            if lock_file.tell() == 0:
                lock_file.write(b"\0")
                lock_file.flush()
        except OSError as error:
            raise StoreError(
                "Unable to initialize the GitHub TOTP storage lock"
            ) from error
        while True:
            try:
                _set_file_lock(lock_file)
                break
            except OSError as error:
                if error.errno not in (errno.EACCES, errno.EAGAIN, errno.EDEADLK):
                    raise StoreError(
                        "Unable to acquire the GitHub TOTP storage lock"
                    ) from error
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise StoreError(
                        "Timed out waiting for another GitHub TOTP operation; retry later"
                    ) from error
                time.sleep(min(0.05, remaining))
        try:
            yield
        finally:
            try:
                _set_file_lock(lock_file, unlock=True)
            except OSError as error:
                raise StoreError(
                    "Unable to release the GitHub TOTP storage lock"
                ) from error


@contextmanager
def storage_transaction() -> Iterator[None]:
    """Serialize nested credential and registry updates for this local user."""
    deadline = time.monotonic() + STORE_LOCK_TIMEOUT_SECONDS
    if not _thread_lock.acquire(timeout=STORE_LOCK_TIMEOUT_SECONDS):
        raise StoreError(
            "Timed out waiting for another GitHub TOTP operation; retry later"
        )
    try:
        if getattr(_transaction_state, "active", False):
            yield
            return
        with _process_lock(deadline):
            _transaction_state.active = True
            try:
                yield
            finally:
                _transaction_state.active = False
    finally:
        _thread_lock.release()


def normalize_profile(raw: str) -> str:
    """Return a stable profile name that is safe for credential keys."""
    profile = str(raw or "").strip().casefold()
    if not profile:
        raise StoreError("Profile name is empty")
    if len(profile) > MAX_PROFILE_LENGTH or not re.fullmatch(
        r"[a-z0-9][a-z0-9_-]*", profile
    ):
        raise StoreError(
            "Profile name must start with a letter or digit and contain only "
            "letters, digits, '-' or '_' (maximum 64 characters); names are "
            "normalized to lowercase"
        )
    return profile


def credential_name_for_profile(profile: str) -> str:
    return f"{PROFILE_CREDENTIAL_PREFIX}{normalize_profile(profile)}"


def registry_credential_name(slot: int) -> str:
    if not 0 <= slot < MAX_REGISTERED_PROFILES:
        raise StoreError("Profile registry slot is out of range")
    return f"{PROFILE_REGISTRY_PREFIX}{slot:02d}"


def _load_keyring():
    if os.name != "nt":
        raise StoreError(
            "Saved-profile commands require Windows Credential Manager; use "
            "'python github/totp.py now --setup-key BASE32_SETUP_KEY' for a "
            "one-time calculation without storage (the key may be visible in "
            "process listings and shell history)"
        )
    try:
        import keyring
        from keyring.errors import KeyringError
    except ImportError as error:
        raise StoreError(
            "Missing dependency 'keyring'; install with: python -m pip install "
            "-r github/requirements.txt"
        ) from error

    try:
        backend = keyring.get_keyring()
    except Exception as error:
        raise StoreError(
            "Unable to initialize Windows Credential Manager; check access under "
            "the current Windows user and retry"
        ) from error

    backend_module = backend.__class__.__module__
    backend_class = backend.__class__.__name__
    if not (
        backend_module.startswith("keyring.backends.Windows")
        and backend_class == "WinVaultKeyring"
    ):
        raise StoreError(
            "Refusing to store a TOTP seed outside Windows Credential Manager; "
            f"active keyring backend is {backend_module}.{backend_class}. "
            "Use Windows WinVaultKeyring; alternate or plaintext backends are not accepted"
        )
    return keyring, KeyringError


def read_payload(profile: str) -> str | None:
    credential_name = credential_name_for_profile(profile)
    keyring, keyring_error = _load_keyring()
    try:
        return keyring.get_password(SERVICE_NAME, credential_name)
    except keyring_error as error:
        raise StoreError(
            "Unable to read GitHub TOTP from Windows Credential Manager"
        ) from error


def write_payload(profile: str, payload: str) -> None:
    credential_name = credential_name_for_profile(profile)
    with storage_transaction():
        keyring, keyring_error = _load_keyring()
        try:
            keyring.set_password(SERVICE_NAME, credential_name, payload)
        except keyring_error as error:
            raise StoreError(
                "Unable to save GitHub TOTP in Windows Credential Manager"
            ) from error


def delete_payload(profile: str) -> bool:
    credential_name = credential_name_for_profile(profile)
    with storage_transaction():
        keyring, keyring_error = _load_keyring()
        try:
            existing = keyring.get_password(SERVICE_NAME, credential_name)
        except keyring_error as error:
            raise StoreError("Unable to inspect Windows Credential Manager") from error
        if existing is None:
            return False
        try:
            keyring.delete_password(SERVICE_NAME, credential_name)
        except keyring_error as error:
            raise StoreError(
                "Unable to delete GitHub TOTP from Windows Credential Manager"
            ) from error
        return True


def _invalid_registry_slot(slot: int) -> StoreError:
    return StoreError(
        f"GitHub TOTP profile registry slot {slot} is invalid; inspect the "
        f"{PROFILE_REGISTRY_PREFIX}{slot:02d} marker under service {SERVICE_NAME} "
        "in Windows Credential Manager before retrying. register cannot repair "
        "malformed markers; do not delete seed records blindly"
    )


def _read_profile_registry(
    keyring: Any, keyring_error: type[Exception]
) -> tuple[dict[str, list[int]], list[int]]:
    registered: dict[str, list[int]] = {}
    empty_slots: list[int] = []
    for slot in range(MAX_REGISTERED_PROFILES):
        try:
            payload = keyring.get_password(SERVICE_NAME, registry_credential_name(slot))
        except keyring_error as error:
            raise StoreError(
                "Unable to read the GitHub TOTP profile registry from "
                "Windows Credential Manager"
            ) from error
        if payload is None:
            empty_slots.append(slot)
            continue
        try:
            record = json.loads(payload)
        except (TypeError, json.JSONDecodeError) as error:
            raise _invalid_registry_slot(slot) from error
        if (
            not isinstance(record, dict)
            or record.get("version") != PROFILE_REGISTRY_VERSION
        ):
            raise _invalid_registry_slot(slot)
        raw_profile = record.get("profile")
        try:
            profile = normalize_profile(str(raw_profile or ""))
        except StoreError as error:
            raise _invalid_registry_slot(slot) from error
        if raw_profile != profile or profile == DEFAULT_PROFILE:
            raise _invalid_registry_slot(slot)
        registered.setdefault(profile, []).append(slot)
    return registered, empty_slots


def registered_profiles() -> list[str]:
    """Return the implicit default profile and registered named profiles."""
    keyring, keyring_error = _load_keyring()
    registered, _empty_slots = _read_profile_registry(keyring, keyring_error)
    return [DEFAULT_PROFILE, *sorted(registered)]


def register_profile(profile: str) -> bool:
    """Add a non-default profile to the local registry if needed."""
    profile = normalize_profile(profile)
    if profile == DEFAULT_PROFILE:
        return False
    with storage_transaction():
        keyring, keyring_error = _load_keyring()
        registered, empty_slots = _read_profile_registry(keyring, keyring_error)
        if profile in registered:
            return False
        if not empty_slots:
            raise StoreError(
                f"The GitHub TOTP profile registry is full ({MAX_REGISTERED_PROFILES} "
                "named profiles); see 'python github/totp.py delete --help' to "
                "remove an unused profile only if its local seed is no longer needed"
            )
        payload = json.dumps(
            {"profile": profile, "version": PROFILE_REGISTRY_VERSION},
            separators=(",", ":"),
            sort_keys=True,
        )
        try:
            keyring.set_password(
                SERVICE_NAME, registry_credential_name(empty_slots[0]), payload
            )
        except keyring_error as error:
            raise StoreError(
                "Unable to update the GitHub TOTP profile registry in "
                "Windows Credential Manager"
            ) from error
        return True


def unregister_profile(profile: str) -> bool:
    """Remove every registry marker for a named profile."""
    profile = normalize_profile(profile)
    if profile == DEFAULT_PROFILE:
        return False
    with storage_transaction():
        keyring, keyring_error = _load_keyring()
        registered, _empty_slots = _read_profile_registry(keyring, keyring_error)
        slots = registered.get(profile, [])
        for slot in slots:
            try:
                keyring.delete_password(SERVICE_NAME, registry_credential_name(slot))
            except keyring_error as error:
                raise StoreError(
                    "Unable to update the GitHub TOTP profile registry in "
                    "Windows Credential Manager"
                ) from error
        return bool(slots)
