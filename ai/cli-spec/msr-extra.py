"""Hand-written semantic constraints for msr / gfind-* / find-* commands.

Each entry keyed by long-name (canonical). Constraints not auto-derivable from
help text -- they catch syntactically valid but semantically wrong usage.

Schema:
  long_name: {
    'forbid_chars_in_arg': [chars],   # F6: arg cannot contain these chars
    'forbid_msg': str,
    'requires': [other_long_names],   # F5: requires presence of these flags
    'requires_msg': str,
    'mutex_group': str,               # F4: at most one flag per group may appear
  }
"""

CONSTRAINTS = {
    '--dir-has': {
        'forbid_chars_in_arg': ['/', '\\'],
        'forbid_msg': '-d / --dir-has expects a single sub-folder NAME regex; '
                      'subfolder names never contain "/" or "\\". Use --sp "<path>" for path substring AND-include.',
    },
    '--nd': {
        'forbid_chars_in_arg': ['/', '\\'],
        'forbid_msg': '--nd expects a single sub-folder NAME regex; subfolder names never contain "/" or "\\". '
                      'Use --xp / --np for path-level exclusion.',
    },
    '--time-begin': {
        'requires': ['--time-format'],
        'requires_msg': '-B / --time-begin requires -F / --time-format (regex for time/key extraction).',
    },
    '--time-end': {
        'requires': ['--time-format'],
        'requires_msg': '-E / --time-end requires -F / --time-format.',
    },
    '--sort-as-number': {
        'requires': ['--sort-by'],
        'requires_msg': '-n / --sort-as-number requires -s / --sort-by.',
    },
    '--backup': {
        'requires': ['--replace-file'],
        'requires_msg': '-K / --backup only meaningful with -R / --replace-file.',
    },
    '--reuse-block-end': {
        'requires': ['--stop-block'],
        'requires_msg': '-y / --reuse-block-end requires -Q / --stop-block.',
    },
    '--stop-block': {
        'requires': ['--start-block'],
        'requires_msg': '-Q / --stop-block requires -b / --start-block.',
    },
}

MUTEX_GROUPS = {}

# F12: short flags that exist in msr but mean something entirely different from grep/rg.
# Agent typing grep/rg habits silently misuses them -- no "unknown flag" error fires.
# Each entry: short -> (msr_meaning, grep_or_rg_meaning, msr_correct_alternative, kind)
# kind:
#   'eats_token' -- msr flag takes a value; grep/rg flag does not (or takes a different value type).
#                  Detect by looking at the next token's shape.
#   'value_type' -- both take values but value semantics differ. Detect by value pattern.
#   'no_value'   -- neither takes a value; misuse is behavioral, not token-swallowing.
#                  Often skipped at cli-spec layer (analyzer can detect via downstream pipe).
GREP_MISUSE = {
    '-A': ('--no-any-info (no value; suppress all info)',
           'grep after-context (-A N)',
           'use -D N (downward context)',
           'no_value'),
    '-B': ('--time-begin <time-string> (value-taking; requires -F regex)',
           'grep before-context (-B N)',
           'use -U N (upward context)',
           'eats_token'),
    '-C': ('--no-color (no value)',
           'grep context (-C N)',
           'use -U N -D N (or bundled -PIC for no-color)',
           'no_value'),
    '-E': ('--time-end <time-string> (value-taking; requires -F regex)',
           'grep extended-regex (-E)',
           'msr is PCRE by default -- remove -E; use -t "<regex>"',
           'eats_token'),
    '-F': ('--time-format <regex> (value-taking; companion to -B/-E)',
           'grep fixed-string (-F "literal")',
           'use -x "<plain-text>"',
           'value_type'),
    '-G': ('--read-once (no value; for link files)',
           'grep basic-regex (-G)',
           'msr is PCRE by default -- remove -G; use -t "<regex>"',
           'no_value'),
    '-H': ('--head <N> (value-taking; output top N rows)',
           'grep always-print-filename (-H, no value)',
           'msr already prints path; remove -H (or use -H N for head-N rows)',
           'value_type'),
    '-L': ('--row-begin <N> (value-taking start row)',
           'grep files-without-match (-L, no value)',
           'invert via --nt/--nx, or use nin',
           'eats_token'),
    '-N': ('--row-end <N> (value-taking end row)',
           'rg no-line-number (-N, no value)',
           'msr default already lists line:no in path-prefix; use -P to hide path or -m to add count',
           'eats_token'),
    '-P': ('--no-path-line (no value; suppress path prefix)',
           'grep/rg PCRE (-P)',
           'msr is PCRE by default -- remove -P (or keep if you really want path hidden)',
           'no_value'),
    '-S': ('--single-line (no value; "." matches newline)',
           'rg smart-case (-S)',
           'msr has no smart-case; use -i for ignore-case or (?i) in -t regex',
           'no_value'),
    '-U': ('--up <N> (value-taking upward context)',
           'rg multiline (-U, no value)',
           'msr has no multiline-mode flag; use -S for "." matches newline (per-block)',
           'value_type'),
    '-V': ('--stop-execute <regex-or-math> (value-taking; for -X)',
           'grep/rg --version (-V, no value)',
           'use msr -h | head for help; msr has no --version short -- check binary timestamp',
           'eats_token'),
    '-c': ('--show-command (no value; debug echo of cmdline)',
           'grep count (-c, no value)',
           'use -m (--show-count per line) or -l (--list-count per file)',
           'no_value'),
    '-f': ('--file-match <filename-regex> (value-taking)',
           'grep -f <pattern-file> (value = file containing patterns)',
           'msr -f matches filename only; use -t for content pattern, or pre-read patterns and pass via -t "(p1|p2)"',
           'value_type'),
    '-o': ('--replace-to <replacement> (value-taking; needs -t/-x)',
           'grep only-matching (-o, no value)',
           'msr -t "(?:before)(captured)(?:after)" already shows the match line; use -o "\\1" to print only the capture group',
           'eats_token'),
    '-v': ('--show-time <fmt> (value-taking, e.g. dt/dtm/dto)',
           'grep invert-match (-v, no value)',
           'use --nt "<regex>" or --nx "<plain>"',
           'eats_token'),
    '-w': ('--read-paths <file> (value-taking; reads path list)',
           'grep word-boundary (-w "word", value=pattern)',
           'use -t "\\bword\\b"',
           'value_type'),
    '-x': ('--has-text <plain-text> (value = substring must appear)',
           'grep -x line-regex (value = whole-line pattern)',
           'msr -x means contains; for whole-line match use -t "^<regex>$"',
           'value_type'),
    '-z': ('--string <text> (value = direct string input, no file/pipe)',
           'grep -z null-data / rg -z search-zip (no value)',
           'msr -z is unrelated to grep/rg -z; if you wanted null-separated input, msr does not support it',
           'eats_token'),
}
