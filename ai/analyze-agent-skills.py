#!/usr/bin/env python
"""Analyze ~/.claude/projects/**/*.jsonl agent session logs for smart-search / set-mining / safe-replace skill violations.

Scope: assistant tool_use blocks (Bash / Read / Grep / Glob / Edit / Write).
Skill sources: C:/opengit/msrTools/skills/{smart-search,set-mining,safe-replace}/{SKILL.md,references.md}
Cross-cutting rules: ~/.claude/CLAUDE.md PRE-REPLY HARD GATES, ~/.claude/search-tools.md, ~/.claude/pipe-processing.md.
"""
import argparse, json, logging, os, re, sys, subprocess, tempfile, time
from collections import Counter, defaultdict, deque
from pathlib import Path
from datetime import datetime, timedelta, timezone

sys.path.insert(0, str(Path(__file__).parent / 'cli-spec'))
try:
    from check_cli import check_command as _cli_spec_check_raw
    from check_cli import probe_cache_stats as _probe_cache_stats
    from check_cli import set_probe_cache_enabled as _set_probe_cache_enabled
except ImportError:
    def _cli_spec_check_raw(_cmd, probe_mode='auto'):
        return []
    def _probe_cache_stats():
        return (0, 0, 0.0, 0)
    def _set_probe_cache_enabled(_enabled):
        pass

_PROBE_MODE = 'auto'

def _cli_spec_check(cmd):
    return _cli_spec_check_raw(cmd, probe_mode=_PROBE_MODE)

sys.stdout.reconfigure(encoding='utf-8')
sys.stderr.reconfigure(encoding='utf-8')

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s.%(msecs)03d %(levelname)s [%(filename)s:%(lineno)d] %(funcName)s() %(message)s',
    datefmt='%Y-%m-%d %H:%M:%S',
    stream=sys.stderr,
)
log = logging.getLogger()

PROJECTS_DIR = Path.home() / '.claude' / 'projects'
DEFAULT_PROJECTS_DIRS = [PROJECTS_DIR]

ALIASES_WITH_BUILTIN_I = re.compile(r'\b(gfind-(?!file\b)[\w-]+|find-py|find-cs|find-doc|find-small|find-all|find-ndp)\b')
GFIND_OR_FIND = re.compile(r'\b(gfind-[\w-]+|find-ndp|find-py|find-cs|find-doc|find-small|find-all|find-file)\b')
NON_ASCII = re.compile(r'[^\x00-\x7f]')
SHELL_NATIVE_SEARCH = re.compile(r'(?:^|[\s|;&])(grep|findstr|Select-String|Where-Object|Group-Object|Compare-Object|Measure-Object)\b|\bfind\s+[^|]*-name\b')
SHELL_NATIVE_PIPE = re.compile(r'\|\s*(head|tail|wc|sort\s+-u|sort\s*\|\s*uniq|Select-Object\s+-(?:First|Last)|Group-Object)\b')
STDERR_REDIR = re.compile(r'2>(?:&1|/dev/null|nul|\S+)')
MSR_RP = re.compile(r'\bmsr\s+(?:-\S*\s+)*-rp\s+(\S+)')
MSR_P_SINGLE = re.compile(r'(?:^|[\s|;&(])msr\s+(?:-\S+\s+)*-p\s+\S+')
MSR_DASH_R = re.compile(r'\bmsr\s+(?:[^|]*?)-R\b')
MSR_T_DOT = re.compile(r'\bmsr\s+(?:[^|]*?)-t\s+["\']\.["\']')
NIN_PD_NO_SUM = re.compile(r'\bnin\b(?=[^|]*-pd\b)(?![^|]*--sum\b)')
NIN_POSITIONAL = re.compile(r'(?:^|[\s|;&])nin\s+(?:-\S+\s+)*(?:nul|[^\s|;&-]\S*)\s+("([^"]+)"|\'([^\']+)\')')
MSR_DASH_RK = re.compile(r'\bmsr\s+(?:[^|]*?)-RK\b')
ALLOWED_FIND_TOOLS = {'gfind-file', 'gfind-small', 'gfind-config', 'find-ndp'}
ANY_FIND_TOOL = re.compile(r'(?:^|[\s|;&(])((?:gfind|find)-[\w-]+)\b')
TOOL_CHAIN_TOKEN = r'(?:msr|nin|gfind-[\w-]+|find-ndp|find-file|find-small|find-py|find-cs|find-doc|find-all)'
TOOL_HEAD = rf'(?:^|[\s|;&(])({TOOL_CHAIN_TOKEN})\b[^|;&]*'
MSR_TOOL_AT_START = re.compile(rf'(?:^|[\s|;&(])({TOOL_CHAIN_TOKEN})\b')
REGEX_META = re.compile(r'[\[\]{}()|+?]|\.\*|\^\w|\w\$')
SP_VALUE = re.compile(r'(?:^|\s)(--sp|-x|--nx)\s+("([^"]*)"|\'([^\']*)\'|(\S+))')
ERR_MARKERS = re.compile(r'(Invalid preceding|cannot be specified more than once|No Regex capture1|Failed to parse|is not used|unexpected EOF|Unknown option|illegal option|No such file or directory)', re.I)
ZERO_MATCH = re.compile(r'(Matched|Got)\s+0\s+lines?\b')
PLAIN_GREP_FIND = re.compile(r'(?:^|[\s|;&(])(grep|rg|findstr|find)\s+(?:-\S+\s+)*("([^"]+)"|\'([^\']+)\'|(\S+))')
PIPE_TEXT_TOOLS = re.compile(r'\|\s*(awk|sed|cut|tr|uniq|xargs|ForEach-Object|%\s|Where-Object|Group-Object|Measure-Object|Select-String|Compare-Object|Sort-Object|paste|column)\b')
MSR_RP_NO_F = re.compile(r'\bmsr\s+(?:[^|]*?)-rp\s+\S+(?![^|]*\s-f\s)(?![^|]*\s-p\s)')

GFIND_OR_FIND_NDP = re.compile(r'\b(gfind-[\w-]+|find-ndp)\b')
GFIND_LEADING = re.compile(r'^\s*(gfind-[\w-]+|find-ndp)(?:\s|$)')
XP_VALUE = re.compile(r'(?<!\S)--xp\s+("([^"]+)"|\'([^\']+)\'|(\S+))')
NARROW_FLAG = re.compile(r'(?<!\S)(--sp|--pp|--np|--nf|--nd|--xp|--xd|--xf|--nx|-d|-f|-t|-x|-nf)(?:\s|=)')

MSR_D_INT = re.compile(rf'{TOOL_HEAD}?\s-d\s+(\d+)(?:\s|$)')
MSR_F_WITH_SLASH = re.compile(r'\b(?:msr|gfind-[\w-]+|find-ndp|find-file|find-small|find-py|find-cs|find-doc|find-all)\b[^|;&]*?\s-f\s+("([^"]*/[^"]*)"|\'([^\']*/[^\']*)\')')
MSR_E_NO_TX = re.compile(rf'{TOOL_HEAD}?\s-e\s+\S+')
EXCLUDE_PLAIN_PIPE = re.compile(r'(--x[pdf])\s+("([^"]*\|[^"]*)"|\'([^\']*\|[^\']*)\')')
NO_COLOR_BUNDLE = re.compile(r'(?<!\S)-[A-Za-z]*C[A-Za-z]*\b')
H_LOW_NO_TAIL = re.compile(rf'{TOOL_HEAD}(?<!\S)-H\s+([01])(?:\s|$)')
DOLLAR_BACKREF_IN_O = re.compile(rf'{TOOL_HEAD}\s-o\s+("[^"]*\\?\$\d[^"]*"|\'[^\']*\\?\$\d[^\']*\')')

STRIP_PATH_SUFFIX = re.compile(r'msr\s+-t\s+["\']\^\.\.\[\^:\]\+:\(\\d\+:\.\*\)["\']')
MSR_R_AS_RECURSIVE = re.compile(rf'{TOOL_HEAD}\s-R(?:\b|\s)')
CLASSIFY_SEARCH_RIGHT = re.compile(rf'(?:^|[\s|;&(])({TOOL_CHAIN_TOKEN})\b')
CLASSIFY_SEARCH_WRONG = re.compile(r'(?:^|[\s|;&(])(grep|rg|findstr|Select-String)\b|(?:^|[\s|;&(])find\s+(?:-\S+\s+)*\S+\s+(?:-\S+\s+)*-name\b')
CLASSIFY_REPLACE_RIGHT = re.compile(r'\bmsr\s+(?:[^|]*?)-RK?\b')
CLASSIFY_REPLACE_WRONG = re.compile(r'(?:^|[\s|;&(])(sed)\s+(?:-\S+\s+)*-i\b|\|\s*Set-Content\b|\|\s*Out-File\b')

SKILL_SMART_SEARCH = re.compile(
    r'(?:^|[\s|;&(])(msr|gfind-[\w-]+|find-(?:ndp|py|cs|doc|small|all|file)|grep|rg|findstr|Select-String)\b'
)
SKILL_SAFE_REPLACE_BASH = re.compile(
    r'\bmsr\s+(?:[^|]*?)-RK?\b|(?:^|[\s|;&(])sed\b\s+(?:-\S+\s+)*-i\b|\|\s*(?:Set-Content|Out-File)\b'
)
SKILL_SET_MINING = re.compile(
    r'(?:^|[\s|;&(])nin\b|\|\s*(?:sort\s+-u|sort\s*\|\s*uniq|uniq|Group-Object|Sort-Object\s+-Unique|Compare-Object|Measure-Object)\b'
)
SKILL_NAMES = ('smart-search', 'safe-replace', 'set-mining')


def classify_skills(tool_name, cmd):
    """Return set of skill names this tool_use belongs to. Non-exclusive."""
    skills = set()
    if tool_name in ('Edit', 'Write'):
        skills.add('safe-replace')
    if tool_name in ('Grep', 'Glob'):
        skills.add('smart-search')
    if tool_name == 'Bash' and cmd:
        is_msr_replace = bool(re.search(r'\bmsr\s+(?:[^|]*?)-RK?\b', cmd))
        if SKILL_SMART_SEARCH.search(cmd) and not is_msr_replace:
            skills.add('smart-search')
        if SKILL_SAFE_REPLACE_BASH.search(cmd):
            skills.add('safe-replace')
        if SKILL_SET_MINING.search(cmd):
            skills.add('set-mining')
    return skills


