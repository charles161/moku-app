"""Small copies of the daily house's renders, for the hero's home chip and the piece that lands.

Run from any directory: python3 website/scripts/house-thumbs.py   (Pillow with WebP support)

The chip shows the render about 46 px wide (34 px, scaled 1.35), so a 160 px copy covers a 3x
phone; the full 800 px render is 50 KB, this about 4 KB. Writes public/images/house/thumb/<NNN>.webp
for the cottage, and public/images/house/<id>/thumb/ for each companion with its own renders. Re-run
after export-house.py. Resizing and re-encoding only: nothing is redrawn.
"""
from pathlib import Path
from PIL import Image

site = Path(__file__).resolve().parents[1]
WIDTH = 160

for folder in [site / 'public/images/house', *sorted(p for p in (site / 'public/images/house').iterdir() if p.is_dir() and p.name not in ('thumb', 'hologram'))]:
    renders = sorted(folder.glob('[0-9][0-9][0-9].webp'))
    if not renders:
        continue
    (folder / 'thumb').mkdir(exist_ok=True)
    total = 0
    for render in renders:
        with Image.open(render) as image:
            small = image.convert('RGB').resize((WIDTH, round(image.height * WIDTH / image.width)), Image.LANCZOS)
            out = folder / 'thumb' / render.name
            small.save(out, format='WEBP', quality=82, method=6)
            total += out.stat().st_size
    print(f'{folder.relative_to(site)}: {len(renders)} thumbs, {total // 1024} KB')
