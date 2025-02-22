#!/usr/bin/env python3
import os
import argparse
import sys
import re
import logging
from typing import Dict
from update_vscode_custom_alias_groups import resolve_path, build_regex
import subprocess

GithubFormat = '{repo_url}/blob/{branch}/{file}#L{begin}-L{end}'
StudioFormat = '{repo_url}?path={file}&version=GB{branch}&line={begin}&lineEnd={end}&lineStartColumn=1&lineEndColumn={end_column}&lineStyle=plain&_a=contents'

parser = argparse.ArgumentParser(description='Update alias links in markdown file')
parser.add_argument('-m', '--markdown-doc', required=True, help='Path to markdown file (like README.md)')
parser.add_argument('-r', '--read-json-paths', required=True, help='Setting.json file paths, use comma to separate multiple files.')
parser.add_argument('-s', '--skip-name', help='Regex-pattern or comma-separated-list of alias names to skip.')
parser.add_argument('-f', '--format', default='auto', help=f'Format place holder, default = "auto". Example: "{GithubFormat}"')
parser.add_argument('-v', '--log-level', help='Log level: DEBUG, INFO, WARNING, ERROR, CRITICAL', default='INFO')

logging.basicConfig(level=logging.INFO, datefmt='%Y-%m-%d %H:%M:%S', format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)


class RepoInfo:
    def __init__(self, root, url: str, branch: str):
        self.root = root
        self.url = url
        self.branch = branch


class AliasNameRowRange:
    def __init__(self, alias_name: str, relative_path: str, begin_row: int, end_row: int, begin_column: int = 1, end_column: int = 1):
        self.alias_name = alias_name
        self.relative_path = relative_path
        self.begin_row = begin_row
        self.end_row = end_row
        self.begin_column = begin_column
        self.end_column = end_column

    def __str__(self):
        return f"{self.alias_name} in {self.relative_path}:{self.begin_row} ~ {self.end_row}"


class AliasGroupRange:
    def __init__(self, group_name: str, alias_rows_dict: Dict[str, AliasNameRowRange]):
        self.group = group_name
        self.alias_rows = alias_rows_dict


def get_git_repo_url(file_path: str) -> RepoInfo:
    root_folder = subprocess.check_output(['git', 'rev-parse', '--show-toplevel'], cwd=os.path.dirname(file_path), universal_newlines=True).strip()
    remote_url = subprocess.check_output(['git', 'config', '--get', 'remote.origin.url'], cwd=root_folder, universal_newlines=True).strip()
    branch_name = subprocess.check_output(['git', 'rev-parse', '--abbrev-ref', 'HEAD'], cwd=root_folder, universal_newlines=True).strip()
    default_branch = subprocess.check_output(['git', 'symbolic-ref', '--short', 'refs/remotes/origin/HEAD'], cwd=root_folder, universal_newlines=True).strip()

    branch_name = default_branch.replace('origin/', '') if default_branch else branch_name

    # Convert SSH URL to HTTPS if needed
    if remote_url.startswith('git@'):
        remote_url = remote_url.replace(':', '/').replace('git@', 'https://')
    if remote_url.endswith('.git'):
        remote_url = remote_url[:-4]

    return RepoInfo(root_folder, remote_url, branch_name)