MSR_STATS_RE = re.compile(r'Matched\s+(\d+)\s+lines?(?:\([\d.]+%\))?(?:\s+in\s+(\d+)\s+files?)?.*?Used\s+([\d.]+)\s+s', re.S)


def parse_msr_stats(stderr):
    if not stderr:
        return None
    m = MSR_STATS_RE.search(stderr)
    if not m:
        return None
    lines = m.group(1)
    files = m.group(2) or '-'
    secs = m.group(3)
    return f'{lines}L/{files}F {secs}s'

GIT_ROOT_CACHE = {}


DURATION_RE = re.compile(r'^(\d+(?:\.\d+)?)([mhdw])$', re.I)
UNIT_SECONDS = {'m': 60, 'h': 3600, 'd': 86400, 'w': 604800}


def parse_time(s, now=None):
    """Parse --since / --until value into datetime.

    Forms:
      "0"                       -> None (means "no bound")
      "30m" / "2h" / "7d" / "1w" -> now - duration
      "2026-05-24"              -> ISO date at 00:00:00
      "2026-05-24 14:00"        -> ISO datetime
      "2026-05-24T14:00:00"     -> ISO datetime
    """
    if s is None:
        return None
    s = str(s).strip()
    if s == '' or s == '0':
        return None
    now = now or datetime.now()
    m = DURATION_RE.match(s)
    if m:
        n = float(m.group(1))
        unit = m.group(2).lower()
        return now - timedelta(seconds=n * UNIT_SECONDS[unit])
    try:
        return datetime.fromisoformat(s.replace('Z', '+00:00').replace(' ', 'T', 1) if 'T' not in s and ' ' in s else s.replace('Z', '+00:00'))
    except ValueError:
        raise argparse.ArgumentTypeError(
            f'invalid time value: "{s}" - use duration ({{N}}{{m|h|d|w}}, e.g. 30m / 2h / 7d / 1w), "0" for no bound, or ISO date (2026-05-24 or "2026-05-24 14:00")')


def to_native_path(p):
    if not p:
        return p
    p = p.replace('\\', '/').rstrip('/')
    m = re.match(r'^/([a-zA-Z])/(.*)', p)
    if m:
        return f'{m.group(1).upper()}:/{m.group(2)}'
    return p


def find_git_root(cwd):
    cwd = to_native_path(cwd)
    if not cwd:
        return None
    if cwd in GIT_ROOT_CACHE:
        return GIT_ROOT_CACHE[cwd]
    try:
        r = subprocess.run(['git', '-C', cwd, 'rev-parse', '--show-toplevel'],
                           capture_output=True, text=True, timeout=5)
        root = r.stdout.strip() if r.returncode == 0 else None
        root = to_native_path(root) if root else None
    except Exception:
        root = None
    GIT_ROOT_CACHE[cwd] = root
    return root


def path_in_git_tree(path_arg, cwd):
    abs_path = path_arg
    if not re.match(r'^[a-zA-Z]:[/\\]|^/[a-zA-Z]/', path_arg):
        if cwd:
            abs_path = os.path.normpath(os.path.join(to_native_path(cwd), path_arg))
    abs_path = to_native_path(abs_path)
    root = find_git_root(abs_path if os.path.isdir(abs_path) else os.path.dirname(abs_path))
    return root is not None, root, abs_path


def extract_value(cmd, flag):
    m = re.search(rf"{re.escape(flag)}\s+(\"[^\"]*\"|'[^']*'|\S+)", cmd)
    if not m:
        return None
    v = m.group(1)
    if v[0] in '"\'' and v[-1] == v[0]:
        v = v[1:-1]
    return v


def _split_pipes(cmd):
    out = []
    buf = []
    quote = None
    i = 0
    while i < len(cmd):
        c = cmd[i]
        if quote:
            buf.append(c)
            if c == quote and cmd[i-1] != '\\':
                quote = None
        elif c in '"\'':
            quote = c
            buf.append(c)
        elif c == '|' and i+1 < len(cmd) and cmd[i+1] != '|' and (i == 0 or cmd[i-1] != '|'):
            out.append(''.join(buf))
            buf = []
        else:
            buf.append(c)
        i += 1
    out.append(''.join(buf))
    return out


def _r6(cmd): return 'remove 2>&1 / 2>nul / 2>/dev/null' if STDERR_REDIR.search(cmd) else None
def _r4(cmd): return 'use msr/nin/gfind-* not grep/findstr/Select-String' if SHELL_NATIVE_SEARCH.search(cmd) else None
def _r5(cmd): return 'use msr -H/-T or nin not | head/tail/wc/sort -u' if SHELL_NATIVE_PIPE.search(cmd) else None
def _r10(cmd): return 'add --sum when using nin -pd' if NIN_PD_NO_SUM.search(cmd) else None
def _r8(cmd): return 'omit -t "."; msr -p file -PIC dumps all lines' if MSR_T_DOT.search(cmd) else None
def _r18(cmd): return 'multi-file msr -rp must add -f "<pattern>" or it reads all file types' if MSR_RP_NO_F.search(cmd) and ' -p ' not in cmd else None
def _r30(cmd): return '-e on msr/gfind/nin is enhance/color-only — never useful for agent (agent does not see ANSI). Remove -e; use -t for regex match or -x for plain text.' if MSR_E_NO_TX.search(cmd) else None
def _r33(cmd):
    m = H_LOW_NO_TAIL.search(cmd)
    if not m:
        return None
    seg = cmd[m.start():m.start()+200]
    if re.search(r'(?<!\S)-J\b', seg) or re.search(r'(?<!\S)-T\s+\d', seg):
        return None
    n = m.group(2)
    return f'-H {n} without -T N: use "-H 1 -T 1" (count + tail-line scope verification) or "-H 1 -J" (existence fast-exit). Bare -H {n} reads all files but loses cheap +1 tail line.'
def _r34(cmd):
    m = DOLLAR_BACKREF_IN_O.search(cmd)
    return '-o "$N" backreference: use \\\\1 instead of $1 — bash/PowerShell expand $N as variable, breaking the replacement.' if m else None

def _r35(cmd):
    for m in ANY_FIND_TOOL.finditer(cmd):
        tool = m.group(1)
        if tool not in ALLOWED_FIND_TOOLS and not tool.startswith('find-alias'):
            return f'agent must use only gfind-file / gfind-small / gfind-config / find-ndp (or msr -rp / msr -p); "{tool}" is non-allowlisted -- risks hallucinated gfind-* and increases agent memory load.'
    return None

def _r37(cmd):
    """msr -R is REPLACE-FILE (destructive), not grep/rg -r recursive.
    Fire when standalone -R appears without -o (no replacement intent) and without -K (no backup intent).
    """
    if not MSR_R_AS_RECURSIVE.search(cmd):
        return None
    if re.search(r'(?<!\S)-RK\b|(?<!\S)-K\b', cmd):
        return None
    if re.search(r'(?<!\S)-o\b|(?<!\S)--replace-to\b', cmd):
        return None
    return ('msr -R is REPLACE-FILE (destructive!), NOT grep/rg -r recursive. '
            'For recursive search use lowercase -r / -rp <path> (or msr -rp <path> -f "<regex>"). '
            'For replacement use -R together with -t/-x AND -o "<replacement>".')


_TOOL_HEAD_AT_START = re.compile(rf'^\s*{TOOL_CHAIN_TOKEN}\b')
_EXIT_FLAG = re.compile(r'(?<!\S)--exit(?:=|\s)')


def _split_top_level_logical(cmd):
    """Split cmd on top-level && / || (outside single/double quotes). Returns list of (segment, op_after).
    op_after is '&&', '||' or '' for last segment."""
    parts = []
    buf = []
    quote = None
    i = 0
    n = len(cmd)
    while i < n:
        c = cmd[i]
        if quote:
            buf.append(c)
            if c == quote and cmd[i-1:i] != '\\':
                quote = None
            i += 1
            continue
        if c in ("'", '"'):
            quote = c
            buf.append(c)
            i += 1
            continue
        if c in ('&', '|') and i + 1 < n and cmd[i+1] == c:
            parts.append((''.join(buf), c * 2))
            buf = []
            i += 2
            continue
        buf.append(c)
        i += 1
    parts.append((''.join(buf), ''))
    return parts


def _iter_command_segments(cmd):
    """Yield (segment_stripped, logical_op_after) for every top-level && / ||
    sub-segment of every pipe-separated piece. Skips empty segments."""
    for piece in _split_pipes(cmd):
        for seg, op in _split_top_level_logical(piece):
            seg_s = seg.strip()
            if seg_s:
                yield seg_s, op


def _r38(cmd):
    """msr/nin/gfind-* before && or || without --exit: exit code is match-count,
    not 0/1 success. MSR_EXIT env var can also alter default. Only --exit makes
    semantics explicit and machine-portable."""
    if '&&' not in cmd and '||' not in cmd:
        return None
    segs = _split_top_level_logical(cmd)
    if len(segs) < 2:
        return None
    for idx, (seg, op) in enumerate(segs):
        if op not in ('&&', '||'):
            continue
        next_seg = segs[idx + 1][0].strip() if idx + 1 < len(segs) else ''
        if not next_seg:
            continue
        if not _TOOL_HEAD_AT_START.search(seg):
            continue
        if _EXIT_FLAG.search(seg):
            continue
        return (f'msr/nin/gfind-* before {op} without --exit: exit code = match-count (0..N), not 0/1. '
                f'MSR_EXIT env may also alter default. On Linux/MacOS error returns -1 -> truncated to 255 by shell; '
                f'on MinGW -> 127. Match counts > 255 also wrap. '
                f'Add explicit --exit with [Number] OR [Regex-or-Math]-to-[Exit-Code] (comma-separated for multi-rule). '
                f'Common recipes: --exit gt0-to-0,le0-to-1 (UNIX 0=success on match) | '
                f'--exit 0 (always 0) | --exit "lt0-to-1,255-to-1" (normalize error+truncation cross-platform) | '
                f'--exit "gt0-to-0,le0-to-1,255-to-1" (search-success + normalize 255-wrap). '
                f'Or restructure to | pipe / separate statements.')
    return None


