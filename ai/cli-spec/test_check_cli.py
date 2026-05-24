"""Tests for check_cli.py. Run: python ai/cli-spec/test_check_cli.py"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from check_cli import check_command  # noqa: E402


CASES = [
    ('gfind-file -d Tools/LocalDev/patch -f "\\.ps1$" -t "pattern"',
     [('F6', '--dir-has')]),
    ('msr -rp . -d "src" -t "Service" -H 10',
     []),
    ('msr -p file.log -B "2026-05-24" -t "ERROR"',
     [('F5', '--time-begin')]),
    ('msr -p file.log -F "(\\d+)" -B "100" -E "200" -t "."',
     []),
    ('msr -rp . -t "a" -t "b" -PIC',
     [('F3', '--text-match')]),
    ('msr -rp . -t "pattern" --bogus-flag arg',
     [('F1', '--bogus-flag')]),
    ('msr -rp . -t "x" -PIC',
     []),
    ('msr -rp . -f "\\.cs$" --nd "test/sub" -t "Foo"',
     [('F6', '--nd')]),
    ('nin file1 file2 --ascending --descending',
     [('F4', '--ascending,--descending')]),
    ('cd /tmp && msr -z test',
     []),
    ('msr -z test --verbose -PIC',
     []),
    ('msr -p /tmp/x.log -K -t "."',
     [('F5', '--backup')]),
    ('msr -p /tmp/x.log -R -K -t "." -o "y"',
     []),
    ('msr -rp . -t "x" -X -V "ne0"',
     []),
    ('msr -rp . -t "x" --% -d c:/literal/path -f "\\.txt$"',
     []),
    ('msr -p /tmp/x.log -t "." -RKI -o "y"',
     []),
    ('msr -p /tmp/x.log -t "(.+)" -o "echo pwned" -X -V "ne0"',
     []),
    ('msr -rp /tmp -t "x" --sp "regex|pattern"',
     [('F7', '--sp')]),
    ('msr -rp /tmp -t "x" --xp "test,deprecate"',
     []),
    ('msr -rp /tmp -t "x" --xp "test|deprecate"',
     [('F7', '--xp')]),
    ('msr -rp /tmp -x "a|b"',
     [('F8', '--has-text')]),
    ('msr -rp /tmp -x "hello world"',
     []),
    ('msr -rp /tmp -x "func(arg)"',
     [('F8', '--has-text')]),
    ('msr -rp /tmp --nx "\\bword\\b"',
     [('F8', '--nx')]),
    ('msr -p /tmp/log -F "\\d{4}-\\d+-\\d+" -B "2026-05-01" -t "."',
     [('F9', '--time-format')]),
    ('msr -p /tmp/log -F "(\\d{4}-\\d+-\\d+)" -B "2026-05-01" -t "."',
     []),
    ('msr -rp /tmp -t "x" --pp "src\\bin"',
     []),
    ('msr -rp /tmp -t "x" --pp "src\\folder"',
     [('F10', '--pp')]),
    ('gfind-file --sp "src" --xp "test,deprecate" -f "\\.cs$" -t "Foo"',
     []),
    ('msr -p log.txt -x "127.0.0.1"',
     []),
    ('msr -p log.txt -x "(error|warn)"',
     [('F8', '--has-text')]),
    ('msr -p log.txt -x "a\\sb"',
     [('F8', '--has-text')]),
    ('msr -p log.txt --nx "[INFO]"',
     [('F8', '--nx')]),
    ('msr -p log.txt -x "C:\\Users\\qualiu"',
     []),
    ('nin file1 file2 -x "(a|b)"',
     [('F8', '--has-text')]),
    ('msr -rp /tmp --sp "src,test"',
     [('F11', '(no -t/-x/-l)')]),
    ('msr -rp /tmp --sp "src;test"',
     [('F11', '(no -t/-x/-l)')]),
    ('msr -rp /tmp --sp "src(test)"',
     [('F7', '--sp'), ('F11', '(no -t/-x/-l)')]),
    ('msr -rp /tmp --xp "node_modules,/dist,build/"',
     [('F11', '(no -t/-x/-l)')]),
    ('msr -rp /tmp -t "x" --pp "src/.*?/bin"',
     []),
    ('msr -rp /tmp -t "x" --pp "src\\.config"',
     []),
    ('msr -p log -F "[\\d-]+ [\\d:]+" -B "2026-01-01"',
     [('F9', '--time-format'), ('F11', '(no -t/-x/-l)')]),
    ('msr -p log -F "((?:\\d+-){2}\\d+ [\\d:]+)" -B "2026-01-01"',
     [('F11', '(no -t/-x/-l)')]),
    ('cmd1 | msr -rp /tmp -t "x" | gfind-file -d "src" -t "y" | nin file1 -x "z"',
     []),
    ('msr -rp /tmp -t "x" --sp "regex|pattern" | nin nul "(\\S+)"',
     [('F7', '--sp')]),
    ('cd /tmp && msr -rp . --sp "a|b" --xp "c|d" -t "x"',
     [('F7', '--sp'), ('F7', '--xp')]),
    ('msr -p file -d "Tools/Local" --sp "Backend" -F "[\\d-]+" -B "100" -x "(grp)"',
     [('F6', '--dir-has'), ('F9', '--time-format'), ('F8', '--has-text')]),
    ('gfind-file -f "python_error_checker\\.py$"',
     [('F11', '(no -t/-x/-l)')]),
    ('gfind-file -f "python_error_checker\\.py$" -t "def main"',
     []),
    ('gfind-file -f "python_error_checker\\.py$" -x "TODO"',
     []),
    ('gfind-file -f "python_error_checker\\.py$" -l',
     []),
    ('msr -rp src -t "Foo" -U 2 -D 2',
     []),
    ('msr -rp src',
     [('F11', '(no -t/-x/-l)')]),
    ('msr -p file.log',
     [('F11', '(no -t/-x/-l)')]),
    ('nin file1 file2',
     []),
]


def main():
    fails = 0
    for cmd, expected in CASES:
        vs = check_command(cmd)
        got = sorted((v.code, v.flag) for v in vs)
        want = sorted(expected)
        if got != want:
            fails += 1
            print(f'FAIL: {cmd}')
            print(f'  expected: {want}')
            print(f'  got:      {got}')
            for v in vs:
                print(f'    [{v.code}] {v.flag}: {v.msg}')
        else:
            print(f'PASS: {cmd}  -> {got if got else "clean"}')
    print(f'\n{len(CASES) - fails} passed / {len(CASES)} total')
    sys.exit(0 if fails == 0 else 1)


if __name__ == '__main__':
    main()
