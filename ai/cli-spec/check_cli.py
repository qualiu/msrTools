"""CLI argument violation checker for msr / nin / gfind-* / find-* commands.

Detects (F2 omitted -- msr self-reports type errors via non-zero exit):
  F1  unknown-flag       flag not in spec (verified via --verbose probe)
  F3  duplicate-flag     same flag specified >=2 times
  F4  mutex-conflict     two flags from same mutex group both present
  F5  missing-required   flag needs dependency flag that is absent
  F6  semantic-misuse    arg value syntactically valid but semantically wrong (e.g. -d with '/')
  F7  CSV-plain regex    --sp / --xp value contains regex meta (these are CSV plain-text)
  F8  plain-text regex   -x / --nx value contains regex meta (suspicious)
  F9  -F no capture      --time-format missing "(...)" capture group
  F10 path literal "\\"   --pp / --np contains literal "\\" outside known escapes (suspicious)
  F11 no content filter  msr/gfind without -t/-x/--nt/--nx and without -l -> dumps full file contents
  F12 grep-flag-misuse   short flag exists in msr but used with grep semantics (silent semantic shift)

Public API:
  check_command(cmdline: str) -> list[Violation]
"""

import importlib.util
import json
import re
import shlex
import subprocess
from dataclasses import dataclass
from pathlib import Path

HERE = Path(__file__).parent

_SPEC_CACHE = {}
_EXTRA_CACHE = {}
_PROBE_CACHE = {}
_PROBE_STATS = {'calls': 0, 'hits': 0}
_PROBE_CACHE_ENABLED = True


def set_probe_cache_enabled(enabled):
    """Toggle the flag-shape probe cache globally. Default: enabled.
    Disabling forces every _verbose_probe call to spawn a fresh subprocess --
    useful for benchmarking or when investigating cache-correctness suspicions."""
    global _PROBE_CACHE_ENABLED
    _PROBE_CACHE_ENABLED = bool(enabled)


def reset_probe_cache():
    """Clear cache + stats. Call between independent benchmark runs."""
    _PROBE_CACHE.clear()
    _PROBE_STATS['calls'] = 0
    _PROBE_STATS['hits'] = 0

DANGER_SINGLE_CHARS = {'R', 'X'}
DANGER_LONG = {'--replace-file', '--execute-out-lines'}
PATH_ARG_FLAGS = {'-p', '-w', '--path', '--read-paths'}

CSV_PLAIN_FLAGS = {'--sp', '--xp'}
PLAIN_TEXT_FLAGS = {'--has-text', '--nx'}
PATH_REGEX_FLAGS = {'--pp', '--np'}

CONTENT_FILTER_FLAGS = {'--text-match', '--no-text-match', '--has-text', '--nx'}
LIST_MODE_FLAGS = {'--list-count'}
NO_FILE_INPUT_FLAGS = {'--string'}
RE_CSV_PLAIN_META = re.compile(r'[|()\[\]?*+{]|\\[bdswBDSW]')
RE_PLAIN_META_HARD = re.compile(r'\||\\[bdswBDSW]')
RE_PLAIN_META_SOFT = re.compile(r'[(\[{]')
RE_KNOWN_ESCAPE = re.compile(r'\\[bBdDsSwW.()\[\]{}|+*?^$/\\nrtv0-9]')
RE_TOOL_NAME = re.compile(r'^(msr|nin|gfind-[\w-]+|find-(?:ndp|py|cs|doc|small|all|file|alias|top-folder|top-type))$')


def _sanitize_for_probe(tokens):
    """Strip -R/-X/-V (and combined-short forms containing R/X/V) and neutralize path args
    so a verbose probe never writes files or executes commands."""
    out = []
    i = 0
    while i < len(tokens):
        tok = tokens[i]
        if re.match(r'^-[a-zA-Z]{2,}$', tok):
            if any(c in DANGER_SINGLE_CHARS for c in tok[1:]):
                i += 1
                continue
            out.append(tok)
            i += 1
            continue
        if tok in ('-R', '-X'):
            i += 1
            continue
        if tok in DANGER_LONG:
            i += 1
            continue
        if tok in PATH_ARG_FLAGS and i + 1 < len(tokens):
            out.append(tok)
            out.append('nul')
            i += 2
            continue
        out.append(tok)
        i += 1
    return out