_TOOL_START_RE = re.compile(rf'^\s*({TOOL_CHAIN_TOKEN})\b')
_C_BUNDLE_TOKEN = re.compile(r'(?<!\S)-[A-Za-z]*C[A-Za-z]*(?!\S)')
_LONG_NO_COLOR = re.compile(r'(?<!\S)--no-color\b')
_GREP_C_CONTEXT = re.compile(r'(?<!\S)-C\s+\d+\b')
_ALIASES_WITH_BUILTIN_C = re.compile(r'^(find-alias|(?:g?find)-top-\S+)$')


def _r39(cmd):
    """Every msr/nin/gfind-*/find-* invocation must have -C (or any short-bundle
    containing C: -PIC, -IC, -PAC, -PICc, ...) or --no-color. ANSI color leaks
    into agent output and breaks downstream regex / readability. -C <digit>
    is grep-style context misuse (F12), NOT real --no-color.
    Aliases find-alias / (g)find-top-* already bundle -C internally."""
    for seg_s, _op in _iter_command_segments(cmd):
        m_tool = _TOOL_START_RE.match(seg_s)
        if not m_tool:
            continue
        tool = m_tool.group(1)
        if _ALIASES_WITH_BUILTIN_C.match(tool):
            continue
        args = seg_s[m_tool.end():]
        no_grep_C = _GREP_C_CONTEXT.sub(' ', args)
        if _LONG_NO_COLOR.search(no_grep_C):
            continue
        if _C_BUNDLE_TOKEN.search(no_grep_C):
            continue
        return (f'{tool} without -C (or -PIC / -IC / -PAC / --no-color): '
                f'ANSI color leaks into stdout, breaks downstream regex and agent readability. '
                f'Add -C, or bundle into -PIC (no-path + no-extra + no-color) / -IC / -PAC / -PICc. '
                f'Note: -C <integer> is grep-style context (F12 misuse), NOT --no-color; '
                f'use -U N / -D N for context.')
    return None


def _r25(cmd):
    m = PIPE_TEXT_TOOLS.search(cmd)
    return f'| {m.group(1)} in pipe; use | msr (filter/extract) or | nin (dedup/dist/diff) instead' if m else None

def _r40(cmd):
    """gfind-*/find-ndp --xp containing obj/bin: /obj/, /bin/, /obj, /bin are
    redundant (gfind-* already respects .gitignore); bare obj / bin are unsafe
    (substring match also hits ObjectFactory/, Bindings/, etc.)."""
    if not GFIND_OR_FIND_NDP.search(cmd):
        return None
    for m in XP_VALUE.finditer(cmd):
        val = m.group(2) or m.group(3) or m.group(4) or ''
        for raw in val.split(','):
            tok = raw.strip()
            tl = tok.lower()
            if tl in ('/obj/', '/bin/', '/obj', '/bin'):
                return (f'--xp "{tok}" is redundant: gfind-*/find-ndp already honors .gitignore '
                        f'(obj/, bin/ are typically gitignored). Remove the token or move to --xd '
                        f'if you need to exclude in non-git trees.')
            if tl in ('obj', 'bin'):
                return (f'--xp "{tok}" is unsafe substring match: also excludes ObjectFactory/, '
                        f'Bindings/, ObjectModel/, etc. Use "/obj/" / "/bin/" (slashes) or --xd '
                        f'with a regex anchored to the directory name.')
    return None

def _r41(cmd):
    """--xp / --xd / --xf / --sp / --pp values are CSV (comma-separated), case-insensitive
    on Windows. Duplicate items after case-fold (e.g. "test,Test,TEST") are dead weight
    and usually signal a copy-paste mistake."""
    if not GFIND_OR_FIND_NDP.search(cmd) and ' msr ' not in (' ' + cmd):
        return None
    hits = []
    for flag in ('--xp', '--xd', '--xf', '--sp'):
        for m in re.finditer(rf'(?<!\S){re.escape(flag)}\s+("([^"]+)"|\'([^\']+)\'|(\S+))', cmd):
            val = m.group(2) or m.group(3) or m.group(4) or ''
            parts = [p.strip() for p in val.split(',') if p.strip()]
            lowered = [p.lower() for p in parts]
            if len(lowered) != len(set(lowered)):
                dup = [p for p in parts if lowered.count(p.lower()) > 1]
                hits.append(f'{flag} "{val[:60]}" has duplicate (case-insensitive) tokens: {sorted(set(dup))[:4]}')
    if hits:
        return ' | '.join(hits) + '. CSV values are case-insensitive on Windows; deduplicate.'
    return None

def _r42(cmd):
    """gfind-*/find-ndp invoked at segment start without any narrowing flag:
    no --sp / --pp / --np / -d / -f / -t / -x / --xp / --xd. The tool then walks
    the entire repo and reads every file, which is slow and noisy. Always pair
    with at least one narrowing flag (-f filename-regex, -t content-regex,
    --pp path-regex, --sp path-list, etc.)."""
    for seg_s, _op in _iter_command_segments(cmd):
        m = GFIND_LEADING.match(seg_s)
        if not m:
            continue
        tool = m.group(1)
        args = seg_s[m.end():]
        if NARROW_FLAG.search(args):
            continue
        if re.search(r'(?<!\S)-(H|T|J|l)\b', args) and not args.strip():
            continue
        return (f'{tool} without any narrowing flag (-f / -t / -x / --pp / --np / --sp / '
                f'--xp / --xd / -d): walks every file in the tree. Add at least one of: '
                f'-f "<filename-regex>", -t "<content-regex>", --pp "<full-path-regex>".')
    return None

def _r27(cmd):
    m = MSR_D_INT.search(cmd)
    return f'-d {m.group(2)} on msr/gfind: -d takes a sub-folder-NAME regex, not max-depth. For depth use -k N.' if m else None

def _r28(cmd):
    m = MSR_F_WITH_SLASH.search(cmd)
    if not m: return None
    val = m.group(2) or m.group(3) or ''
    return f'-f matches filename only; "{val[:60]}" contains "/" — use --pp for full-path regex or split with -f + --pp/--np'

def _r29(cmd):
    m = EXCLUDE_PLAIN_PIPE.search(cmd)
    if not m: return None
    flag = m.group(1); val = m.group(3) or m.group(4) or ''
    return f'{flag} takes comma-separated plain text not regex: "{val[:60]}" contains "|". Use comma: "{val.replace("|", ",")[:60]}" or switch to --np/--nd/--nf for regex.'

def _r24(cmd):
    for gm in PLAIN_GREP_FIND.finditer(cmd):
        tool = gm.group(1)
        if tool == 'find':
            tail = cmd[gm.start():gm.start()+200]
            if not any(f in tail for f in ('-name', '-iname', '-path', '-regex')):
                continue
        pat = gm.group(3) or gm.group(4) or gm.group(5) or ''
        if NON_ASCII.search(pat):
            continue
        return f'{tool} "{pat[:40]}" has ASCII-only pattern; use msr/gfind-* (smart-search) instead'
    return None

def _r15(cmd):
    for m in NIN_POSITIONAL.finditer(cmd):
        pat = m.group(2) or m.group(3) or ''
        if pat and '(' not in pat and pat != 'nul':
            return f'nin positional regex needs (...) capture group: "{pat}" -> "({pat})"'
    return None

def _r9(cmd):
    if not re.search(r'(?<!\S)-PIC\b', cmd):
        return None
    m_alias = ALIASES_WITH_BUILTIN_I.search(cmd)
    if m_alias and re.search(rf'\b{re.escape(m_alias.group(1))}\b[^|]*(?<!\S)-PIC\b', cmd):
        return f'use -PC not -PIC ({m_alias.group(1)} has built-in -I)'
    return None

def _r3(cmd):
    if not (MSR_P_SINGLE.search(cmd) and ' -rp ' not in cmd and re.search(r'(?<!\S)-PIC\b', cmd) and '|' in cmd):
        return None
    if STRIP_PATH_SUFFIX.search(cmd):
        return None
    return 'msr -p file -PIC piped downstream pollutes output with path; use -IC + | msr -t "^..[^:]+:(\\d+:.*)" -o "\\1" -PIC strip-path suffix'

def _r7(cmd):
    if not MSR_DASH_R.search(cmd):
        return None
    for flag in ('-t', '-o', '--nt', '--np', '--xt'):
        v = extract_value(cmd, flag)
        if v and NON_ASCII.search(v):
            return f'use Edit tool; non-ASCII in {flag} corrupts via ANSI argv'
    return None


def _r19(cmd, cwd):
    if not MSR_DASH_RK.search(cmd):
        return None
    return 'in git repo use -R not -RK; git already backs up via diff/checkout' if cwd and find_git_root(cwd) else None

def _r1(cmd, cwd):
    m = MSR_RP.search(cmd)
    if not m:
        return None
    in_tree, root, _ = path_in_git_tree(m.group(1), cwd)
    return f'cd {root} && gfind-* instead' if in_tree else None

def _r2(cmd, cwd):
    if not GFIND_OR_FIND.search(cmd):
        return None
    return 'use msr -rp on non-git dirs' if cwd and find_git_root(cwd) is None else None


