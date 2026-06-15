# -*- coding: utf-8 -*-
import csv
import json
import sys

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


def piece_row(item):
    return [
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


def label_row(label):
    return [label] + [''] * (len(HEADERS) - 1)


def build_matrix(rows):
    matrix = [HEADERS]
    for item in rows:
        row_type = item.get('type')
        if row_type == 'module' or row_type == 'total':
            matrix.append(label_row(item.get('label', '')))
        elif row_type == 'piece':
            matrix.append(piece_row(item))
    return matrix


def write_csv(path, matrix):
    with open(path, 'w', newline='', encoding='utf-8') as handle:
        writer = csv.writer(handle, delimiter='|')
        for row in matrix:
            writer.writerow(row)


def write_xlsx(path, matrix):
    from openpyxl import Workbook

    workbook = Workbook()
    sheet = workbook.active
    sheet.title = 'Despiece'

    for row in matrix:
        sheet.append(row)

    workbook.save(path)


def main():
    if len(sys.argv) != 3:
        sys.stderr.write('Uso: export_excel.py entrada.json salida.xlsx\n')
        sys.exit(1)

    json_path = sys.argv[1]
    output_path = sys.argv[2]

    with open(json_path, 'r', encoding='utf-8') as handle:
        payload = json.load(handle)

    matrix = build_matrix(payload.get('rows', []))

    try:
        write_xlsx(output_path, matrix)
        sys.exit(0)
    except ImportError:
        write_csv(output_path, matrix)
        sys.exit(0)
    except Exception as exc:
        sys.stderr.write('openpyxl fallo: {0}\n'.format(exc))
        write_csv(output_path, matrix)
        sys.exit(0)


if __name__ == '__main__':
    main()
