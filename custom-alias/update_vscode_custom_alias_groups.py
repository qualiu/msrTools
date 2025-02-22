#!/usr/bin/env python3
# pip install json5 argparse
# Tool to update your published alias from your latest (frequently used + tuned) alias:
#   Only update existing alias + check/add their dependencies alias to your published settings.json file.
# Usage example: python update_vscode_custom_alias_groups.py -r %APPDATA%/Code/User/settings.json -t C:/opengit/msrTools/code/vs-conemu/vscode/settings.json
import os
import json5
import json
import argparse
import sys
import re
from typing import Set

parser = argparse.ArgumentParser(description='Update alias lists in settings.json file')
parser.add_argument('-t', '--target-json', required=True, help='Target settings json file (your published) to update.')
parser.add_argument('-r', '--read-new-json', required=True, help='New settings json from yours like: %APPDATA%/Code/User/settings.json'.replace('%', '%%'))
parser.add_argument('-d', '--update-description-only', required=False, help='Only update descriptions.', action='store_true')
parser.add_argument('-o', '--save-new-path', required=False, help='Save new settings json file path.')
parser.add_argument('-n', '--skip-alias', required=False, help='Regex-pattern or comma-separated-list of alias names to skip.')
parser.add_argument('-g', '--skip-group', required=False, help='Regex-pattern or comma-separated-list of group names to skip.')

Alias_Groups_To_Update = [
    "msr.commonAliasNameBodyList",
    "msr.cmd.commonAliasNameBodyList",
    "msr.bash.commonAliasNameBodyList"
]


def resolve_path(path: str) -> str:
    return os.path.realpath(os.path.expanduser(os.path.expandvars(path))) if path else path


def load_json_file(file_path: str) -> dict:
    try:
        with open(file_path, 'r', encoding='utf-8') as f:
            return json5.loads(f.read())
    except Exception as e:
        print(f"Error loading file {file_path}: {str(e)}", file=sys.stderr)
        raise


def save_json_file(file_path: str, data: dict):
    try:
        with open(file_path, 'w', encoding='utf-8') as f:
            json.dump(data, f, indent=4, ensure_ascii=False)
    except Exception as e:
        print(f"Error saving file {file_path}: {str(e)}", file=sys.stderr)
        raise


def find_dependent_alias_names(is_cmd_group: bool, aliasBody: str, new_alias_names: Set[str]) -> Set[str]:
    dependent_names = set()
    suffix = r'\.cmd' if is_cmd_group else r'\b'
    for alias_name in new_alias_names:
        pattern = r'(^|\s|\"|\')(' + alias_name + suffix + r')(\s+|"$)'
        is_found = re.search(pattern, aliasBody)
        if is_found:
            dependent_names.add(alias_name)
    return dependent_names


def is_different_body(old_alias: dict, new_alias: dict) -> bool:
    return old_alias['aliasBody'] != new_alias['aliasBody']


def is_different_description(old_alias: dict, new_alias: dict) -> bool:
    if not new_alias.get("description"):
        return False
    return old_alias.get("description") != new_alias.get("description")


def is_different_alias(old_alias: dict, new_alias: dict) -> bool:
    return is_different_body(old_alias, new_alias) or is_different_description(old_alias, new_alias)


def check_duplicate_alias_names(data: dict, file_path: str):
    for group_name in Alias_Groups_To_Update:
        if group_name not in data:
            continue
        alias_names: set[str] = set()
        duplicate_alias_names: set[str] = set()
        for alias in data[group_name]:
            alias_name = alias["aliasName"]
            old_count = len(alias_names)
            alias_names.add(alias_name)
            if len(alias_names) == old_count:
                duplicate_alias_names.add(alias_name)
                print(f"Duplicate alias: {alias_name} in group: {group_name} in file: {file_path}", file=sys.stderr)
        if duplicate_alias_names:
            raise Exception(
                f"Found {len(duplicate_alias_names)} duplicate alias in group: {group_name} in file: {file_path}: Duplicate alias[{len(duplicate_alias_names)}] = {duplicate_alias_names}")


