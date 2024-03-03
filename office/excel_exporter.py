#!/usr/bin/env python3
# autopep8: --max-line-length=160
# pip install pandas openpyxl xlsxwriter xlrd
import json
import sys
import pandas as pd
import os
import re


class ExeclExporter:
    def __init__(self, input_excel_path: str, output_file_path: str, sheet_name='Sheet1', skip_column_regex="^None#", force_number_column_regex='^None#', auto_fix_number_columns=True, fix_empty_value=False):
        self.input_excel_path = input_excel_path
        self.out_file = output_file_path
        self.sheet_name = sheet_name
        self.skip_column_regex = re.compile(skip_column_regex, re.IGNORECASE)
        self.force_number_column_regex = re.compile(force_number_column_regex, re.IGNORECASE)
        self.fix_empty_value = fix_empty_value
        self.auto_fix_number_columns = auto_fix_number_columns
        if not re.compile(r'\.(csv|json)$', re.IGNORECASE).search(self.out_file):
            raise Exception("Only support output CSV + JSON, please check file name: " + self.out_file)

    def export_excel_sheet(self):
        df = pd.read_excel(self.input_excel_path, sheet_name=self.sheet_name)
        # Filter out columns with empty or null names
        df = df.loc[:, df.columns.notnull() & (df.columns != '')]
        df = df.loc[:, ~df.columns.str.contains(self.skip_column_regex)]

        if self.auto_fix_number_columns:
            for col in df.select_dtypes(include=['float']).columns:
                if df[col].dropna().apply(float.is_integer).all():  # Check non-NaN values if all are integers
                    df[col] = df[col].astype(pd.Int64Dtype())  # Handle NaN with Int64Dtype

        number_columns = df.columns[df.columns.str.contains(self.force_number_column_regex)]
        for col in number_columns:
            df[col] = df[col].apply(lambda x: int(x) if pd.notnull(x) else x).astype(pd.Int64Dtype())

        empty_row_numbers = []
        for index, row in df.iterrows():
            if row.isnull().all():
                empty_row_numbers.append(index + 1)
                df.drop(index, inplace=True)
            elif self.fix_empty_value:
                for col in df.columns:
                    if pd.isnull(row[col]):
                        for i in range(index-1, -1, -1):
                            if not pd.isnull(df.at[i, col]):
                                df.at[index, col] = df.at[i, col]
                                break
        df.reset_index(drop=True, inplace=True)

        if self.out_file.lower().endswith('.csv'):
            df.to_csv(self.out_file, index=False)
        else:
            # df.to_json(self.out_file, orient='records', indent=4)
            data_list = df.to_dict(orient='records')
            with open(self.out_file, 'w', encoding='utf-8') as json_writer:
                json.dump(data_list, json_writer, ensure_ascii=False, indent=4)

        print(f'Saved {len(df)} rows (skipped {len(empty_row_numbers)} rows) to {self.out_file}')


if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser(description="Export Excel to CSV or JSON file.")
    parser.add_argument('-i', "--input-file", required=True, help="Path to the Excel file")
    parser.add_argument('-o', '--out-file', required=True, help="Output path of CSV or JSON file, export by file extension.")
    parser.add_argument('-n', '--sheet-name', default='Sheet1', help="Sheet name to export, like: Sheet1")
    parser.add_argument('-s', '--skip-column-regex', default="^None#", help="Regex pattern to skip columns by name.")
    parser.add_argument('-f', '--force-number-column-regex', default="^None#", help="Regex pattern to force set number columns by name.")
    parser.add_argument('-z', '--not-auto-fix-number-columns', action='store_true', help="Not auto detect and fix number column types.")
    parser.add_argument('-e', '--fix-empty-value', action='store_true', help='Reuse upper column values for empty value.')

    if len(sys.argv) == 1:
        parser.print_help(sys.stderr)
    args = parser.parse_args()

    excel_path = os.path.expanduser(args.input_file)
    out_path = os.path.expanduser(args.out_file)
    exporter = ExeclExporter(
        input_excel_path=excel_path,
        output_file_path=out_path,
        sheet_name=args.sheet_name,
        skip_column_regex=args.skip_column_regex,
        force_number_column_regex=args.force_number_column_regex,
        auto_fix_number_columns=not args.not_auto_fix_number_columns,
        fix_empty_value=args.fix_empty_value
    )
    exporter.export_excel_sheet()