def _r43(cmd):
    """gfind-*/find-ndp writes the whole-repo git-tracked file list to a temp
    paths file and invokes 'msr -w <paths-file>'. Appending -p <subdir> does
    NOT narrow into <subdir> -- msr treats -p as an ADDITIONAL input root on
    top of the -w list. Result: the full-repo list is still scanned, plus
    <subdir> is added. Agent typically intends "search inside <subdir>", which
    requires --sp / --pp / -d (filename/path filters), not -p.
    Verified empirically: gfind-file -p ai -f "\\.py$" -l returns 276 .py files
    spanning the WHOLE repo (sibling-dir-1/, sibling-dir-2/, ...), not just ai/.
    """
    for seg_s, _op in _iter_command_segments(cmd):
        m = GFIND_LEADING.match(seg_s)
        if not m:
            continue
        tool = m.group(1)
        args = seg_s[m.end():]
        if not re.search(r'(?<!\S)-p(?:\s|=)', args):
            continue
        return (f'{tool} -p <dir> does NOT narrow into <dir>: {tool} feeds the whole-repo git '
                f'file list via "msr -w"; -p only APPENDS another input root, the full list is '
                f'still scanned. To narrow into a subdir use --sp /<dir>/ (path-contains AND), '
                f'--pp "/<dir>/" (full-path regex), or -d "^<dir>$" (sub-folder-name regex). '
                f'Drop the -p.')
    return None



SIMPLE_RULES = [
    ('R6',  'stderr-redirect',           _r6),
    ('R4',  'shell-native-search',       _r4),
    ('R5',  'shell-native-pipe',         _r5),
    ('R10', 'nin-pd-no-sum',             _r10),
    ('R8',  'msr-t-dot',                 _r8),
    ('R18', 'msr-rp-no-f',               _r18),
    ('R27', 'd-int-on-msr',              _r27),
    ('R28', 'f-with-slash',              _r28),
    ('R29', 'exclude-comma-not-regex',   _r29),
    ('R30', 'e-on-msr',                  _r30),
    ('R33', 'H-zero-on-msr',             _r33),
    ('R34', 'dollar-backref-in-o',       _r34),
    ('R35', 'non-allowlisted-find-tool', _r35),
    ('R37', 'msr-R-not-grep-r',          _r37),
    ('R38', 'chain-without-exit',        _r38),
    ('R39', 'missing-no-color',          _r39),
    ('R40', 'gfind-xp-obj-bin',          _r40),
    ('R41', 'csv-flag-dup-case',         _r41),
    ('R42', 'gfind-no-narrowing',        _r42),
    ('R43', 'gfind-redundant-p',         _r43),
    ('R24', 'shell-search-replaceable',  _r24),
    ('R25', 'pipe-text-tool',            _r25),
    ('R15', 'nin-no-capture-group',      _r15),
    ('R3',  'single-file-PIC',           _r3),
    ('R9',  'PIC-on-alias-with-builtin-I', _r9),
    ('R7',  'msr-R-non-ascii-arg',       _r7),
]
CONTEXTUAL_RULES = [
    ('R1',  'msr-rp-in-git-tree', _r1),
    ('R2',  'gfind-on-non-git',   _r2),
    ('R19', 'msr-RK-in-git',      _r19),
]


def _check_segments(cmd, hits):
    segments = _split_pipes(cmd)
    seen = {h[0] for h in hits}
    for idx, seg in enumerate(segments):
        seg_s = seg.strip()
        if 'R31' not in seen and idx < len(segments) - 1:
            m_tool = re.match(rf'^({TOOL_CHAIN_TOKEN})\b', seg_s)
            if m_tool and re.match(r'^(msr|nin|gfind-|awk|sed|cut|tr)', segments[idx+1].strip()) \
               and not NO_COLOR_BUNDLE.search(seg) and not re.search(r'(?<!\S)-X\b', seg):
                hits.append(('R31', 'no-color-before-pipe',
                             f'{m_tool.group(1)} piped to text tool without -C; ANSI colors leak. Add -C (or use -PIC/-PAC).'))
                seen.add('R31')
        if 'R32' not in seen and seg_s.startswith('nin ') and re.search(r'(?<!\S)-[A-Za-z]*I[A-Za-z]*\b', seg_s):
            hits.append(('R32', 'nin-I-pollutes-stdout',
                         'nin -I = --info-normal-out (writes summary to STDOUT, opposite of msr -I). Remove -I; use -M (no summary) or -PAC for clean output.'))
            seen.add('R32')


def check_bash(cmd, cwd):
    hits = []
    for rule_id, tag, fn in SIMPLE_RULES:
        msg = fn(cmd)
        if msg:
            hits.append((rule_id, tag, msg))
    for rule_id, tag, fn in CONTEXTUAL_RULES:
        msg = fn(cmd, cwd)
        if msg:
            hits.append((rule_id, tag, msg))
    _check_segments(cmd, hits)
    for v in _cli_spec_check(cmd):
        sev_marker = '[SUSPICIOUS] ' if getattr(v, 'severity', 'error') == 'suspicious' else ''
        hits.append((v.code, f'{v.tool}{v.flag}', sev_marker + v.msg))
    return hits


def check_tool_call(tool, inp, cwd):
    hits = []
    name = (tool or '').lower()
    if name == 'bash':
        hits.extend(check_bash(inp.get('command', '') or '', cwd))
    elif name in ('grep', 'glob'):
        if cwd and find_git_root(cwd):
            hits.append(('R14', f'{name}-in-git-repo', 'use gfind-*/msr smart-search not Grep/Glob in git repo'))
    return hits


def _expand_claude_siblings(roots):
    """For each root, also include same-level sibling directories whose name starts with '.claude'.
    No recursion: scan only the immediate parent of each anchor.
    Anchor selection:
      - If root's basename starts with '.claude', anchor.parent = root.parent (siblings of root itself).
      - Else if root's parent basename starts with '.claude' (e.g. ~/.claude/projects), anchor.parent = root.parent.parent.
      - Else use root.parent (look for .claude* siblings sharing the same parent).
    For each sibling dir, append '/projects' if a 'projects' subdir exists and root originally ended in 'projects'
    (or root pointed at a .claude dir whose 'projects' subdir exists). Otherwise use the sibling as-is.
    """
    expanded = list(roots)
    seen = {r.resolve() for r in roots if r.exists()}
    for r in roots:
        if r.name.startswith('.claude'):
            search_parent = r.parent
        elif r.parent.name.startswith('.claude'):
            search_parent = r.parent.parent
        else:
            search_parent = r.parent
        if not search_parent.exists():
            log.warning('--with-siblings-folders: parent does not exist: %s', search_parent)
            continue
        append_projects = (r.name == 'projects') or ((r / 'projects').is_dir())
        for sib in sorted(search_parent.glob('.claude*')):
            if not sib.is_dir():
                continue
            cand = sib / 'projects' if (append_projects and (sib / 'projects').is_dir()) else sib
            key = cand.resolve()
            if key in seen:
                continue
            seen.add(key)
            expanded.append(cand)
            log.info('--with-siblings-folders: added %s', cand)
    return expanded


def iter_jsonl_files(roots, since_dt, until_dt):
    cutoff = since_dt.timestamp() if since_dt else None
    # mtime upper bound omitted: a file can contain records earlier than its mtime, so --until is enforced per-record in parse_session.
    _ = until_dt  # signature kept symmetric with --since for future use
    seen = {}
    raw_count = 0
    for root in roots:
        if not root.exists():
            log.warning('projects dir not found: %s', root)
            continue
        for f in root.rglob('*.jsonl'):
            try:
                mtime = f.stat().st_mtime
                if cutoff and mtime < cutoff:
                    continue
                raw_count += 1
                key = f.name
                prev = seen.get(key)
                if prev is None or mtime > prev[1].stat().st_mtime:
                    seen[key] = (root, f)
            except OSError:
                continue
    log.info('jsonl candidates: %d (raw, before dedup), %d (kept after newest-mtime dedup), %d (dedup-skipped)',
             raw_count, len(seen), raw_count - len(seen))
    for root, f in seen.values():
        yield root, f


def _ts_in_window(ts, since_iso, until_iso):
    if not ts:
        return True
    if since_iso and ts < since_iso:
        return False
    if until_iso and ts > until_iso:
        return False
    return True