class MarkdownLinkUpdater:
    def __init__(self, markdown_path: str, settings_paths: list[str], format_place_holder: str, skip_alias_regex: re.Pattern[str]):
        self.markdown_path = markdown_path
        self.settings_paths = settings_paths
        self.format_place_holder = format_place_holder
        self.skip_alias_regex = skip_alias_regex
        self.repo_info = get_git_repo_url(markdown_path)

    def get_formatter(self) -> str:
        if self.format_place_holder != 'auto':
            return self.format_place_holder
        if 'github.com' in self.repo_info.url:
            return GithubFormat
        if 'studio.com' in self.repo_info.url:
            return StudioFormat
        raise ValueError(f"Unknown format for repo: {self.repo_info.url}, please specify format in command line args.")

    def format_source_link(self, source: AliasNameRowRange) -> str:
        formatter = self.get_formatter()
        end_column = source.end_column + 1 if formatter == StudioFormat else source.end_column
        return formatter.format(repo_url=self.repo_info.url, branch=self.repo_info.branch, file=source.relative_path, begin=source.begin_row, end=source.end_row, begin_column=source.begin_column, end_column=end_column)

    def update_markdown_links(self):
        alias_set_from_markdown = self.get_all_alias_names_in_markdown()
        find_alias_regex = re.compile(r'\[\W*?(' + '|'.join(alias_set_from_markdown) + r')\W*?\]\(([^\)]+?\.json[^\)]*)\)')
        alias_source_map = self.find_alias_from_all_sources(alias_set_from_markdown, settings_paths)
        with open(markdown_path, 'r', encoding='utf-8') as f:
            lines = f.readlines()

        changed_count = 0
        missed_alias = []
        for row in range(len(lines)):
            all_matches = find_alias_regex.finditer(lines[row])
            while True:
                search = next(all_matches, None)
                if search is None:
                    break
                alias_name = search.group(1)
                if skip_alias_regex.match(alias_name):
                    continue
                if alias_name not in alias_source_map:
                    missed_alias.append(alias_name)
                    logger.error(f"Missed-Alias[{len(missed_alias)}]: {alias_name} not found, please check: {markdown_path}:{row + 1}")
                    continue
                source = alias_source_map[alias_name]
                new_url = self.format_source_link(source)
                old_url = search.group(2)
                if new_url == old_url:
                    logger.debug(f"Skip same link: {markdown_path}:{row + 1}: {old_url}")
                    continue
                old_name_link = search.group(0)
                new_name_link = old_name_link.replace(old_url, new_url)
                lines[row] = lines[row].replace(old_name_link, new_name_link)
                logger.info(f"Updated link: {alias_name} at {markdown_path}:{row + 1}: from {old_url} to {new_url}")
                changed_count += 1

        if changed_count > 0:
            with open(markdown_path, 'w', encoding='utf-8') as f:
                f.writelines(lines)
        logger.info(f"Updated {changed_count} links in {markdown_path}, missed aliases[{len(missed_alias)}] = {missed_alias}")

    def find_alias_row_ranges(self, json_path: str, alias_names: set[str]) -> Dict[str, AliasNameRowRange]:
        with open(json_path, 'r', encoding='utf-8') as f:
            lines = f.readlines()
        relative_path = os.path.relpath(json_path, self.repo_info.root).replace('\\', '/')
        alias_rows_dict: Dict[str, AliasNameRowRange] = {}
        row = 0
        match_block_end_regex = re.compile(r'\s*},?\s*$')
        search_alias_regex = re.compile(r'\s*"aliasName":\s*"(' + '|'.join(alias_names) + r')",?\s*$')
        while row < len(lines):
            line = lines[row]
            matched = search_alias_regex.match(line)
            if matched:
                begin_row = row
                begin_column_pos = lines[row - 1].find('{')
                begin_column = begin_column_pos + 1 if begin_column_pos >= 0 else 1
                alias_name = matched.group(1)
                while row < len(lines):
                    if match_block_end_regex.match(lines[row]):
                        end_column_pos = lines[row].find('}')  # .find('\n')
                        end_column = end_column_pos + 1 if end_column_pos >= 0 else len(lines[row])
                        source_range = AliasNameRowRange(alias_name, relative_path, begin_row, row + 1, begin_column, end_column)
                        alias_rows_dict[alias_name] = source_range
                        logger.debug(f"Found alias: {alias_name} at {json_path}:{begin_row} ~ {row + 1}")
                        break
                    row += 1
            row += 1
        return alias_rows_dict

    def get_all_alias_names_in_markdown(self) -> set[str]:
        with open(self.markdown_path, 'r', encoding='utf-8') as f:
            content = f.read()

        pattern = r'\[\W*([\w-]+)\W*\]\(([^\)]+?\.json[^\)]*?)\)'
        matches = re.findall(pattern, content)

        alias_names: set[str] = set()
        for match in matches:
            alias_name = match[0]
            if self.skip_alias_regex.match(alias_name):
                continue
            old_count = len(alias_names)
            alias_names.add(alias_name)
            if len(alias_names) == old_count:
                logger.warning(f"Duplicate name found: {alias_name} in {self.markdown_path}")
        logger.info(f"Will check {len(alias_names)} aliases: {alias_names} in {self.markdown_path}")
        return alias_names

    def find_alias_from_all_sources(self, alias_set_from_markdown: set[str], settings_paths: set[str]) -> Dict[str, AliasNameRowRange]:
        alias_source_map: Dict[str, AliasNameRowRange] = {}
        for settings_path in settings_paths:
            source_map = self.find_alias_row_ranges(settings_path, alias_set_from_markdown)
            alias_source_map.update(source_map)
            alias_set_from_markdown -= source_map.keys()
            if len(alias_set_from_markdown) == 0:
                break
        if len(alias_set_from_markdown) > 0:
            logger.error(f"Failed to find alias[{len(alias_set_from_markdown)}]: {alias_set_from_markdown}")
        else:
            logger.info(f"Found all {len(alias_source_map)} aliases from settings: {", ".join(alias_source_map.keys())}")
        return alias_source_map


if __name__ == "__main__":
    if len(sys.argv) == 1:
        parser.print_help(sys.stderr)
    args = parser.parse_args()
    logger.setLevel(args.log_level)
    format = args.format

    markdown_path = resolve_path(args.markdown_doc)
    # settings_paths = set([resolve_path(path) for path in args.read_json_paths.split(',')])
    settings_paths = list(dict.fromkeys([resolve_path(path) for path in args.read_json_paths.split(',')]))
    skip_alias_regex = build_regex(args.skip_name)
    updater = MarkdownLinkUpdater(markdown_path, settings_paths, format, skip_alias_regex)
    updater.update_markdown_links()
