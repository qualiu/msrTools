#!/usr/bin/env python3
# autopep8: --max-line-length=160

import os
import csv
import json
import argparse
import sys

parser = argparse.ArgumentParser(description='Export JSON to CSV file.')
parser.add_argument('-i', '--input-file', required=True, help='Input JSON file path.')
parser.add_argument('-o', '--out-file', required=True, help='Output result CSV file path.')


def convert_json_to_csv(json_file_path, csv_file_path):
    with open(json_file_path) as json_reader:
        data = json.load(json_reader)
        header = data[0].keys()
        with open(csv_file_path, 'w', newline='') as csv_writer:
            writer = csv.DictWriter(csv_writer, fieldnames=header)
            writer.writeheader()
            writer.writerows(data)
            print(f'Saved {len(data)} rows to csv file: {csv_file_path}')


if __name__ == '__main__':
    if len(sys.argv) == 1:
        parser.print_help(sys.stderr)
    args = parser.parse_args()
    json_file = os.path.expanduser(args.input_file)
    csv_file = os.path.expanduser(args.out_file)
    convert_json_to_csv(json_file, csv_file)