def parse_session(path, want_rules, since_iso=None, until_iso=None, want_skills=None):
    """Parse jsonl. Return (violations, stats, skill_cmds).

    skill_cmds: list of dicts, one per tool_use whose classify_skills() intersects want_skills.
    If want_skills is None, skill_cmds is [] (collection disabled).
    """
    file_reads = Counter()
    recent_tools = deque(maxlen=5)
    violations = []
    skill_cmds = []
    stats = {'tool_calls': 0, 'bash_calls': 0, 'read_calls': 0, 'msr_R_calls': 0, 'restore_calls': 0,
             'search_right': 0, 'search_wrong': 0, 'replace_right': 0, 'replace_wrong': 0,
             'err_calls': 0, 'duration_ms_sum': 0, 'out_bytes_sum': 0,
             'first_ts': '', 'last_ts': ''}
    msr_R_seen_at = None

    results = {}
    for line in open(path, 'r', encoding='utf-8'):
        try:
            d = json.loads(line)
        except Exception:
            continue
        t = d.get('type')
        if t == 'user':
            msg = d.get('message') or {}
            for b in (msg.get('content') or []):
                if isinstance(b, dict) and b.get('type') == 'tool_result':
                    tr = d.get('toolUseResult') or {}
                    is_err = bool(b.get('is_error', False))
                    content = b.get('content', '')
                    if isinstance(content, list):
                        content = ''.join((c.get('text', '') if isinstance(c, dict) else str(c)) for c in content)
                    content_bytes = len(content) if isinstance(content, str) else 0
                    if isinstance(tr, dict):
                        stdout = tr.get('stdout', '') or ''
                        stderr = tr.get('stderr', '') or ''
                        results[b.get('tool_use_id', '')] = {
                            'stdout': stdout, 'stderr': stderr,
                            'interrupted': bool(tr.get('interrupted', False)),
                            'is_error': is_err,
                            'duration_ms': int(tr.get('durationMs') or 0),
                            'out_bytes': max(len(stdout) + len(stderr), content_bytes),
                        }
                    else:
                        results[b.get('tool_use_id', '')] = {
                            'stdout': '', 'stderr': '', 'interrupted': False,
                            'is_error': is_err, 'duration_ms': 0, 'out_bytes': content_bytes,
                        }

    # Track which (uuid, tu_id) emitted violations so skill_cmds can carry the rule list inline.
    violations_by_blockkey = defaultdict(list)

    for line in open(path, 'r', encoding='utf-8'):
        try:
            d = json.loads(line)
        except Exception:
            continue
        if d.get('type') != 'assistant':
            continue
        msg = d.get('message') or {}
        cwd = d.get('cwd')
        uuid = d.get('uuid', '')
        ts = d.get('timestamp', '')
        if not _ts_in_window(ts, since_iso, until_iso):
            continue
        model = (msg.get('model') or '')
        usage = msg.get('usage') or {}
        tok_in = int(usage.get('input_tokens') or 0)
        tok_out = int(usage.get('output_tokens') or 0)
        prompt_id = d.get('promptId', '')
        session_id = d.get('sessionId', '')
        is_side = bool(d.get('isSidechain', False))
        for block in (msg.get('content') or []):
            if block.get('type') != 'tool_use':
                continue
            stats['tool_calls'] += 1
            tname = block.get('name', '')
            inp = block.get('input') or {}
            tu_id = block.get('id', '')
            cmd = inp.get('command', '') if tname == 'Bash' else ''
            res = results.get(tu_id) or {}
            if res:
                if res.get('is_error'):
                    stats['err_calls'] += 1
                stats['duration_ms_sum'] += int(res.get('duration_ms') or 0)
                stats['out_bytes_sum'] += int(res.get('out_bytes') or 0)
            if tname == 'Bash':
                stats['bash_calls'] += 1
                if ts:
                    if not stats['first_ts'] or ts < stats['first_ts']:
                        stats['first_ts'] = ts
                    if ts > stats['last_ts']:
                        stats['last_ts'] = ts
                if MSR_DASH_R.search(cmd):
                    stats['msr_R_calls'] += 1
                    msr_R_seen_at = uuid
                if 'Restore-GitLineEndings' in cmd:
                    stats['restore_calls'] += 1
                if CLASSIFY_SEARCH_RIGHT.search(cmd):
                    stats['search_right'] += 1
                if CLASSIFY_SEARCH_WRONG.search(cmd):
                    stats['search_wrong'] += 1
                if CLASSIFY_REPLACE_RIGHT.search(cmd):
                    stats['replace_right'] += 1
                if CLASSIFY_REPLACE_WRONG.search(cmd):
                    stats['replace_wrong'] += 1
                if MSR_TOOL_AT_START.search(cmd):
                    if res:
                        combined = (res.get('stderr') or '') + '\n' + (res.get('stdout') or '')
                        if 'R20' in want_rules and ERR_MARKERS.search(combined):
                            m_err = ERR_MARKERS.search(combined)
                            violations.append({'rule': 'R20', 'tag': 'msr-cmdline-error', 'fix': f'msr/gfind reported error: "{m_err.group(1)}" - fix command syntax',
                                               'uuid': uuid, 'ts': ts, 'cwd': cwd, 'cmd': cmd[:200]})
                            violations_by_blockkey[(uuid, tu_id)].append('R20')
                        elif 'R21' in want_rules and ZERO_MATCH.search(combined):
                            for vm in SP_VALUE.finditer(cmd):
                                val = vm.group(3) or vm.group(4) or vm.group(5) or ''
                                if val and REGEX_META.search(val):
                                    violations.append({'rule': 'R21', 'tag': 'regex-in-plaintext-flag',
                                                       'fix': f'{vm.group(1)} treats value as plain text; "{val}" looks like regex - use -t for regex',
                                                       'uuid': uuid, 'ts': ts, 'cwd': cwd, 'cmd': cmd[:200]})
                                    violations_by_blockkey[(uuid, tu_id)].append('R21')
                                    break
            if tname == 'Read':
                stats['read_calls'] += 1
                fp = inp.get('file_path', '')
                if fp:
                    file_reads[fp] += 1
                    if file_reads[fp] >= 2 and 'R12' in want_rules:
                        violations.append({'rule': 'R12', 'tag': 'reread-file', 'fix': 'file already in context; use msr -p file -t pattern -IC instead',
                                           'uuid': uuid, 'ts': ts, 'cwd': cwd, 'cmd': f'Read {fp} (#{file_reads[fp]})'})
                        violations_by_blockkey[(uuid, tu_id)].append('R12')
                recent_tools.append('Read')
                if list(recent_tools).count('Read') >= 3 and 'R13' in want_rules:
                    violations.append({'rule': 'R13', 'tag': 'consecutive-read-files', 'fix': 'fall back to search strategy after 3+ Read calls',
                                       'uuid': uuid, 'ts': ts, 'cwd': cwd, 'cmd': 'Read x3+ in a row'})
                    violations_by_blockkey[(uuid, tu_id)].append('R13')
                    recent_tools.clear()
            else:
                recent_tools.append(tname)

            for rule, tag, fix in check_tool_call(tname, inp, cwd):
                if rule not in want_rules:
                    continue
                violations.append({'rule': rule, 'tag': tag, 'fix': fix, 'uuid': uuid, 'ts': ts, 'cwd': cwd,
                                   'cmd': cmd if tname == 'Bash' else f'{tname} {inp.get("file_path") or inp.get("pattern") or ""}'.strip()})
                violations_by_blockkey[(uuid, tu_id)].append(rule)

            if want_skills:
                skills = classify_skills(tname, cmd)
                hit = skills & want_skills
                if hit:
                    display_cmd = cmd if tname == 'Bash' else (
                        f'{tname} {inp.get("file_path") or inp.get("pattern") or inp.get("url") or ""}'.strip()
                    )
                    skill_cmds.append({
                        'ts': ts,
                        'session': session_id,
                        'turn': prompt_id,
                        'uuid': uuid,
                        'model': model,
                        'skills': sorted(skills),
                        'tool': tname,
                        'rules': sorted(set(violations_by_blockkey.get((uuid, tu_id), []))),
                        'cmd': display_cmd,
                        'matched': parse_msr_stats(res.get('stderr', '')) if res else None,
                        'tok_in': tok_in,
                        'tok_out': tok_out,
                        'interrupted': res.get('interrupted', False),
                        'is_error': res.get('is_error', False),
                        'duration_ms': res.get('duration_ms', 0),
                        'out_bytes': res.get('out_bytes', 0),
                        'is_sidechain': is_side,
                        'cwd': cwd or '',
                    })

    if msr_R_seen_at and stats['restore_calls'] == 0 and 'R11' in want_rules:
        violations.append({'rule': 'R11', 'tag': 'msr-R-without-restore', 'fix': 'after msr -R run Restore-GitLineEndings.ps1 if git diff shows full-file rewrite',
                           'uuid': msr_R_seen_at, 'ts': '', 'cwd': '', 'cmd': f'session had {stats["msr_R_calls"]} msr -R calls, 0 restore'})
    return violations, stats, skill_cmds


RULE_TITLES = {
    'R1':  'msr -rp in git tree',
    'R2':  'gfind-* / find-ndp in non-git dir',
    'R3':  'single-file msr -p ... -PIC without strip-path suffix',
    'R4':  'shell-native search (grep/findstr/Select-String)',
    'R5':  'shell-native pipe (head/tail/wc/sort -u)',
    'R6':  'stderr redirect (2>&1 / 2>nul)',
    'R7':  'msr -R with non-ASCII arg',
    'R8':  'msr -t "."',
    'R9':  '-PIC on alias with built-in -I',
    'R10': 'nin -pd without --sum',
    'R11': 'msr -R without subsequent Restore-GitLineEndings',
    'R12': 'Read same file >=2 times',
    'R13': 'consecutive Read >=3',
    'R14': 'Grep/Glob in git repo',
    'R15': 'nin positional regex without capture group',
    'R18': 'msr -rp without -f (reads all file types)',
    'R19': 'msr -RK in git repo (use -R)',
    'R20': 'msr/gfind cmdline error (return -1 / invalid syntax)',
    'R21': '-x/--nx/--sp value looks like regex but flag is plain-text',
    'R24': 'grep/rg/findstr/find -name with ASCII-only pattern (use msr/gfind)',
    'R25': 'pipe uses awk/sed/cut/uniq/xargs/Where-Object/Group-Object (use msr/nin)',
    'R27': 'msr/gfind -d <int> looks like depth (use -k N; -d is sub-folder-name regex)',
    'R28': 'msr/gfind -f value contains "/" (filename only; use --pp for full-path regex)',
    'R29': '--xp/--xd/--xf value contains "|" (comma-separated plain text, not regex)',
    'R30': 'msr/gfind/nin -e is enhance/color-only (agent never sees color; always remove)',
    'R31': 'msr/gfind/nin piped to text tool without -C (ANSI colors leak)',
    'R32': 'nin -I = --info-normal-out (writes summary to stdout, opposite of msr -I)',
    'R33': '-H 0 / -H 1 without -T N (use -H 1 -T 1 for count+boundary, or -H 1 -J for existence)',
    'R34': '-o "$N" backreference (use \\\\1; $N expands as shell variable)',
    'R35': 'non-allowlisted find tool (only gfind-file / gfind-small / gfind-config / find-ndp allowed; else use msr -rp / msr -p)',
    'R37': 'msr -R confused with grep/rg -r (msr -R = REPLACE-FILE destructive; use lowercase -r / -rp for recursive search)',
    'R38': 'msr/nin/gfind-* chained with && or || without --exit (exit code = match-count, not 0/1; MSR_EXIT env may alter default; Linux/MacOS truncates -1 -> 255 and match-count > 255 wraps; add --exit with [Number] or [Regex-or-Math]-to-[Exit-Code], e.g. --exit gt0-to-0,le0-to-1,255-to-1 for portable semantics)',
    'R39': 'msr/nin/gfind-* without -C / --no-color (or short bundle containing C: -PIC / -IC / -PAC / -PICc): ANSI colors leak into stdout and break downstream regex / agent readability',
    'R40': 'gfind-*/find-ndp --xp contains obj/bin: /obj/, /bin/ are redundant (gitignored); bare obj/bin do unsafe substring match (also hits ObjectFactory/, Bindings/)',
    'R41': '--xp / --xd / --xf / --sp value has case-insensitive duplicate tokens (CSV is case-insensitive on Windows; deduplicate)',
    'R42': 'gfind-*/find-ndp invoked without any narrowing flag (-f / -t / -x / --pp / --np / --sp / --xp / --xd / -d): walks every file in tree',
    'F1': 'msr/nin unknown flag (not in cli-spec; verbose probe confirmed)',
    'F3': 'msr/nin duplicate flag (cannot be specified more than once)',
    'F4': 'msr/nin mutex conflict (both flags from same exclusive group present)',
    'F5': 'msr/nin missing required dependency (e.g. -B needs -F, -K needs -R)',
    'F6': 'msr/nin semantic misuse (e.g. -d / --nd value contains "/" or "\\")',
    'F7': 'msr/nin --sp/--xp value contains regex meta (CSV plain-text, not regex; paths never contain | () [] ? * +)',
    'F8': 'msr/nin -x/--nx value contains regex meta (plain-text flag; use -t/--nt for regex)',
    'F9': 'msr/nin -F/--time-format missing capture group "(...)"',
    'F10': 'msr/nin --pp/--np value contains literal "\\" outside known regex escape',
    'F11': 'msr/gfind without -t/-x/--nt/--nx and without -l (dumps full file contents)',
    'F12': 'msr short flag misused with grep/rg semantics (silent semantic shift: -A/-B/-C/-E/-F/-H/-L/-N/-U/-V/-f/-o/-v/-w/-x/-z)',
    'F13': 'spec-stale: flag recognized by msr/nin --verbose but missing from cli-spec/*-spec.json (only emitted by --probe-mode verbose-all)',
}


