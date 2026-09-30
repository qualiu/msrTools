"""Install the repository's line-width pre-commit without replacing existing guards."""

from __future__ import annotations

import argparse
import logging
from pathlib import Path
import subprocess

from check_line_width import AuditError, git, repository_root


LOGGER = logging.getLogger("install-hooks")
HOOK = b'''#!/bin/sh
# msrTools-line-width:v1
repo_root=$(git rev-parse --show-toplevel) || exit $?
if command -v python >/dev/null 2>&1; then
    interpreter=python
elif command -v python3 >/dev/null 2>&1; then
    interpreter=python3
else
    printf '%s\\n' 'LINE_WIDTH_BLOCKED: install Python 3.10+ and retry.' >&2
    exit 2
fi
exec "$interpreter" -B "$repo_root/tools/check_line_width.py" --repo "$repo_root" --staged
'''


def install(root: Path) -> bool:
    root = repository_root(root)
    config = subprocess.run(["git", "-C", str(root), "config", "--get", "core.hooksPath"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    if config.returncode not in {0, 1}:
        raise AuditError("Cannot inspect core.hooksPath; inspect the Git configuration before retrying.")
    if config.returncode == 0:
        raise AuditError("core.hooksPath is configured; preserve it and integrate 'python -B tools/check_line_width.py --staged' into the reviewed existing pre-commit.")
    hooks = Path(git(root, "rev-parse", "--path-format=absolute", "--git-path", "hooks").decode("utf-8").strip())
    if hooks.is_symlink():
        raise AuditError("The hooks directory is linked; preserve it and review the existing hook routing before integration.")
    target = hooks / "pre-commit"
    if target.is_symlink():
        raise AuditError("Existing pre-commit is linked; preserve it and review integration instead of overwriting it.")
    if not (root / "tools" / "check_line_width.py").is_file():
        raise AuditError("tools/check_line_width.py is missing; restore the repository tool before installing its hook.")
    if target.exists():
        if target.read_bytes() != HOOK:
            raise AuditError("Unknown existing pre-commit; no hooks changed. Review it and integrate 'python -B tools/check_line_width.py --staged' without removing existing guards.")
        target.chmod(target.stat().st_mode | 0o111)
        return False
    hooks.mkdir(parents=True, exist_ok=True)
    with target.open("xb") as stream:
        stream.write(HOOK)
    target.chmod(target.stat().st_mode | 0o111)
    return True


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, epilog="Does not change core.hooksPath, prepare-commit-msg, or commit-msg. Unknown hooks require reviewed manual integration.")
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[1], help="Repository to install into; defaults to this tool's repository.")
    args = parser.parse_args(argv)
    logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s")
    try:
        changed = install(args.repo)
    except (AuditError, OSError, UnicodeError) as exception:
        LOGGER.error("INSTALL_BLOCKED: %s", exception)
        return 2
    LOGGER.info("%s; existing message/identity hooks preserved", "Installed line-width pre-commit" if changed else "Line-width pre-commit already installed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
