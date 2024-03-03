#!/usr/bin/env python3
# autopep8: --max-line-length=160

import os
import csv
import json
import sys


def convert_csv_to_json(csv_file, json_file, fix_empty_value=False):
    data = []
    skipped_rows = []
    previous_row = None
    with open(csv_file, 'r') as file:
        reader = csv.reader(file)
        headers = next(reader)
        old_columns = headers.copy()
        headers = [header for header in headers if header.strip() != '']
        skipped_columns = len(old_columns) - len(headers)
        for row_number, row in enumerate(reader, start=1):
            if all(value == '' for value in row):
                skipped_rows.append(row_number)
                continue
            elif fix_empty_value:
                for i, value in enumerate(row):
                    if value == '':
                        if previous_row is not None:
                            row[i] = previous_row[i]
                        else:
                            for j in range(row_number - 1, 0, -1):
                                if data[j][i] != '':
                                    row[i] = data[j][i]
                                    break
            data.append(dict(zip(headers, row)))
            previous_row = row
    if skipped_rows and args.details:
        print(f"Skipped {len(skipped_rows)} rows: {', '.join(map(str, skipped_rows))}")
    with open(json_file, 'w') as file:
        json.dump(data, file, indent=4)
        print(f'Exported {len(data)} rows, skipped {len(skipped_rows)} rows + {skipped_columns} empty columns, output to {json_file}')


if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser(description='Export CSV file to JSON file.')
    parser.add_argument('-i', '--input-file', required=True, help='Path of input CSV file.')
    parser.add_argument('-o', '--out-file', required=True, help='Path of output JSON file.')
    parser.add_argument('--fix-empty-value', action='store_true', help='Reuse upper column values for empty value.')
    parser.add_argument('-d', '--details', action='store_true', help='Show details of skipped rows and columns.')
    if len(sys.argv) == 1:
        parser.print_help(sys.stderr)
    args = parser.parse_args()
    csv_file = os.path.expanduser(args.input_file)
    json_file = os.path.expanduser(args.out_file)
    convert_csv_to_json(csv_file, json_file, args.fix_empty_value)
