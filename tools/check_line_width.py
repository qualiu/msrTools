"""Audit added staged source lines, or explicitly audit worktree files."""

from __future__ import annotations

import argparse
import ast
from dataclasses import dataclass
import difflib
import io
import logging
from pathlib import Path
import re
import subprocess
import tokenize
import unicodedata


CODE_LIMIT = 200
TEXT_LIMIT = 240
SOURCE_EXTENSIONS = {".bat", ".c", ".cc", ".cmd", ".cpp", ".cs", ".go", ".h", ".hpp", ".java", ".js", ".jsx", ".ps1", ".psm1", ".py", ".rs", ".sh", ".ts", ".tsx"}
TEXT_EXTENSIONS = {".md", ".rst", ".txt", ".json", ".xml", ".yaml", ".yml"}
POLICY_NAMES = {".editorconfig", ".flake8", "pyproject.toml", "setup.cfg", "ruff.toml", ".ruff.toml", ".prettierrc", ".prettierrc.json"}
POLICY_SETTING = re.compile(r'''(?im)^[ \t]*["']?(?:max[-_]?line[-_]?length|line[-_]?length|print[-_]?width|column[-_]?limit)["']?\s*[:=]\s*["']?(\d+)''')
JSON_POLICY_SETTING = re.compile(r'''(?i)(?<!\\)"(?:max[-_]?line[-_]?length|line[-_]?length|print[-_]?width|column[-_]?limit)"\s*:\s*(\d+)''')
JSON_COMMENT = re.compile(r'("(?:\\.|[^"\\])*")|(/\*[\s\S]*?\*/|//[^\r\n]*)')
JSON_ARGUMENT_LIST = re.compile(r'"(?:autopep8|flake8|black(?:-formatter)?|ruff|prettier)(?:\.[-\w]+)*\.args"\s*:\s*\[[^\]]*\]', re.IGNORECASE)
POLICY_ARGUMENT = re.compile(r'''--(?:max-line-length|line-length|print-width|column-limit)(?:=|[ \t]+|["']\s*,\s*["'])(\d+)''')
SCRIPT_EXTENSIONS = {".ps1", ".psm1", ".sh", ".bat", ".cmd"}
PS_TEXT_COMMAND = re.compile(r"^\s*Write-(?:Host|Output|Verbose|Debug|Information|Warning|Error)\b", re.IGNORECASE)
LOG_METHODS = {"debug", "info", "warning", "warn", "error", "exception", "critical", "log"}
LOGGER_NAMES = {"logging", "logger", "log", "console"}
LOGGER = logging.getLogger("line-width")


class AuditError(Exception):
    """A repository or input could not be audited safely."""


@dataclass(frozen=True)
class Violation:
    path: str
    line: int
    width: int
    limit: int
    kind: str = "width"


def is_policy_file(path: str) -> bool:
    candidate = Path(path)
    return candidate.name in POLICY_NAMES or candidate.as_posix().endswith(".vscode/settings.json")


def configuration_violations(path: str, source: str, selected: set[int] | None) -> list[Violation]:
    violations = []
    json_policy = Path(path).suffix.lower() == ".json" or Path(path).name == ".prettierrc"
    policy_source = JSON_COMMENT.sub(lambda comment_match: comment_match.group(1) or re.sub(r"[^\r\n]", " ", comment_match.group(2)), source) if json_policy else source
    pattern = JSON_POLICY_SETTING if json_policy else POLICY_SETTING
    matches = list(pattern.finditer(policy_source)) if is_policy_file(path) else []
    argument_lists = list(JSON_ARGUMENT_LIST.finditer(policy_source)) if json_policy else []
    for match in POLICY_ARGUMENT.finditer(policy_source):
        if json_policy and not any(region.start() <= match.start() < region.end() for region in argument_lists):
            continue
        line_start = policy_source.rfind("\n", 0, match.start()) + 1
        prefix = policy_source[line_start:match.start()].lstrip()
        if prefix.startswith("# autopep8:") or is_policy_file(path) and not prefix.startswith(("#", "//")):
            matches.append(match)
    for match in matches:
        prefix = source[source.rfind("\n", 0, match.start()) + 1:match.start()].lstrip()
        if prefix.startswith(("//", "/*", "*")):
            continue
        first = source.count("\n", 0, match.start()) + 1
        last = source.count("\n", 0, match.end()) + 1
        if int(match.group(1)) != CODE_LIMIT and (selected is None or any(number in selected for number in range(first, last + 1))):
            violations.append(Violation(path, first, int(match.group(1)), CODE_LIMIT, "configuration"))
    return violations


