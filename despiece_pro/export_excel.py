# -*- coding: utf-8 -*-
import json
import sys

from openpyxl import Workbook

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


def write_xlsx(output_path, payload):
    workbook = Workbook()
    sheet = workbook.active
    sheet.title = 'Despiece'
    sheet.append(HEADERS)

    for item in payload.get('rows', []):
        row_type = item.get('type')
        if row_type == 'module' or row_type == 'total':
            sheet.append(label_row(item.get('label', '')))
        elif row_type == 'piece':
            sheet.append(piece_row(item))

    workbook.save(output_path)


def load_payload():
    if len(sys.argv) >= 3:
        with open(sys.argv[2], encoding='utf-8-sig') as handle:
            return json.load(handle)

    return json.load(sys.stdin)


def main():
    if len(sys.argv) < 2:
        sys.stderr.write('Uso: export_excel.py salida.xlsx [datos.json]\n')
        sys.exit(1)

    output_path = sys.argv[1]
    payload = load_payload()
    write_xlsx(output_path, payload)


if __name__ == '__main__':
    main()