MSR_SKILL_RULES = {'R1','R3','R7','R8','R9','R10','R11','R15','R18','R19','R20','R21','R27','R28','R29','R30','R31','R32','R33','R34','R35','R37','R38','R39','R40','R41','R42','F1','F3','F4','F5','F6','F7','F8','F9','F10','F11','F12','F13'}


def _pct(part, total):
    return (part / total * 100) if total else 0.0


def _truncate(s, n):
    return s if len(s) <= n else s[:n - 3] + '...'


def compute_extra_stats(total_stats, by_rule, probe_mode='auto', since_iso=None, until_iso=None):
    extra = {}
    try:
        first = datetime.fromisoformat(total_stats['first_ts'].replace('Z', '+00:00'))
        last = datetime.fromisoformat(total_stats['last_ts'].replace('Z', '+00:00'))
        extra['span_days'] = (last - first).total_seconds() / 86400
        extra['first_ts'] = total_stats['first_ts'][:19]
        extra['last_ts'] = total_stats['last_ts'][:19]
    except Exception:
        extra['span_days'] = 0
        extra['first_ts'] = extra['last_ts'] = ''
    extra['probe_mode'] = probe_mode
    extra['window_since'] = since_iso or 'all'
    extra['window_until'] = until_iso or 'now'

    sr, sw = total_stats['search_right'], total_stats['search_wrong']
    rr, rw = total_stats['replace_right'], total_stats['replace_wrong']
    s_total, r_total = sr + sw, rr + rw
    extra['search_right'], extra['search_wrong'], extra['search_total'] = sr, sw, s_total
    extra['replace_right'], extra['replace_wrong'], extra['replace_total'] = rr, rw, r_total
    extra['search_correct_pct'] = _pct(sr, s_total)
    extra['search_wrong_pct'] = _pct(sw, s_total)
    extra['replace_correct_pct'] = _pct(rr, r_total)
    extra['replace_wrong_pct'] = _pct(rw, r_total)
    extra['msr_skill_errors'] = sum(len(by_rule[r]) for r in MSR_SKILL_RULES if r in by_rule)
    extra['msr_skill_error_pct'] = _pct(extra['msr_skill_errors'], sr)
    tc = total_stats.get('tool_calls', 0)
    ec = total_stats.get('err_calls', 0)
    extra['tool_calls'] = tc
    extra['err_calls'] = ec
    extra['err_pct'] = _pct(ec, tc)
    extra['duration_ms_sum'] = total_stats.get('duration_ms_sum', 0)
    extra['out_bytes_sum'] = total_stats.get('out_bytes_sum', 0)
    return extra


def _stats_lines_text(extra):
    return [
        '=== Skill Usage Stats ===',
        f'Time span              : {extra["first_ts"]}  ->  {extra["last_ts"]}  ({extra["span_days"]:.2f} days)',
        f'Window                 : {extra["window_since"]}  ->  {extra["window_until"]}',
        f'Probe mode             : {extra["probe_mode"]}',
        f'Search commands total  : {extra["search_total"]}  '
        f'(msr/gfind/nin: {extra["search_right"]} = {extra["search_correct_pct"]:.1f}%, '
        f'grep/find/rg: {extra["search_wrong"]} = {extra["search_wrong_pct"]:.1f}%)',
        f'Replace commands total : {extra["replace_total"]}  '
        f'(msr -R: {extra["replace_right"]} = {extra["replace_correct_pct"]:.1f}%, '
        f'sed -i/Set-Content: {extra["replace_wrong"]} = {extra["replace_wrong_pct"]:.1f}%)',
        f'msr-skill errors       : {extra["msr_skill_errors"]}  '
        f'({extra["msr_skill_error_pct"]:.1f}% of msr/gfind/nin commands)',
        f'Tool-result errors     : {extra["err_calls"]} / {extra["tool_calls"]}  ({extra["err_pct"]:.1f}% is_error=true)',
        f'Output bytes (sum)     : {extra["out_bytes_sum"] / 1024 / 1024:.2f} MB  (stdout+stderr of all tool_use)',
        f'WebFetch+other dur     : {extra["duration_ms_sum"] / 1000:.2f} s  (sum of toolUseResult.durationMs; Bash has none)',
        '',
    ]


def _stats_lines_md(extra):
    return [
        '## Skill Usage Stats',
        '',
        '| Metric | Value |',
        '|---|---|',
        f'| Time span | {extra["first_ts"]} → {extra["last_ts"]} ({extra["span_days"]:.2f} days) |',
        f'| Window | {extra["window_since"]} → {extra["window_until"]} |',
        f'| Probe mode | `{extra["probe_mode"]}` |',
        f'| Search commands (total) | {extra["search_total"]} |',
        f'| &nbsp;&nbsp;msr / gfind-* / nin (correct) | {extra["search_right"]} ({extra["search_correct_pct"]:.1f}%) |',
        f'| &nbsp;&nbsp;grep / find -name / rg / findstr / Select-String (wrong) | {extra["search_wrong"]} ({extra["search_wrong_pct"]:.1f}%) |',
        f'| Replace commands (total) | {extra["replace_total"]} |',
        f'| &nbsp;&nbsp;msr -R (correct) | {extra["replace_right"]} ({extra["replace_correct_pct"]:.1f}%) |',
        f'| &nbsp;&nbsp;sed -i / Set-Content / Out-File (wrong) | {extra["replace_wrong"]} ({extra["replace_wrong_pct"]:.1f}%) |',
        f'| msr-skill error count | {extra["msr_skill_errors"]} |',
        f'| msr-skill error rate | {extra["msr_skill_error_pct"]:.1f}% of msr/gfind/nin commands |',
        f'| Tool-result errors (is_error=true) | {extra["err_calls"]} / {extra["tool_calls"]} ({extra["err_pct"]:.1f}%) |',
        f'| Output bytes (stdout+stderr sum) | {extra["out_bytes_sum"] / 1024 / 1024:.2f} MB |',
        f'| WebFetch+other duration (sum) | {extra["duration_ms_sum"] / 1000:.2f} s (Bash has no durationMs) |',
        '',
    ]


def render_text(by_rule, total_stats, all_violations, files_scanned, session_count, top, extra=None):
    out = []
    out.append('=== Scan summary ===')
    out.append(f'Files scanned          : {files_scanned}')
    out.append(f'Sessions w/ violations : {session_count}')
    out.append(f'Total tool calls       : {total_stats["tool_calls"]}')
    out.append(f'  Bash                 : {total_stats["bash_calls"]}')
    out.append(f'  Read                 : {total_stats["read_calls"]}')
    out.append(f'  msr -R               : {total_stats["msr_R_calls"]}')
    out.append(f'  Restore script       : {total_stats["restore_calls"]}')
    out.append(f'Total violations       : {len(all_violations)}')
    out.append('')
    if extra:
        out.extend(_stats_lines_text(extra))
    out.append('=== By rule ===')
    for rule in sorted(by_rule, key=lambda r: (-len(by_rule[r]), r)):
        out.append(f'  {rule:<4} {len(by_rule[rule]):>5}   {RULE_TITLES.get(rule, "?")}')
    out.append('')
    for rule in sorted(by_rule, key=lambda r: (-len(by_rule[r]), r)):
        items = by_rule[rule]
        out.append(f'=== {rule} {RULE_TITLES.get(rule, "?")} ({len(items)} total, top {min(top, len(items))}) ===')
        for v in items[:top]:
            cmd = _truncate(v['cmd'], 200)
            out.append(f'  {v["file"]}  {v["ts"][:19]}')
            out.append(f'    cwd: {v.get("cwd","")}')
            out.append(f'    cmd: {cmd}')
            out.append(f'    fix: {v["fix"]}')
        out.append('')
    return '\n'.join(out)


