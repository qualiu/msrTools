#!/usr/bin/env python3
"""Build msr/nin CLI spec JSON by combining `<tool> -h -C` (short<->long map + arg presence)
and `<tool> --verbose` (authoritative long-name list).

Output:
  ai/cli-spec/msr-spec.json
  ai/cli-spec/nin-spec.json

Each entry:
  {
    "long": "--dir-has",
    "short": "-d",            # may be null
    "takes_arg": true,
    "default": "",            # raw default string from verbose dump
    "help": "Regex pattern: Must has 1+ sub-folder-name ..."
  }
"""
import json
import re
import subprocess
from pathlib import Path

HERE = Path(__file__).parent

RE_PAIR = re.compile(r'^\s*(-\w+)\s*\[\s*(--[\w-]+)\s*\](\s+arg)?\s+(.+)$')
RE_LONG_ONLY = re.compile(r'^\s+(--[\w-]+)(\s+arg)?\s+([A-Z].+)$')
RE_VERBOSE_LINE = re.compile(r'^(?:--?)?\s?([\w-]+)\s*=\s*(.*)$')


def run(cmd, want_stderr=False):
    p = subprocess.run(cmd, capture_output=True, text=True, encoding='utf-8', errors='replace')
    return (p.stderr if want_stderr else p.stdout)


def parse_help(text):
    pairs = {}
    long_only = {}
    for line in text.splitlines():
        m = RE_PAIR.match(line)
        if m:
            short, lng, arg, desc = m.group(1), m.group(2), m.group(3), m.group(4)
            pairs[lng] = {'short': short, 'takes_arg': bool(arg), 'help': desc.strip()}
            continue
        m = RE_LONG_ONLY.match(line)
        if m:
            lng, arg, desc = m.group(1), m.group(2), m.group(3)
            if lng not in pairs:
                long_only[lng] = {'short': None, 'takes_arg': bool(arg), 'help': desc.strip()}
    return pairs, long_only


def parse_verbose(text):
    flags = {}
    in_block = False
    for line in text.splitlines():
        if 'Begin args verbose' in line:
            in_block = True
            continue
        if 'End args verbose' in line:
            break
        if not in_block:
            continue
        m = RE_VERBOSE_LINE.match(line)
        if m:
            name, default = m.group(1), m.group(2)
            flags['--' + name] = default.strip()
    return flags


def build_msr_spec():
    help_text = run(['msr', '-h', '-C'])
    verbose_text = run(['msr', '-z', 'test', '--verbose', '-PIC'], want_stderr=True)
    pairs, long_only = parse_help(help_text)
    verbose_flags = parse_verbose(verbose_text)
    spec = {}
    for lng, info in {**pairs, **long_only}.items():
        spec[lng] = {
            'long': lng,
            'short': info['short'],
            'takes_arg': info['takes_arg'],
            'default': verbose_flags.get(lng, None),
            'help': info['help'][:200],
        }
    for lng, default in verbose_flags.items():
        if lng not in spec:
            spec[lng] = {
                'long': lng,
                'short': None,
                'takes_arg': default not in ('false', 'true'),
                'default': default,
                'help': '(undocumented; from --verbose only)',
            }
    return spec


def build_nin_spec():
    help_text = run(['nin', '-h', '-C'])
    p = subprocess.run(['nin', 'nul', 'nul', '--verbose', '-PIC'], capture_output=True, text=True, encoding='utf-8', errors='replace')
    verbose_text = p.stderr
    pairs, long_only = parse_help(help_text)
    verbose_flags = parse_verbose(verbose_text)
    spec = {}
    for lng, info in {**pairs, **long_only}.items():
        spec[lng] = {
            'long': lng,
            'short': info['short'],
            'takes_arg': info['takes_arg'],
            'default': verbose_flags.get(lng, None),
            'help': info['help'][:200],
        }
    for lng, default in verbose_flags.items():
        if lng not in spec:
            spec[lng] = {
                'long': lng,
                'short': None,
                'takes_arg': default not in ('false', 'true'),
                'default': default,
                'help': '(undocumented; from --verbose only)',
            }
    return spec


def main():
    msr_spec = build_msr_spec()
    nin_spec = build_nin_spec()
    (HERE / 'msr-spec.json').write_text(json.dumps(msr_spec, indent=2, ensure_ascii=False), encoding='utf-8')
    (HERE / 'nin-spec.json').write_text(json.dumps(nin_spec, indent=2, ensure_ascii=False), encoding='utf-8')
    print(f'msr flags: {len(msr_spec)}')
    print(f'nin flags: {len(nin_spec)}')
    print(f'msr short-name count: {sum(1 for v in msr_spec.values() if v["short"])}')
    print(f'nin short-name count: {sum(1 for v in nin_spec.values() if v["short"])}')


if __name__ == '__main__':
    main()