def display_width(text: str) -> int:
    width = 0
    for character in text:
        if character == "\t":
            width += 4 - width % 4
        elif not unicodedata.combining(character):
            width += 2 if unicodedata.east_asian_width(character) in "WF" else 1
    return width


def python_text_lines(source: str) -> set[int]:
    result = set()
    lines = source.splitlines()
    try:
        tree = ast.parse(source)
        for node in ast.walk(tree):
            if not isinstance(node, ast.Expr):
                continue
            value = node.value
            is_string = isinstance(value, ast.Constant) and isinstance(value.value, str)
            is_log = (
                isinstance(value, ast.Call) and isinstance(value.func, ast.Attribute) and value.func.attr in LOG_METHODS
                and isinstance(value.func.value, ast.Name) and value.func.value.id in LOGGER_NAMES
            )
            if not (is_string or is_log):
                continue
            prefix = lines[node.lineno - 1].encode("utf-8")[:node.col_offset].strip()
            suffix = lines[node.end_lineno - 1].encode("utf-8")[node.end_col_offset:].strip()
            if not prefix and (not suffix or suffix.startswith(b"#")):
                result.update(range(node.lineno, node.end_lineno + 1))
    except (SyntaxError, ValueError):
        pass
    try:
        for token in tokenize.generate_tokens(io.StringIO(source).readline):
            if token.type != tokenize.STRING:
                continue
            for number in range(token.start[0], token.end[0] + 1):
                prefix = lines[number - 1][:token.start[1]] if number == token.start[0] else ""
                suffix = lines[number - 1][token.end[1]:] if number == token.end[0] else ""
                if not prefix.strip() and not suffix.strip(" \t,)]}"):
                    result.add(number)
    except (tokenize.TokenError, IndentationError, SyntaxError):
        pass
    return result


def text_lines(path: str, source: str) -> set[int]:
    suffix = Path(path).suffix.lower()
    if suffix in TEXT_EXTENSIONS:
        return set(range(1, len(source.splitlines()) + 1))
    if suffix == ".py":
        result = python_text_lines(source)
        return result | {number for number, line in enumerate(source.splitlines(), 1) if line.lstrip().startswith("#")}
    result = set()
    block_end = None
    for number, line in enumerate(source.splitlines(), 1):
        stripped = line.strip()
        if block_end:
            ended = stripped == block_end if block_end in {"'@", '"@'} else block_end in stripped
            if not ended or not stripped.split(block_end, 1)[1].strip():
                result.add(number)
            if ended:
                block_end = None
            continue
        comment_end = "*/" if suffix not in SCRIPT_EXTENSIONS and stripped.startswith("/*") else "#>" if suffix in {".ps1", ".psm1"} and stripped.startswith("<#") else None
        if comment_end:
            if comment_end not in stripped:
                block_end = comment_end
            elif not stripped.split(comment_end, 1)[1].strip():
                result.add(number)
        elif suffix in {".ps1", ".psm1"} and re.search(r"@(['\"])$", stripped):
            block_end = stripped[-1] + "@"
        if suffix in {".ps1", ".psm1", ".sh"}:
            is_comment = stripped.startswith("#")
        elif suffix in {".bat", ".cmd"}:
            is_comment = bool(re.match(r"(?i)(?:::|REM(?:\s|$))", stripped))
        else:
            is_comment = stripped.startswith("//")
        is_output = bool(PS_TEXT_COMMAND.match(line)) if suffix in {".ps1", ".psm1"} else suffix in {".sh", ".bat", ".cmd"} and bool(re.match(r"(?i)@?(?:echo|printf)(?:\s|$)", stripped))
        if block_end or is_comment or is_output:
            result.add(number)
    return result


def check_source(path: str, source: str, selected: set[int] | None = None) -> list[Violation]:
    prose = text_lines(path, source)
    violations = configuration_violations(path, source, selected)
    if is_policy_file(path) and Path(path).suffix.lower() not in SOURCE_EXTENSIONS:
        return violations
    for number, line in enumerate(source.splitlines(), 1):
        if selected is not None and number not in selected:
            continue
        limit = TEXT_LIMIT if number in prose else CODE_LIMIT
        width = display_width(line)
        if width > limit:
            violations.append(Violation(path, number, width, limit))
    return violations


