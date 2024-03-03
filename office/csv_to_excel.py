#!/usr/bin/env python3
# autopep8: --max-line-length=160
# pip install pandas openpyxl xlsxwriter
import sys
import pandas as pd
import os
import re


def csv_to_excel(csv_path, excel_path, text_column_name_pattern):
    text_column_regex = re.compile(text_column_name_pattern, re.IGNORECASE)
    df = pd.read_csv(csv_path)
    df.to_excel(excel_path, index=False)

    for column in df.columns:
        if text_column_regex.search(column):
            df[column] = df[column].astype(str)

    writer = pd.ExcelWriter(excel_path, engine='xlsxwriter')
    df.to_excel(writer, index=False, sheet_name='Sheet1')
    worksheet = writer.sheets['Sheet1']
    workbook = writer.book
    text_format = workbook.add_format({'num_format': '@', 'align': 'left'})
    left_format = workbook.add_format({'align': 'left'})
    for i, column in enumerate(df.columns):
        is_text_column = text_column_regex.search(column)
        column_width = max(df[column].astype(str).map(len).max(), len(column))
        column_width = max(30, column_width) if is_text_column else max(10, column_width)
        cell_format = text_format if is_text_column else left_format
        worksheet.set_column(first_col=i, last_col=i, width=column_width, cell_format=cell_format)
        print(f'Column[{i+1}] = {column}, width = {column_width}')

    writer.close()
    print(f'Saved {len(df)} rows to {excel_path}')


if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser(description="Export CSV file to Excel file.")
    parser.add_argument('-i', "--input-file", required=True, help="Path of input CSV file")
    parser.add_argument('-o', '--out-file', required=True, help="Path of output Excel file")
    parser.add_argument('-t', '--text-column-regex', default="_id(_|$)", type=str, help="Regex pattern of text column name.")
    if len(sys.argv) == 1:
        parser.print_help(sys.stderr)
    args = parser.parse_args()

    csv_path = os.path.expanduser(args.input_file)
    excel_path = os.path.expanduser(args.out_file)
    text_column_pattern = "^#" if not args.text_column_regex else args.text_column_regex
    csv_to_excel(csv_path, excel_path, text_column_pattern)
