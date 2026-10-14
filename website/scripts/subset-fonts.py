"""Subset the headline's serif to the characters the site uses (docs/specs/next-0-1-9.md §3).

Run from any directory: python3 website/scripts/subset-fonts.py
Requires fontTools with WOFF2 support (pip install fonttools brotli).

Reads the full Latin fonts in website/fonts/ and writes website/src/fonts/, where Vite gives
each file a hashed name that vercel.json caches for good. The characters are every one in
index.html, privacy.html and src/ (the demo's typed work, Your day, the companions' words),
and all of printable ASCII, so a new word in the copy rarely needs a re-run. Run it after
adding text with characters outside that (accents, symbols): `npm test` names any missing.
Every OpenType feature is kept (kerning, ligatures), so the text sets exactly as before: the serif
pages render pixel for pixel the same. DM Sans is copied whole: subset, the chapter rail's 9 px
tabular digits moved by a device pixel, and it saves only 10 KB.
"""
from pathlib import Path
import html
import re
import shutil
import sys
from fontTools import subset

site = Path(__file__).resolve().parents[1]


def characters():
    text = ''
    for path in [site / 'index.html', site / 'privacy.html', *sorted((site / 'src').rglob('*'))]:
        if path.is_file() and path.suffix in ('.html', '.js', '.json', '.css'):
            source = path.read_text(encoding='utf-8')
            text += html.unescape(source)
            # \u2019 and friends, as JavaScript and CSS write them.
            text += ''.join(chr(int(code, 16)) for code in re.findall(r'\\u([0-9a-fA-F]{4})', source))
            text += ''.join(chr(int(code, 16)) for code in re.findall(r'\\([0-9a-fA-F]{4,6})\b', source) if path.suffix == '.css')
    used = {ord(c) for c in text if ord(c) > 0x7e and not (0xd800 <= ord(c) < 0xe000)}
    return sorted(set(range(0x20, 0x7f)) | {0xa0} | used)


def main():
    codes = characters()
    shutil.copyfile(site / 'fonts/sans-normal.woff2', site / 'src/fonts/sans-normal.woff2')
    for name in ('serif-normal', 'serif-italic'):
        options = subset.Options()
        options.flavor = 'woff2'
        options.layout_features = ['*']
        options.notdef_outline = True
        font = subset.load_font(str(site / 'fonts' / f'{name}.woff2'), options)
        subsetter = subset.Subsetter(options)
        subsetter.populate(unicodes=codes)
        subsetter.subset(font)
        out = site / 'src/fonts' / f'{name}.woff2'
        subset.save_font(font, str(out), options)
        kept = sorted(font.getBestCmap())
        print(f'{name}: {(site / "fonts" / f"{name}.woff2").stat().st_size // 1024} KB to {out.stat().st_size // 1024} KB, {len(kept)} characters')
    # What the fonts hold beyond ASCII, for src/fonts.test.js to check new copy against.
    (site / 'src/fonts/characters.txt').write_text(''.join(chr(code) for code in codes if code > 0x7e) + '\n', encoding='utf-8')


if __name__ == '__main__':
    sys.exit(main())