def git(root: Path, *arguments: str) -> bytes:
    process = subprocess.run(["git", "-C", str(root), *arguments], stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    if process.returncode:
        detail = process.stderr.decode("utf-8", errors="replace").strip()
        raise AuditError(f"Git {arguments[0]} failed ({process.returncode}): {detail}")
    return process.stdout


def repository_root(path: Path) -> Path:
    return Path(git(path, "rev-parse", "--show-toplevel").decode("utf-8").strip()).resolve()


def decode_source(path: str, content: bytes) -> str:
    try:
        return content.decode("utf-8-sig")
    except UnicodeDecodeError as exception:
        raise AuditError(f"Cannot decode {path!r} as UTF-8 at byte {exception.start}; verify the file encoding and retry.") from exception


def added_lines(previous: str, current: str) -> set[int]:
    matcher = difflib.SequenceMatcher(None, previous.splitlines(), current.splitlines(), autojunk=False)
    return {number for operation, _, _, start, end in matcher.get_opcodes() if operation in {"insert", "replace"} for number in range(start + 1, end + 1)}


def staged_changes(root: Path):
    fields = git(root, "diff", "--cached", "--name-status", "--find-renames", "--diff-filter=ACMRT", "-z").split(b"\0")
    position = 0
    while position < len(fields) and fields[position]:
        status = fields[position].decode("ascii")
        original = fields[position + 1].decode("utf-8")
        position += 2
        path = original
        if status.startswith(("R", "C")):
            path = fields[position].decode("utf-8")
            position += 1
        yield status, original, path


def audit_staged(root: Path) -> tuple[list[Violation], int]:
    violations = []
    count = 0
    for status, original, path in staged_changes(root):
        if Path(path).suffix.lower() not in SOURCE_EXTENSIONS and not is_policy_file(path):
            continue
        current = decode_source(path, git(root, "cat-file", "blob", f":{path}"))
        previous = "" if status.startswith("A") else decode_source(original, git(root, "cat-file", "blob", f"HEAD:{original}"))
        violations.extend(check_source(path, current, added_lines(previous, current)))
        count += 1
    return violations, count


def audit_worktree(root: Path, paths: list[str], all_files: bool) -> tuple[list[Violation], int]:
    candidates = paths
    if all_files:
        candidates = sorted({entry.decode("utf-8") for entry in git(root, "ls-files", "-z", "--cached", "--others", "--exclude-standard").split(b"\0") if entry})
    violations = []
    count = 0
    for candidate in candidates:
        path = Path(candidate)
        absolute = (path if path.is_absolute() else root / path).resolve()
        if not absolute.is_relative_to(root):
            raise AuditError(f"File {candidate!r} is outside the repository; select an in-repository file.")
        relative = absolute.relative_to(root).as_posix()
        supported = SOURCE_EXTENSIONS | (set() if all_files else TEXT_EXTENSIONS)
        if absolute.suffix.lower() not in supported and not is_policy_file(relative):
            if all_files:
                continue
            raise AuditError(f"Unsupported file type: {candidate!r}; select a source, document, or text data file.")
        violations.extend(check_source(relative, decode_source(relative, absolute.read_bytes())))
        count += 1
    return violations, count


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, epilog=f"Limits: code {CODE_LIMIT} display columns; comments/docstrings/log/help text {TEXT_LIMIT}. No files are changed.")
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[1], help="Repository root or a directory inside it. Defaults to this tool's repository.")
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument("--staged", action="store_true", help="Check only added/modified staged source and width-policy lines (default). Read complete index blobs for context.")
    modes.add_argument("--all", action="store_true", help="Audit all Git-visible source and width-policy files in the worktree, including historical lines; other documents/data remain explicit-only.")
    parser.add_argument("paths", nargs="*", help="Audit complete worktree files, relative to the repository root or absolute; also accepts text documents/data at 240 columns.")
    args = parser.parse_args(argv)
    if args.paths and (args.staged or args.all):
        parser.error("file paths cannot be combined with --staged or --all; omit the mode to audit those worktree files")
    logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s")
    try:
        root = repository_root(args.repo)
        violations, count = audit_worktree(root, args.paths, args.all) if args.paths or args.all else audit_staged(root)
    except (AuditError, OSError, UnicodeError, ValueError) as exception:
        LOGGER.error("AUDIT_ERROR: %s", exception)
        return 2
    for violation in violations:
        if violation.kind == "configuration":
            LOGGER.error("%s:%d: configured code width %d must equal %d", violation.path, violation.line, violation.width, violation.limit)
        else:
            LOGGER.error("%s:%d: display width %d exceeds %d", violation.path, violation.line, violation.width, violation.limit)
    if violations:
        LOGGER.error("Shorten without losing meaning, then wrap at semantic boundaries. Do not split tokens, URLs, regexes, or copyable commands.")
        return 1
    LOGGER.info("PASS: %d source/file(s) checked; code <= %d, text <= %d display columns", count, CODE_LIMIT, TEXT_LIMIT)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