def _probe_cache_key(tool_canonical, sanitized_tokens):
    """Cache key = (tool, sorted unique flag tokens). Values are irrelevant: the probe's
    output (set of long-names msr/nin recognized) depends only on which flag tokens are
    present, not on their argument values. Two commands `msr -p A -t foo` and
    `msr -p B -t bar` produce identical `recognized` sets, so they share a cache entry."""
    flags = tuple(sorted({t for t in sanitized_tokens if t.startswith('-')}))
    return (tool_canonical, flags)


def _verbose_probe(tool_canonical, sanitized_tokens):
    """Run `<tool> <sanitized-args> --verbose -PIC` and return set of long-names msr/nin
    actually recognized (from `Begin args verbose` block in stderr).
    Returns None on probe failure. Cached by flag-shape signature (see _probe_cache_key)."""
    _PROBE_STATS['calls'] += 1
    key = _probe_cache_key(tool_canonical, sanitized_tokens) if _PROBE_CACHE_ENABLED else None
    if key is not None and key in _PROBE_CACHE:
        _PROBE_STATS['hits'] += 1
        return _PROBE_CACHE[key]
    cmd = [tool_canonical] + sanitized_tokens + ['--verbose', '-PIC']
    if tool_canonical == 'msr' and '-z' not in sanitized_tokens and '--string' not in sanitized_tokens:
        cmd += ['-z', '']
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, encoding='utf-8',
                           errors='replace', timeout=5)
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
        if key is not None:
            _PROBE_CACHE[key] = None
        return None
    in_block = False
    recognized = set()
    for line in p.stderr.splitlines():
        if 'Begin args verbose' in line:
            in_block = True
            continue
        if 'End args verbose' in line:
            break
        if not in_block:
            continue
        m = re.match(r'^--([\w-]+)\s*=', line)
        if m:
            recognized.add('--' + m.group(1))
    result = recognized if in_block else None
    if key is not None:
        _PROBE_CACHE[key] = result
    return result


def probe_cache_stats():
    """Return (calls, hits, hit_rate, unique_keys) — caller can log after a run."""
    c, h = _PROBE_STATS['calls'], _PROBE_STATS['hits']
    return c, h, (h / c if c else 0.0), len(_PROBE_CACHE)


@dataclass
class Violation:
    code: str
    tool: str
    flag: str
    value: str
    msg: str
    severity: str = 'error'

    def to_dict(self):
        return {'code': self.code, 'severity': self.severity, 'tool': self.tool,
                'flag': self.flag, 'value': self.value, 'msg': self.msg}


def _load_spec(tool):
    """tool in {'msr', 'nin'}. gfind-*/find-* alias to msr (they wrap msr)."""
    if tool in _SPEC_CACHE:
        return _SPEC_CACHE[tool]
    path = HERE / f'{tool}-spec.json'
    if not path.exists():
        _SPEC_CACHE[tool] = None
        return None
    spec = json.loads(path.read_text(encoding='utf-8'))
    short_to_long = {v['short']: k for k, v in spec.items() if v.get('short')}
    _SPEC_CACHE[tool] = {'flags': spec, 'short_to_long': short_to_long}
    return _SPEC_CACHE[tool]


