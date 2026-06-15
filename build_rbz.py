import os
import zipfile


def build_rbz():
    output = 'despiece_pro.rbz'
    files = [
        ('despiece_pro.rb', 'despiece_pro.rb'),
        ('despiece_pro/main.rb', 'despiece_pro/main.rb'),
        ('despiece_pro/dialog.html', 'despiece_pro/dialog.html'),
        ('despiece_pro/export_excel.py', 'despiece_pro/export_excel.py'),
        ('despiece_pro/icons/scan_small.png', 'despiece_pro/icons/scan_small.png'),
        ('despiece_pro/icons/scan_large.png', 'despiece_pro/icons/scan_large.png'),
        ('despiece_pro/icons/list_small.png', 'despiece_pro/icons/list_small.png'),
        ('despiece_pro/icons/list_large.png', 'despiece_pro/icons/list_large.png'),
    ]

    with zipfile.ZipFile(output, 'w', zipfile.ZIP_DEFLATED) as zf:
        for local_path, arcname in files:
            if not os.path.exists(local_path):
                print(f"ERROR: No existe {local_path}")
                return
            zf.write(local_path, arcname)
            print(f"  + {arcname}")

    size_kb = os.path.getsize(output) / 1024
    print(f"\nGenerado: {output} ({size_kb:.1f} KB)")


build_rbz()