def merge_alias_lists(old_data: dict, new_data: dict, update_description_only: bool, skip_alias_name_regex: re.Pattern[str], skip_alias_group_regex: re.Pattern[str]) -> tuple[dict, int]:
    updated_count = 0
    added_dependencies_count = 0
    for group_name in Alias_Groups_To_Update:
        if skip_alias_group_regex.match(group_name):
            print(f"Skip matched group name: {group_name}")
            continue
        is_cmd_group = group_name == "msr.cmd.commonAliasNameBodyList"
        if not (group_name in new_data and group_name in old_data):
            continue
        old_group = old_data[group_name]
        old_aliases = {item["aliasName"]: item for item in old_group}
        old_alias_names = set(old_aliases.keys())
        new_group = new_data[group_name]
        new_alias_names = {item["aliasName"] for item in new_group}
        dependent_new_aliases = set()
        for new_alias in new_group:
            alias_name = new_alias["aliasName"]
            if skip_alias_name_regex.match(alias_name):
                continue
            if alias_name not in old_aliases:
                continue
            new_alias['aliasBody'] = new_alias['aliasBody'].strip()
            if "description" in new_alias:
                new_alias['description'] = new_alias['description'].strip()
            old_alias = old_aliases[alias_name]
            if update_description_only:
                if is_different_description(old_alias, new_alias):
                    updated_count += 1
                    old_alias["description"] = new_alias["description"]
                continue
            if is_different_alias(old_alias, new_alias):
                updated_count += 1
                old_alias['aliasBody'] = new_alias['aliasBody']
                if "description" in new_alias:
                    old_alias["description"] = new_alias["description"]
            dependent_aliases = find_dependent_alias_names(is_cmd_group, new_alias["aliasBody"], new_alias_names)
            for alias_name in dependent_aliases:
                if alias_name not in old_alias_names:
                    dependent_new_aliases.add(alias_name)

        for alias_name in dependent_new_aliases:
            new_alias = next((item for item in new_group if item["aliasName"] == alias_name), None)
            old_group.append(new_alias)
        added_dependencies_count += len(dependent_new_aliases)
        print(f"Updated {updated_count} aliases and added {added_dependencies_count} dependencies in groups: {group_name}")
    return (old_data, updated_count + added_dependencies_count)


def build_regex(regex_or_comma_separated_list: str) -> re.Pattern[str]:
    if not regex_or_comma_separated_list:
        return re.compile(r'^-No-Skip-$')
    if ',' in regex_or_comma_separated_list:
        pattern = r'^(' + '|'.join([name.strip() for name in regex_or_comma_separated_list.split(',')]) + r')$'
        return re.compile(pattern)
    return re.compile(regex_or_comma_separated_list)


if __name__ == "__main__":
    if len(sys.argv) == 1:
        parser.print_help(sys.stderr)
    args = parser.parse_args()

    args.target_json = resolve_path(args.target_json)
    args.read_new_json = resolve_path(args.read_new_json)

    target_data = load_json_file(args.target_json)
    new_data = load_json_file(args.read_new_json)
    check_duplicate_alias_names(new_data, args.read_new_json)
    check_duplicate_alias_names(target_data, args.target_json)

    skip_alias_name_regex = build_regex(args.skip_alias)
    skip_group_name_regex = build_regex(args.skip_group)

    [updated_data, changes_count] = merge_alias_lists(target_data, new_data, args.update_description_only, skip_alias_name_regex, skip_group_name_regex)
    if changes_count == 0:
        print(f"No changes detected in alias lists in {args.target_json}")
    else:
        save_path = args.save_new_path if args.save_new_path else args.target_json
        save_json_file(save_path, updated_data)
        print(f"Successfully updated alias saved to {save_path}")