def _load_extra(tool):
    if tool in _EXTRA_CACHE:
        return _EXTRA_CACHE[tool]
    path = HERE / f'{tool}-extra.py'
    if not path.exists():
        _EXTRA_CACHE[tool] = {'CONSTRAINTS': {}, 'MUTEX_GROUPS': {}}
        return _EXTRA_CACHE[tool]
    spec = importlib.util.spec_from_file_location(f'{tool}_extra', path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    _EXTRA_CACHE[tool] = {
        'CONSTRAINTS': getattr(mod, 'CONSTRAINTS', {}),
        'MUTEX_GROUPS': getattr(mod, 'MUTEX_GROUPS', {}),
    }
    return _EXTRA_CACHE[tool]


def _split_invocations(cmdline):
    """Tokenize whole cmdline (quoting-aware) and yield (canonical, actual, args_tokens) per tool invocation.
    Pipes / && / ; are token-level separators after a tool name; quoted "|" stays attached to its flag."""
    try:
        all_tokens = shlex.split(cmdline, posix=True)
    except ValueError:
        try:
            all_tokens = shlex.split(cmdline, posix=False)
        except ValueError:
            all_tokens = cmdline.split()
    i = 0
    while i < len(all_tokens):
        tok = all_tokens[i]
        m = RE_TOOL_NAME.match(tok)
        if not m:
            i += 1
            continue
        actual = tok
        canonical = 'nin' if actual == 'nin' else 'msr'
        j = i + 1
        args_tokens = []
        while j < len(all_tokens):
            t = all_tokens[j]
            if t in ('|', '||', '&&', ';', '&', '>', '>>', '<', '2>', '2>>', '&>', '&>>'):
                break
            args_tokens.append(t)
            j += 1
        yield canonical, actual, args_tokens
        i = j + 1


def _expand_combined_short(tok, spec):
    """Treat tokens like '-PIC' as combined short flags if every char is a known single-letter short flag."""
    if not (tok.startswith('-') and not tok.startswith('--') and len(tok) > 2):
        return [tok]
    if any(not c.isalpha() for c in tok[1:]):
        return [tok]
    short_to_long = spec['short_to_long']
    if all(f'-{c}' in short_to_long for c in tok[1:]):
        return [f'-{c}' for c in tok[1:]]
    return [tok]


def _parse_flags(tokens, spec):
    """Return list of (canonical_long, value_or_None, original_token)."""
    if spec is None:
        return []
    flags_def = spec['flags']
    s2l = spec['short_to_long']
    out = []
    i = 0
    skip_parsing = False
    while i < len(tokens):
        tok = tokens[i]
        if skip_parsing:
            i += 1
            continue
        if tok == '--%':
            skip_parsing = True
            i += 1
            continue
        if not tok.startswith('-') or tok == '-' or tok == '--':
            i += 1
            continue
        expanded = _expand_combined_short(tok, spec)
        for j, ftok in enumerate(expanded):
            canonical = None
            if ftok.startswith('--'):
                if ftok in flags_def:
                    canonical = ftok
            else:
                canonical = s2l.get(ftok)
            if canonical is None:
                out.append((ftok, None, ftok))
                continue
            takes_arg = flags_def[canonical].get('takes_arg', False)
            if takes_arg and j == len(expanded) - 1 and i + 1 < len(tokens):
                value = tokens[i + 1]
                out.append((canonical, value, ftok))
                i += 1
            else:
                out.append((canonical, None, ftok))
        i += 1
    return out


def check_command(cmdline, probe_mode='auto'):
    """Return list[Violation] across all msr/nin invocations in cmdline.

    probe_mode:
      'auto'        -- spec-table first; verbose probe only if candidate_f1 non-empty
                       (default; fast for everyday use).
      'verbose-all' -- always run msr/nin --verbose for every invocation; cross-validate
                       spec-table. Emits F13 for flags that --verbose recognizes but
                       spec.json missed (spec-stale signal). Slowest, most accurate;
                       use for one-off full-history audits.
      'spec-only'   -- never run --verbose; pure spec-table. candidate_f1 -> F1 with no
                       confirmation (fastest; more false positives if spec stale).
                       Use for CI / offline runs without msr/nin binaries available.
    """
    violations = []
    for canonical, actual, tokens in _split_invocations(cmdline):
        spec = _load_spec(canonical)
        extra = _load_extra(canonical)
        if spec is None:
            continue
        parsed = _parse_flags(tokens, spec)

        candidate_f1 = []
        seen = {}
        present = set()
        for canonical_flag, value, orig in parsed:
            if canonical_flag.startswith('--') and canonical_flag not in spec['flags']:
                candidate_f1.append((canonical_flag, value, orig))
                continue
            if not canonical_flag.startswith('-'):
                continue
            if canonical_flag.startswith('-') and not canonical_flag.startswith('--') and canonical_flag not in spec['short_to_long']:
                candidate_f1.append((canonical_flag, value, orig))
                continue
            present.add(canonical_flag)
            seen.setdefault(canonical_flag, []).append(value)

        if probe_mode == 'spec-only':
            for cf, val, _orig in candidate_f1:
                violations.append(Violation('F1', actual, cf, val or '',
                                            f'unknown flag {cf} (spec-table only; --probe-mode spec-only)'))
        elif probe_mode == 'verbose-all':
            sanitized = _sanitize_for_probe(tokens)
            recognized = _verbose_probe(canonical, sanitized)
            if recognized is None:
                for cf, val, _orig in candidate_f1:
                    violations.append(Violation('F1', actual, cf, val or '',
                                                f'unknown flag {cf} (verbose probe failed)'))
            else:
                for cf, val, _orig in candidate_f1:
                    if cf in recognized:
                        present.add(cf)
                        seen.setdefault(cf, []).append(val)
                    else:
                        violations.append(Violation('F1', actual, cf, val or '',
                                                    f'unknown flag {cf} (msr --verbose confirmed)'))
                for cf in recognized:
                    if cf.startswith('--') and cf not in spec['flags']:
                        violations.append(Violation('F13', actual, cf, '',
                                                    f'spec-stale: flag {cf} recognized by msr --verbose but missing from {canonical}-spec.json',
                                                    severity='warning'))
        elif candidate_f1:
            sanitized = _sanitize_for_probe(tokens)
            recognized = _verbose_probe(canonical, sanitized)
            if recognized is None:
                for cf, val, _orig in candidate_f1:
                    violations.append(Violation('F1', actual, cf, val or '',
                                                f'unknown flag {cf} (verbose probe failed)'))
            else:
                for cf, val, _orig in candidate_f1:
                    if cf in recognized:
                        present.add(cf)
                        seen.setdefault(cf, []).append(val)
                    else:
                        violations.append(Violation('F1', actual, cf, val or '',
                                                    f'unknown flag {cf} (msr --verbose confirmed)'))

        for flag, vals in seen.items():
            if len(vals) >= 2:
                violations.append(Violation('F3', actual, flag, ','.join(str(v) for v in vals if v),
                                            f'flag {flag} specified {len(vals)} times (msr would error: cannot be specified more than once)'))

        constraints = extra.get('CONSTRAINTS', {})
        for flag in present:
            c = constraints.get(flag)
            if not c:
                continue
            if 'requires' in c:
                missing = [r for r in c['requires'] if r not in present]
                if missing:
                    violations.append(Violation('F5', actual, flag, '',
                                                c.get('requires_msg', f'{flag} requires {missing}')))
            if 'forbid_chars_in_arg' in c:
                vals = seen.get(flag, [])
                for v in vals:
                    if v and any(ch in v for ch in c['forbid_chars_in_arg']):
                        violations.append(Violation('F6', actual, flag, v,
                                                    c.get('forbid_msg', f'{flag} value "{v}" contains forbidden chars')))

        for group_name, members in extra.get('MUTEX_GROUPS', {}).items():
            hits = [m for m in members if m in present]
            if len(hits) >= 2:
                violations.append(Violation('F4', actual, ','.join(hits), '',
                                            f'flags in mutex group "{group_name}" cannot coexist: {hits}'))

        for flag, vals in seen.items():
            for v in vals:
                if v:
                    violations.extend(_check_value_patterns(actual, flag, v))

        violations.extend(_check_grep_misuse(actual, parsed, extra, tokens, present))

        violations.extend(_check_no_content_filter(actual, present))

    return violations


def _check_grep_misuse(actual, parsed, extra, tokens, present):
    """F12 -- grep/rg-style misuse of short flags that exist in msr with different meaning.

    parsed entry: (canonical_long, value, orig_token). orig_token is post combined-short
    expansion, so '-PIC' yields '-P','-I','-C' all with the same source position; bundled
    short flags are intentionally NOT flagged (treated as legitimate msr usage).

    Detection strategy by kind:
      eats_token: msr takes a value, grep does not. If value looks like a grep value
                  (small int / version-less / regex pattern), it is misuse.
      value_type: both take values, but value shape differs. Compare value against msr
                  expectation; if it matches grep style instead, flag as suspicious.
      no_value:   neither takes a value. Behavioral misuse is invisible at cli-spec
                  layer; skip (analyzer can catch via downstream signals).

    Strong signal only -- ambiguous cases skipped to keep false-positive rate low.
    """
    table = getattr(_load_extra_module(actual), 'GREP_MISUSE', None)
    if not table:
        return []
    out = []

    # Pre-pass: detect "msr no-value short flag followed by a small integer" -- high-signal
    # grep-context misuse for -A / -C (which msr ignores the integer, silently dropping context intent).
    no_value_eat_pattern = {'-A', '-C'}
    for i, tok in enumerate(tokens):
        if tok in no_value_eat_pattern and i + 1 < len(tokens) and re.fullmatch(r'\d{1,5}', tokens[i + 1]):
            entry = table.get(tok)
            if entry:
                msr_meaning, grep_meaning, fix, _ = entry
                out.append(Violation('F12', actual, tok, tokens[i + 1],
                    f'{tok} on msr = {msr_meaning} (takes no value); next token "{tokens[i + 1]}" looks like '
                    f'{grep_meaning} N. Fix: {fix}.', severity='error'))

    # Identify which tokens were emitted as bundled short flags (-PIC, -aPIC, etc.).
    # Those should never trigger F12, because the user clearly meant msr semantics.
    bundled_chars = set()
    for tok in tokens:
        if re.fullmatch(r'-[A-Za-z]{2,}', tok):
            # _expand_combined_short only expands when ALL chars resolve to known short flags.
            # We replicate that check here without importing spec; safe approximation: treat
            # any all-letter multi-char short token as bundled.
            bundled_chars.add(tok)
    seen_origs = set()
    for canonical, value, orig in parsed:
        if orig not in table:
            continue
        if orig in seen_origs:
            continue
        # Skip if this orig came from a bundled short like -PIC.
        # parsed gives orig=-P/-I/-C separately, but we only want to skip when the source
        # token was a bundle. Heuristic: if any bundled token contains this letter AND the
        # standalone -X token did NOT appear, the flag came from a bundle.
        letter = orig[1] if len(orig) == 2 else ''
        standalone_present = orig in tokens
        from_bundle = bool(letter) and any(letter in b[1:] for b in bundled_chars) and not standalone_present
        if from_bundle:
            continue
        seen_origs.add(orig)
        msr_meaning, grep_meaning, fix, kind = table[orig]
        verdict = _grep_misuse_verdict(orig, value, kind, tokens, present)
        if verdict is None:
            continue
        sev = verdict
        out.append(Violation('F12', actual, orig, value or '',
            f'{orig} on msr = {msr_meaning}, NOT {grep_meaning}. Fix: {fix}.',
            severity=sev))
    return out


def _grep_misuse_verdict(orig, value, kind, tokens, present):
    """Return 'error' / 'suspicious' / None based on signal strength."""
    if kind == 'eats_token':
        return _verdict_eats_token(orig, value)
    if kind == 'value_type':
        return _verdict_value_type(orig, value, present)
    # 'no_value' -- skip at cli-spec layer (analyzer handles via downstream pipe context).
    return None


def _verdict_eats_token(orig, value):
    """msr eats a value, grep/rg does not. If swallowed token matches grep semantics, flag."""
    if value is None:
        return None
    if orig == '-B':
        # msr -B = time string like "2026-05-24 14:00". grep -B = small int.
        if re.fullmatch(r'\d{1,5}', value):
            return 'error'
        return None
    if orig == '-E':
        # msr -E = time string. grep -E = (rare standalone). If next token is regex-like
        # (alternation / char class) or short int, near-certain grep misuse.
        if re.fullmatch(r'\d{1,5}', value):
            return 'error'
        if '|' in value or '[' in value or '(' in value:
            return 'error'
        return None
    if orig == '-L':
        # msr -L = row begin int. grep -L = no value. If next token is a path/filename, misuse.
        if re.fullmatch(r'\d{1,5}', value):
            return None  # plausible row number
        if re.search(r'[/\\.]', value):
            return 'error'
        return 'suspicious'
    if orig == '-N':
        # msr -N = row end int. rg -N = no value. If next token is a path/filename or another flag, misuse.
        if value.startswith('-'):
            return 'error'
        if re.fullmatch(r'[+-]?\d{1,6}', value):
            return None  # plausible row count
        if re.search(r'[/\\.]', value):
            return 'error'
        return 'suspicious'
    if orig == '-V':
        # msr -V = stop-execute regex-or-math. grep -V = no value (--version).
        # If swallowed token looks like a path/flag, near-certain version-flag misuse.
        if value.startswith('-') or re.search(r'[/\\]', value):
            return 'error'
        return None
    if orig == '-o':
        # msr -o = replacement template. grep -o = no value. If next token is a filename
        # or another flag, near-certain only-matching misuse.
        if value.startswith('-'):
            return 'error'
        if re.search(r'\.\w{1,5}$', value) and '/' not in value and '\\' not in value:
            return 'suspicious'
        return None
    if orig == '-v':
        # msr -v fmt only uses {d,t,m,o,z,s}. anything else = grep invert misuse.
        if re.fullmatch(r'[dtmozs]+', value):
            return None
        return 'error'
    if orig == '-z':
        # msr -z = direct string input. grep -z = no value. If next token is a path or flag, misuse.
        if value.startswith('-'):
            return 'error'
        return None
    return None


def _verdict_value_type(orig, value, present):
    """Both take values but semantics differ. Detect grep-style value shapes."""
    if value is None:
        return None
    if orig == '-F':
        # msr -F = time regex. grep -F = literal. Flag pure ASCII word with no regex meta and no digits.
        if re.search(r'[()\\d]', value) or re.search(r'\d', value):
            return None
        if re.fullmatch(r'[A-Za-z_][\w-]*', value):
            return 'error'
        return None
    if orig == '-H':
        # msr -H = head count int. grep -H = no value (always-print filename).
        # If value is not numeric, near-certain grep misuse.
        if re.fullmatch(r'[+-]?\d{1,6}', value):
            return None
        return 'error'
    if orig == '-U':
        # msr -U = upward context int. rg -U = no value (multiline mode).
        # If value is not numeric, near-certain rg misuse.
        if re.fullmatch(r'\d{1,5}', value):
            return None
        return 'error'
    if orig == '-w':
        # msr -w = path-list file. grep -w = word pattern. If value is not a filename
        # (no separator, no list ext), it is a grep word.
        if '/' in value or '\\' in value:
            return None
        if re.search(r'\.(txt|list|lst)$', value, re.I):
            return None
        if re.fullmatch(r'[\w.\-]+', value):
            return 'error'
        return None
    if orig == '-f':
        # msr -f = filename regex. grep -f = pattern file.
        # If value looks like a path to an existing pattern file, near-certain grep misuse.
        if value.endswith(('.txt', '.list', '.lst', '.pat', '.patterns')):
            return 'error'
        return None
    if orig == '-x':
        # msr -x = contains substring. grep -x = whole-line regex. Detect anchors: value
        # starting with ^ or ending with $ is grep whole-line intent.
        if value.startswith('^') or value.endswith('$'):
            return 'suspicious'
        return None
    return None



def _load_extra_module(actual):
    """Return the imported -extra module for the tool (for accessing GREP_MISUSE table)."""
    tool = 'nin' if actual == 'nin' else 'msr'
    path = HERE / f'{tool}-extra.py'
    if not path.exists():
        return type('Empty', (), {})()
    key = f'_modcache_{tool}'
    cache = _EXTRA_CACHE.setdefault('__modules__', {})
    if key in cache:
        return cache[key]
    spec = importlib.util.spec_from_file_location(f'{tool}_extra_full', path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    cache[key] = mod
    return mod


def _check_no_content_filter(actual, present):
    """F11 -- msr/gfind-* invocation without -t/-x/--nt/--nx AND without -l.
    Must have at least one of: content filter (-t/-x/--nt/--nx) OR list-mode (-l / --list-count).
    Otherwise the command dumps every matched file's full contents to stdout -- almost never intended.
    Exempted: nin; -z / --string (no file input)."""
    if actual == 'nin':
        return []
    if NO_FILE_INPUT_FLAGS & present:
        return []
    if CONTENT_FILTER_FLAGS & present:
        return []
    if LIST_MODE_FLAGS & present:
        return []
    return [Violation('F11', actual, '(no -t/-x/-l)', '',
        f'{actual} must use at least one of: content filter (-t/-x/--nt/--nx, optionally with -U N / -D N context) '
        f'OR list mode (-l / --list-count). Without either, it dumps full contents of every matched file.')]


def _check_value_patterns(actual, flag, v):
    """F7/F8/F9/F10 -- per-value regex/plain-text/path-escape heuristics."""
    out = []
    if flag in CSV_PLAIN_FLAGS and RE_CSV_PLAIN_META.search(v):
        out.append(Violation('F7', actual, flag, v,
            f'{flag} expects CSV plain-text path substring(s) separated by "," or ";"; '
            f'value "{v}" contains regex meta -- paths cannot contain | () [] ? * + and these are not alternation here.'))
    if flag in PLAIN_TEXT_FLAGS:
        if RE_PLAIN_META_HARD.search(v):
            out.append(Violation('F8', actual, flag, v,
                f'{flag} is plain-text (no regex); value "{v}" contains "|" or \\b/\\d/\\s/\\w. '
                f'If you intended regex, switch to -t / --nt; if you really want literal, ignore this.',
                severity='suspicious'))
        elif RE_PLAIN_META_SOFT.search(v):
            out.append(Violation('F8', actual, flag, v,
                f'{flag} is plain-text (no regex); value "{v}" contains "(" / "[" / "{{". '
                f'May be intended as regex -- switch to -t / --nt if so.',
                severity='suspicious'))
    if flag == '--time-format' and '(' not in v:
        out.append(Violation('F9', actual, flag, v,
            f'-F / --time-format value "{v}" has no capture group "(...)". '
            f'-B / -E rely on group[0] or group[1]; without "(...)", time comparison will use raw match.'))
    if flag in PATH_REGEX_FLAGS and '\\' in v:
        if '\\' in RE_KNOWN_ESCAPE.sub('', v):
            out.append(Violation('F10', actual, flag, v,
                f'{flag} value "{v}" contains literal "\\" outside known regex escapes. '
                f'msr treats path separators as "/" on Windows -- use "/" instead of "\\\\" in path regex.',
                severity='suspicious'))
    return out


if __name__ == '__main__':
    import sys
    for line in sys.argv[1:]:
        vs = check_command(line)
        print(f'\n=== {line}')
        if not vs:
            print('  (no violations)')
        for v in vs:
            print(f'  [{v.code}] {v.tool} {v.flag}: {v.msg}')