def render_md(by_rule, total_stats, all_violations, files_scanned, session_count, top, extra=None):
    out = []
    out.append('# Agent Search-Tool Skill Violations')
    out.append('')
    out.append(f'Generated: {datetime.now().strftime("%Y-%m-%d %H:%M:%S")}')
    out.append('')
    out.append('## Scan Summary')
    out.append('')
    out.append('| Metric | Value |')
    out.append('|---|---:|')
    out.append(f'| Files scanned | {files_scanned} |')
    out.append(f'| Sessions w/ violations | {session_count} |')
    out.append(f'| Total tool calls | {total_stats["tool_calls"]} |')
    out.append(f'| Bash calls | {total_stats["bash_calls"]} |')
    out.append(f'| Read calls | {total_stats["read_calls"]} |')
    out.append(f'| msr -R calls | {total_stats["msr_R_calls"]} |')
    out.append(f'| Restore script calls | {total_stats["restore_calls"]} |')
    out.append(f'| **Total violations** | **{len(all_violations)}** |')
    out.append('')
    if extra:
        out.extend(_stats_lines_md(extra))
    out.append('## By Rule (ranked)')
    out.append('')
    out.append('| Rule | Count | Title |')
    out.append('|---|---:|---|')
    for rule in sorted(by_rule, key=lambda r: (-len(by_rule[r]), r)):
        out.append(f'| {rule} | {len(by_rule[rule])} | {RULE_TITLES.get(rule, "?")} |')
    out.append('')
    for rule in sorted(by_rule, key=lambda r: (-len(by_rule[r]), r)):
        items = by_rule[rule]
        out.append(f'## {rule} — {RULE_TITLES.get(rule, "?")} ({len(items)} total, top {min(top, len(items))})')
        out.append('')
        for v in items[:top]:
            cmd = _truncate(v['cmd'], 300)
            out.append(f'- `{v["file"]}` @ {v["ts"][:19]}')
            out.append(f'  - cwd: `{v.get("cwd","")}`')
            out.append(f'  - cmd: `{cmd}`')
            out.append(f'  - fix: {v["fix"]}')
        out.append('')
    return '\n'.join(out)


def _merge_stats(total, s):
    for k, v in s.items():
        if k == 'first_ts':
            if v and (not total[k] or v < total[k]):
                total[k] = v
        elif k == 'last_ts':
            if v and v > total[k]:
                total[k] = v
        else:
            total[k] += v


SKILL_SHORT = {'smart-search': 'srch', 'safe-replace': 'rplc', 'set-mining': 'mine'}


def _short_model(m):
    if not m:
        return ''
    m = m.replace('claude-', '').replace('-internal', '')
    m = re.sub(r'-\d{8}$', '', m)
    m = re.sub(r'-1m$', '', m)
    return m


def _fmt_tokens(n):
    if n >= 1000:
        return f'{n / 1000:.0f}k'
    return str(n)


COLUMN_DEFS = {
    'ts':           ('UTC timestamp (HH:MM:SS or date+time)',  lambda r: r['ts'][:19].replace('T', ' ')),
    'session':      ('sessionId first 8 chars',                lambda r: (r.get('session') or '')[:8]),
    'turn':         ('promptId first 8 chars',                 lambda r: (r.get('turn') or '')[:8]),
    'skills':       ('CSV of smart-search/safe-replace/set-mining', lambda r: ','.join(SKILL_SHORT.get(s, s) for s in r['skills'])),
    'tool':         ('Bash / Read / Edit / Grep / Glob / Write', lambda r: r['tool']),
    'rules':        ('violated rule ids CSV or ✓',             lambda r: ','.join(r['rules']) if r['rules'] else '✓'),
    'cmd':          ('tool input (truncated 200 chars)',       lambda r: _truncate(r['cmd'], 200)),
    'cwd':          ('working directory (last 2 segments)',    lambda r: '/'.join((r.get('cwd') or '').replace('\\', '/').rstrip('/').split('/')[-2:])),
    'model':        ('message.model (short form)',             lambda r: _short_model(r.get('model', ''))),
    'tok_in':       ('input_tokens (k-formatted)',             lambda r: _fmt_tokens(r.get('tok_in', 0))),
    'tok_out':      ('output_tokens',                          lambda r: str(r.get('tok_out', 0))),
    'matched':      ('msr stderr stats "NL/MF Xs"',            lambda r: r.get('matched') or '-'),
    'err':          ('tool_result.is_error (✗ / ·)',           lambda r: '✗' if r.get('is_error') else '·'),
    'dur_ms':       ('toolUseResult.durationMs (WebFetch etc.; - if absent)', lambda r: str(r.get('duration_ms')) if r.get('duration_ms') else '-'),
    'out_kb':       ('len(stdout)+len(stderr) in KB',          lambda r: f'{r.get("out_bytes", 0) / 1024:.1f}' if r.get('out_bytes') else '0'),
    'interrupted':  ('user-interrupted flag (✓ / ·)',          lambda r: '✓' if r.get('interrupted') else '·'),
    'is_sidechain': ('Task sub-agent flag (✓ / ·)',            lambda r: '✓' if r.get('is_sidechain') else '·'),
    'uuid':         ('full record uuid (debug only)',          lambda r: r.get('uuid', '')),
    'file':         ('jsonl filename',                         lambda r: r.get('file', '')),
}

PRESETS = {
    'compact':  ['ts', 'skills', 'tool', 'rules', 'cmd'],
    'standard': ['ts', 'session', 'skills', 'tool', 'rules', 'cmd', 'cwd'],
    'wide':     ['ts', 'session', 'turn', 'model', 'skills', 'tool', 'rules', 'matched', 'err', 'dur_ms', 'out_kb', 'tok_in', 'tok_out', 'interrupted', 'cmd', 'cwd'],
    'debug':    list(COLUMN_DEFS.keys()),
}


def resolve_columns(view, columns_spec):
    base = list(PRESETS.get(view, PRESETS['standard']))
    if not columns_spec:
        return base
    if columns_spec.startswith('+') or columns_spec.startswith('-') or any(p.startswith(('+', '-')) for p in columns_spec.split(',')):
        cols = list(base)
        for p in columns_spec.split(','):
            p = p.strip()
            if not p:
                continue
            if p.startswith('+'):
                name = p[1:]
                if name not in COLUMN_DEFS:
                    raise argparse.ArgumentTypeError(f'unknown column "{name}" (see --list-columns)')
                if name not in cols:
                    cols.append(name)
            elif p.startswith('-'):
                name = p[1:]
                cols = [c for c in cols if c != name]
            else:
                raise argparse.ArgumentTypeError(f'mixed absolute + relative in --columns: "{p}" (use all-absolute or all-+/-)')
        return cols
    cols = [c.strip() for c in columns_spec.split(',') if c.strip()]
    for c in cols:
        if c not in COLUMN_DEFS:
            raise argparse.ArgumentTypeError(f'unknown column "{c}" (see --list-columns)')
    return cols


def render_skills_md(skill_cmds, cols, total_stats, files_scanned, want_skills, since_iso, until_iso):
    out = []
    out.append('# Agent Skill Command Inventory')
    out.append('')
    out.append(f'Generated: {datetime.now().strftime("%Y-%m-%d %H:%M:%S")}')
    out.append(f'Window: {since_iso or "all"} → {until_iso or "now"}')
    out.append(f'Probe mode: `{_PROBE_MODE}`')
    out.append(f'Filter: {",".join(sorted(want_skills))}')
    out.append('')
    out.append('## Scan Summary')
    out.append('')
    out.append('| Metric | Value |')
    out.append('|---|---:|')
    out.append(f'| Files scanned | {files_scanned} |')
    out.append(f'| Total tool calls | {total_stats["tool_calls"]} |')
    out.append(f'| Skill commands matched | {len(skill_cmds)} |')
    out.append('')

    per_skill = defaultdict(lambda: {'total': 0, 'violations': 0, 'interrupt': 0, 'tok_out_sum': 0})
    for r in skill_cmds:
        for s in r['skills']:
            if s not in want_skills:
                continue
            per_skill[s]['total'] += 1
            if r['rules']:
                per_skill[s]['violations'] += 1
            if r.get('interrupted'):
                per_skill[s]['interrupt'] += 1
            per_skill[s]['tok_out_sum'] += r.get('tok_out', 0)
    out.append('## Per-Skill Summary')
    out.append('')
    out.append('| Skill | Cmds | Violations | Viol % | Interrupt % | Avg tok_out |')
    out.append('|---|---:|---:|---:|---:|---:|')
    for s in SKILL_NAMES:
        if s not in per_skill:
            continue
        d = per_skill[s]
        n = d['total']
        viol_pct = (d['violations'] / n * 100) if n else 0.0
        int_pct = (d['interrupt'] / n * 100) if n else 0.0
        avg_tok = (d['tok_out_sum'] / n) if n else 0
        out.append(f'| {s} | {n} | {d["violations"]} | {viol_pct:.1f}% | {int_pct:.1f}% | {avg_tok:.0f} |')
    out.append('')

    per_model = defaultdict(lambda: {'total': 0, 'violations': 0})
    for r in skill_cmds:
        m = _short_model(r.get('model', ''))
        per_model[m]['total'] += 1
        if r['rules']:
            per_model[m]['violations'] += 1
    if len(per_model) > 1:
        out.append('## Per-Model Summary')
        out.append('')
        out.append('| Model | Cmds | Viol % |')
        out.append('|---|---:|---:|')
        for m, d in sorted(per_model.items(), key=lambda x: -x[1]['total']):
            pct = (d['violations'] / d['total'] * 100) if d['total'] else 0.0
            out.append(f'| {m or "(none)"} | {d["total"]} | {pct:.1f}% |')
        out.append('')

    for skill in SKILL_NAMES:
        if skill not in want_skills:
            continue
        items = [r for r in skill_cmds if skill in r['skills']]
        if not items:
            continue
        out.append(f'## {skill} ({len(items)} commands)')
        out.append('')
        header = '| ' + ' | '.join(cols) + ' |'
        sep = '|' + '|'.join(['---'] * len(cols)) + '|'
        out.append(header)
        out.append(sep)
        for r in items:
            row = [str(COLUMN_DEFS[c][1](r)).replace('|', '\\|').replace('\n', ' ') for c in cols]
            out.append('| ' + ' | '.join(row) + ' |')
        out.append('')
    return '\n'.join(out)


def render_skills_json(skill_cmds, cols, total_stats, files_scanned, want_skills, since_iso, until_iso):
    return json.dumps({
        'generated': datetime.now().isoformat(timespec='seconds'),
        'window': {'since': since_iso, 'until': until_iso},
        'filter_skills': sorted(want_skills),
        'columns': cols,
        'files_scanned': files_scanned,
        'total_tool_calls': total_stats['tool_calls'],
        'skill_cmds_matched': len(skill_cmds),
        'commands': skill_cmds,
    }, indent=2, ensure_ascii=False)


