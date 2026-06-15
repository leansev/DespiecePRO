# -*- coding: utf-8 -*-
import json
import sys

from openpyxl import Workbook
from openpyxl.styles import Alignment, Font, PatternFill

HEADERS = [
    'cantidad',
    'LARGO',
    'ANCHO',
    'nombre',
    'rota',
    'canto_arr',
    'canto_aba',
    'canto_izq',
    'canto_der',
]

COLOR_HEADER_BG = '2F4F7F'
COLOR_HEADER_FG = 'FFFFFF'
COLOR_MODULE_BG = '4A7C9E'
COLOR_MODULE_FG = 'FFFFFF'
COLOR_ROW_ALT = 'EEF2F7'
COLOR_WHITE = 'FFFFFF'


def solid_fill(color):
    return PatternFill(fill_type='solid', fgColor=color)


def load_payload(json_path):
    with open(json_path, encoding='utf-8-sig') as handle:
        return json.load(handle)


def write_header_row(sheet, row_index):
    fill = solid_fill(COLOR_HEADER_BG)
    font = Font(bold=True, color=COLOR_HEADER_FG)

    for column_index, header in enumerate(HEADERS, start=1):
        cell = sheet.cell(row=row_index, column=column_index, value=header)
        cell.font = font
        cell.fill = fill
        cell.alignment = Alignment(horizontal='center')


def write_module_row(sheet, row_index, label):
    fill = solid_fill(COLOR_MODULE_BG)
    font = Font(bold=True, color=COLOR_MODULE_FG)

    for column_index in range(1, len(HEADERS) + 1):
        cell = sheet.cell(row=row_index, column=column_index)
        cell.fill = fill
        if column_index == 1:
            cell.value = label
            cell.font = font

    sheet.merge_cells(
        start_row=row_index,
        start_column=1,
        end_row=row_index,
        end_column=len(HEADERS),
    )


def write_piece_row(sheet, row_index, item, use_alt_fill):
    values = [
        item['cantidad'],
        item['largo'],
        item['ancho'],
        item['nombre'],
        item.get('rota', 1),
        item.get('canto_arr', 0),
        item.get('canto_aba', 0),
        item.get('canto_izq', 0),
        item.get('canto_der', 0),
    ]
    fill_color = COLOR_ROW_ALT if use_alt_fill else COLOR_WHITE
    fill = solid_fill(fill_color)

    for column_index, value in enumerate(values, start=1):
        cell = sheet.cell(row=row_index, column=column_index, value=value)
        cell.fill = fill


def write_total_row(sheet, row_index, label):
    cell = sheet.cell(row=row_index, column=1, value=label)
    cell.font = Font(bold=True)


def write_xlsx(output_path, payload):
    workbook = Workbook()
    sheet = workbook.active
    sheet.title = 'Despiece'

    row_index = 1
    title = payload.get('project_title', 'PROYECTO: Sin nombre')
    title_cell = sheet.cell(row=row_index, column=1, value=title)
    title_cell.font = Font(bold=True)
    sheet.merge_cells(
        start_row=row_index,
        start_column=1,
        end_row=row_index,
        end_column=len(HEADERS),
    )
    row_index += 1

    write_header_row(sheet, row_index)
    row_index += 1

    use_alt_fill = False
    for item in payload.get('rows', []):
        row_type = item.get('type')

        if row_type == 'module':
            write_module_row(sheet, row_index, item.get('label', ''))
            row_index += 1
            use_alt_fill = False
        elif row_type == 'piece':
            write_piece_row(sheet, row_index, item, use_alt_fill)
            use_alt_fill = not use_alt_fill
            row_index += 1
        elif row_type == 'total':
            write_total_row(sheet, row_index, item.get('label', ''))
            row_index += 1

    for column_index, header in enumerate(HEADERS, start=1):
        width = max(len(header) + 2, 12)
        column_letter = sheet.cell(row=2, column=column_index).column_letter
        sheet.column_dimensions[column_letter].width = width

    workbook.save(output_path)


def main():
    if len(sys.argv) < 3:
        sys.stderr.write('Uso: export_excel.py salida.xlsx datos.json\n')
        sys.exit(1)

    output_path = sys.argv[1]
    json_path = sys.argv[2]
    payload = load_payload(json_path)
    write_xlsx(output_path, payload)


if __name__ == '__main__':
    main()