def main():
    t0 = time.perf_counter()
    ap = argparse.ArgumentParser(description='Analyze agent search-tool history for skill violations and command inventory.')
    ap.add_argument('--projects-dir', default=str(PROJECTS_DIR),
                    help='comma-separated list of ~/.claude/projects-style dirs to scan (default: ~/.claude/projects)')
    ap.add_argument('--with-siblings-folders', default='false',
                    help='also scan sibling ".claude*" dirs of each --projects-dir entry. For input ~/.claude/projects or '
                         '~/.claude, expand to ~/.claude-bak/projects, ~/.claude-bak2/projects, etc. For inputs outside '
                         'any .claude* dir (e.g. ~/Downloads/cld-history), look in the same parent for .claude* siblings. '
                         'Same-level only (no recursion). Truthy values: 1 / true / yes. Default: false.')
    ap.add_argument('--since', default='9d',
                    help='start of time window. Duration: 30m / 2h / 7d / 1w; "0" = no lower bound (full history); '
                         'or ISO date: 2026-05-24 / "2026-05-24 14:00". Default: 9d')
    ap.add_argument('--until', default=None,
                    help='end of time window. Same format as --since. Default: now (no upper bound)')
    ap.add_argument('--rules', default='all', help='comma-separated rule ids (R1,R3,...) or "all"')
    ap.add_argument('--session', help='filter by sessionId substring')
    ap.add_argument('--cwd', help='filter by cwd substring')
    ap.add_argument('--top', type=int, default=10, help='show top N violations per rule')
    ap.add_argument('--probe-mode', default='auto', choices=['auto', 'verbose-all', 'spec-only'],
                    help='How to validate unknown flags against msr/nin --verbose. '
                         'auto (default): run --verbose only when spec-table flags a candidate; fast. '
                         'verbose-all: run --verbose on every msr/nin invocation, cross-validate spec-table, '
                         'emit F13 for spec-stale flags; slowest, most accurate; use for full-history audits. '
                         'spec-only: never run --verbose; pure spec-table; fastest, but candidate flags become F1 '
                         'without confirmation. Useful when msr/nin binaries are not on PATH.')
    ap.add_argument('--probe-cache', default='true',
                    help='in-process cache for --verbose probes, keyed by (tool, sorted flag-shape). '
                         'Probe output depends only on which flag tokens are present, not their values, so two '
                         'invocations with identical flag shape but different paths/patterns share one subprocess. '
                         'Set false to disable (useful for benchmarking the no-cache baseline). '
                         'Truthy: 1 / true / yes. Default: true.')
    ap.add_argument('--skills', default=None,
                    help='enable skill-command inventory mode. CSV of: smart-search,safe-replace,set-mining,all '
                         '(default: violations-only mode). Use "all" for all 3.')
    ap.add_argument('--view', default='standard', choices=list(PRESETS.keys()),
                    help='column preset for --skills mode: compact / standard / wide / debug. Default: standard')
    ap.add_argument('--columns', default=None,
                    help='override --view columns. CSV absolute: "ts,cmd"; or +/- relative to preset: "+model,-cwd". '
                         'See --list-columns.')
    ap.add_argument('--list-columns', action='store_true',
                    help='print available columns + presets and exit')
    ap.add_argument('--json', action='store_true', help='emit JSON (legacy; equivalent to -o <tmp>.json)')
    ap.add_argument('-o', '--output', default=None,
                    help='output target: "console" for stdout, or a file path (extension .md/.json picks format). '
                         'Default: auto-write .md to system temp dir')
    args = ap.parse_args()

    global _PROBE_MODE
    _PROBE_MODE = args.probe_mode
    _set_probe_cache_enabled(args.probe_cache.strip().lower() in ('1', 'true', 'yes'))

    if args.list_columns:
        print('Available columns:')
        for name, (desc, _) in COLUMN_DEFS.items():
            print(f'  {name:<14} {desc}')
        print('\nPresets:')
        for name, cols in PRESETS.items():
            print(f'  {name:<10} {", ".join(cols)}')
        return

    want = set(RULE_TITLES.keys()) if args.rules == 'all' else set(args.rules.split(','))
    roots = [Path(p.strip()).expanduser() for p in args.projects_dir.split(',') if p.strip()]
    if args.with_siblings_folders.strip().lower() in ('1', 'true', 'yes'):
        roots = _expand_claude_siblings(roots)
    try:
        since_dt = parse_time(args.since)
        until_dt = parse_time(args.until)
    except argparse.ArgumentTypeError as e:
        ap.error(str(e))

    want_skills = None
    cols = None
    if args.skills:
        if args.skills.strip().lower() == 'all':
            want_skills = set(SKILL_NAMES)
        else:
            want_skills = {s.strip() for s in args.skills.split(',') if s.strip()}
            bad = want_skills - set(SKILL_NAMES)
            if bad:
                ap.error(f'unknown skill(s): {",".join(sorted(bad))}. Valid: {",".join(SKILL_NAMES)},all')
        try:
            cols = resolve_columns(args.view, args.columns)
        except argparse.ArgumentTypeError as e:
            ap.error(str(e))
    # jsonl `timestamp` field is UTC with trailing 'Z' (e.g. "2026-05-23T23:23:14.774Z"); convert local naive -> UTC for string comparison
    _local_tz = datetime.now().astimezone().tzinfo
    since_iso = since_dt.replace(tzinfo=_local_tz).astimezone(timezone.utc).strftime('%Y-%m-%dT%H:%M:%S.000Z') if since_dt else None
    until_iso = until_dt.replace(tzinfo=_local_tz).astimezone(timezone.utc).strftime('%Y-%m-%dT%H:%M:%S.999Z') if until_dt else None
    log.info('Scanning %d root(s), since=%s, until=%s, rules=%s, skills=%s, view=%s',
             len(roots), since_iso or 'all', until_iso or 'now', args.rules,
             ','.join(sorted(want_skills)) if want_skills else 'off', args.view if want_skills else '-')

    all_violations = []
    all_skill_cmds = []
    total_stats = defaultdict(int)
    total_stats['first_ts'] = ''
    total_stats['last_ts'] = ''
    session_count = 0
    files_scanned = 0
    for root, f in iter_jsonl_files(roots, since_dt, until_dt):
        if args.session and args.session not in f.stem:
            continue
        files_scanned += 1
        v, s, sk = parse_session(f, want, since_iso=since_iso, until_iso=until_iso, want_skills=want_skills)
        if args.cwd:
            v = [x for x in v if x.get('cwd') and args.cwd.lower() in x['cwd'].lower()]
            sk = [x for x in sk if x.get('cwd') and args.cwd.lower() in x['cwd'].lower()]
        if v:
            session_count += 1
            for x in v:
                x['file'] = str(f.relative_to(root))
            all_violations.extend(v)
        for x in sk:
            x['file'] = str(f.relative_to(root))
        all_skill_cmds.extend(sk)
        _merge_stats(total_stats, s)

    by_rule = defaultdict(list)
    for v in all_violations:
        by_rule[v['rule']].append(v)

    extra = compute_extra_stats(total_stats, by_rule, probe_mode=args.probe_mode, since_iso=since_iso, until_iso=until_iso)

    target = args.output
    if not target:
        ext = 'json' if args.json else 'md'
        prefix = 'analyze-agent-skills-inventory' if want_skills else 'analyze-agent-skills'
        target = str(Path(tempfile.gettempdir()) / f'{prefix}-{datetime.now():%Y%m%d-%H%M%S}.{ext}')

    fmt = 'md'
    lower = target.lower()
    if lower.endswith('.json') or args.json:
        fmt = 'json'
    elif lower.endswith('.txt'):
        fmt = 'text'
    elif lower.endswith('.md') or target == 'console':
        fmt = 'md'

    if want_skills:
        if fmt == 'json':
            content = render_skills_json(all_skill_cmds, cols, total_stats, files_scanned, want_skills, since_iso, until_iso)
        else:
            content = render_skills_md(all_skill_cmds, cols, total_stats, files_scanned, want_skills, since_iso, until_iso)
    elif fmt == 'json':
        content = json.dumps({'stats': dict(total_stats), 'extra': extra, 'files_scanned': files_scanned,
                              'sessions_with_violations': session_count,
                              'violations': all_violations}, indent=2, ensure_ascii=False)
    elif fmt == 'text':
        content = render_text(by_rule, total_stats, all_violations, files_scanned, session_count, args.top, extra)
    else:
        content = render_md(by_rule, total_stats, all_violations, files_scanned, session_count, args.top, extra)

    if target == 'console':
        print(content)
    else:
        Path(target).write_text(content, encoding='utf-8')
        log.info('Wrote %s report -> %s', fmt, target)

    elapsed = time.perf_counter() - t0
    if want_skills:
        log.info('SUMMARY: files=%d sessions_seen=%d tool_calls=%d skill_cmds=%d (skills=%s) | elapsed=%.2fs',
                 files_scanned, session_count, total_stats['tool_calls'], len(all_skill_cmds),
                 ','.join(sorted(want_skills)), elapsed)
    else:
        log.info('SUMMARY: files=%d sessions=%d tool_calls=%d violations=%d (msr-skill=%d=%.1f%%) | '
                 'search=%d (correct=%.1f%%, wrong=%.1f%%) | replace=%d (correct=%.1f%%, wrong=%.1f%%) | '
                 'span=%.2fd | elapsed=%.2fs',
                 files_scanned, session_count, total_stats['tool_calls'], len(all_violations),
                 extra['msr_skill_errors'], extra['msr_skill_error_pct'],
                 extra['search_total'], extra['search_correct_pct'], extra['search_wrong_pct'],
                 extra['replace_total'], extra['replace_correct_pct'], extra['replace_wrong_pct'],
                 extra['span_days'], elapsed)
    pc_calls, pc_hits, pc_rate, pc_keys = _probe_cache_stats()
    if pc_calls:
        log.info('Probe cache: %d calls, %d hits (%.1f%%), %d unique flag-shape keys [probe-mode=%s]',
                 pc_calls, pc_hits, pc_rate * 100, pc_keys, _PROBE_MODE)


if __name__ == '__main__':
    main()
