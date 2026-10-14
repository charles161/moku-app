#!/usr/bin/env python3
"""Review sheets for the smile survey (the demo's --smile-survey and --pleased-reel): every pleased frame at the size
the app shows Moku (about 100 px from feet to crown) and at 2x, labelled, with the frames that may not read as smiling
outlined in red (from the face weights shown, see `reads_pleased`).

  smile-sheets.py survey <survey-dir> <out-dir> [--tag before|after]
  smile-sheets.py reel <reel-dir> <out-dir> [--tag before|after] [--every N]
  smile-sheets.py compare <before-dir> <after-dir> <out.jpg> <title> <group/name>...   (survey frames, before over after)
  smile-sheets.py strips <before-reel> <after-reel> <out.jpg> <title> <label:from:to>...  (reel moments, before over after)
  smile-sheets.py reel-strips <reel> <out.jpg> <title> <label:from:to>...  (one reel's moments, nothing outlined)
  smile-sheets.py turn <before-dir> <after-dir> <out.jpg>   (the demo's --smile-turn: the look-up's lids, frame by frame)
"""
import csv, json, sys
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

PAPER = (247, 245, 238)
INK = (52, 70, 51)
RED = (196, 64, 52)
# Moku in the 640 px live render: crown at y 176, feet at y 458, so about 284 px tall.
CROP = (160, 150, 480, 470)
BODY_PX = 284


def font(size):
    for path in ['/System/Library/Fonts/Supplemental/Arial.ttf', '/System/Library/Fonts/Helvetica.ttc']:
        try:
            return ImageFont.truetype(path, size)
        except OSError:
            pass
    return ImageFont.load_default()


def reads_pleased(face):
    """A rough reading of the face weights shown, at 100 px: closed happy arcs, smiling lower lids and lifted cheeks are
    what read; the hairline w barely does. Upper lids lowered without the lower lid rising read as tired, and a full
    blink as asleep. Returns (score, why) where a score under 0.35 is flagged."""
    g = lambda k: float(face.get(k, 0))
    arcs = max(g('eyes_happy'), g('eyes_proud'))
    lids = (g('blink_L') + g('blink_R')) / 2
    lower = g('lid_smile_lower')
    score = arcs + 0.7 * lower + 0.5 * g('cheeks_raise') + 0.25 * max(g('smile'), g('mouth_smile_open')) + 0.15 * g('blush_more')
    score -= 0.9 * max(0, lids - lower - 0.08) * (1 - arcs)
    score -= g('frown') + 0.6 * g('pout') + 0.6 * g('lips_press') + 0.8 * g('brows_concern') + g('brows_angry') + 0.5 * g('lid_sad')
    why = []
    if lids > 0.5 and arcs < 0.3: why.append('lids shut')
    elif lids - lower > 0.12 and arcs < 0.3: why.append('heavy lids')
    if arcs < 0.3 and lower < 0.2 and g('cheeks_raise') < 0.3: why.append('round eyes')
    for k in ['frown', 'pout', 'lips_press', 'brows_concern', 'lid_sad']:
        if g(k) > 0.05: why.append(k)
    return score, why


def tile(image_path, label, face, scale, flag_threshold=0.35):
    im = Image.open(image_path).convert('RGBA').crop(CROP)
    w, h = im.size
    k = scale * 100 / BODY_PX
    im = im.resize((max(1, round(w * k)), max(1, round(h * k))), Image.LANCZOS)
    score, why = reads_pleased(face)
    pad = 4
    small = font(10 if scale == 1 else 13)
    lines = [label, f'{score:.2f}' + (' · ' + ', '.join(why) if why else '')]
    text_h = (len(lines)) * (12 if scale == 1 else 16) + 4
    cell = Image.new('RGB', (max(im.width, 120 if scale == 1 else 200) + 2 * pad, im.height + text_h + 2 * pad), PAPER)
    cell.paste(im, ((cell.width - im.width) // 2, pad), im)
    d = ImageDraw.Draw(cell)
    for i, line in enumerate(lines):
        d.text((pad, im.height + pad + 2 + i * (12 if scale == 1 else 16)), line, fill=RED if (i == 1 and score < flag_threshold) else INK, font=small)
    if score < flag_threshold:
        d.rectangle([0, 0, cell.width - 1, cell.height - 1], outline=RED, width=2)
    return cell, score


def sheet(cells, columns, title, path):
    if not cells:
        return
    cw = max(c.width for c in cells); ch = max(c.height for c in cells)
    rows = (len(cells) + columns - 1) // columns
    out = Image.new('RGB', (columns * cw + 20, rows * ch + 50), PAPER)
    d = ImageDraw.Draw(out)
    d.text((10, 12), title, fill=INK, font=font(18))
    for i, c in enumerate(cells):
        out.paste(c, (10 + (i % columns) * cw, 44 + (i // columns) * ch))
    out.save(path, quality=90)


def survey(src, dst, tag):
    rows = json.loads((src / 'survey.json').read_text())
    groups = {}
    for r in rows:
        groups.setdefault(r['group'], []).append(r)
    report = {}
    for scale in (1, 2):
        for group, items in groups.items():
            cells = []
            for r in items:
                cell, score = tile(src / r['group'] / (r['name'] + '.png'), r['label'] if group != 'moods' else r['label'], r['face'], scale)
                cells.append(cell)
                report[r['group'] + '/' + r['name']] = round(score, 3)
            columns = 11 if group in ('micro', 'transitions') else (12 if scale == 1 else 8)
            sheet(cells, columns, f'Smile survey · {group} · {"app size (~100 px)" if scale == 1 else "2x"} · {tag}', dst / f'{tag}-{group}-{scale}x.jpg')
    flagged = {k: v for k, v in report.items() if v < 0.35}
    (dst / f'{tag}-survey-scores.json').write_text(json.dumps({'flagged': flagged, 'all': report}, indent=1))
    print(f'{len(flagged)} of {len(report)} frames flagged')


def reel(src, dst, tag, every):
    faces = list(csv.DictReader(open(src / 'faces.csv')))
    by_beat = {}
    for row in faces:
        by_beat.setdefault(row['beat'], []).append(row)
    report = {}
    for scale in (1, 2):
        cells = []
        for beat, rows in by_beat.items():
            for row in rows[::every]:
                face = {k: float(v) for k, v in row.items() if k not in ('frame', 't', 'beat', 'mood')}
                path = src / 'frames' / f'r-{int(row["frame"]):05d}.png'
                if not path.exists():
                    continue
                cell, score = tile(path, f'{beat} {float(row["t"]):.2f}s ({row["mood"]})', face, scale)
                cells.append(cell)
                report[row['frame']] = (beat, round(score, 3))
        sheet(cells, 14 if scale == 1 else 9, f'Pleased moments on the clock · {"app size (~100 px)" if scale == 1 else "2x"} · {tag}', dst / f'{tag}-reel-{scale}x.jpg')
    flagged = {k: v for k, v in report.items() if v[1] < 0.35 and v[0] not in ('drift',)}
    (dst / f'{tag}-reel-scores.json').write_text(json.dumps({'flagged': flagged}, indent=1))
    print(f'{len(flagged)} of {len(report)} reel frames flagged (drift frames excluded)')


FACE = (230, 190, 420, 340)


def face_cell(path, label, face=None):
    """A close-up of the face at 2x and the whole of Moku at the app's size, side by side, labelled."""
    im = Image.open(path).convert('RGBA')
    close = im.crop(FACE).resize((228, 180), Image.LANCZOS)
    small = im.crop(CROP).resize((113, 113), Image.LANCZOS)
    cell = Image.new('RGB', (228 + 113 + 12, 200), PAPER)
    cell.paste(close, (0, 0), close); cell.paste(small, (234, 40), small)
    d = ImageDraw.Draw(cell)
    d.text((4, 183), label, fill=INK, font=font(12))
    if face is not None:
        score, why = reads_pleased(face)
        if score < 0.35: d.rectangle([0, 0, cell.width - 1, cell.height - 1], outline=RED, width=2)
    return cell


def compare(before, after, out, title, names):
    rows = {}
    for tag, src in (('before', before), ('after', after)):
        faces = {r['group'] + '/' + r['name']: r for r in json.loads((src / 'survey.json').read_text())}
        rows[tag] = [face_cell(src / (n + '.png'), faces[n]['label'], faces[n]['face']) for n in names]
    w = rows['before'][0].width; h = rows['before'][0].height
    sheet = Image.new('RGB', (70 + w * len(names), 50 + 2 * h + 10), PAPER)
    d = ImageDraw.Draw(sheet); d.text((10, 14), title, fill=INK, font=font(20))
    for j, tag in enumerate(('before', 'after')):
        d.text((8, 50 + j * (h + 10) + h // 2), tag, fill=INK, font=font(14))
        for i, cell in enumerate(rows[tag]): sheet.paste(cell, (70 + i * w, 50 + j * (h + 10)))
    sheet.save(out, quality=88)


def strips(before, after, out, title, spans, per=10, mark=True):
    """Each moment as it played on the clock, `per` frames across, before over after (or one reel, when `before` is
    None): the face at 2x. `mark`: outline frames that may not read as smiling."""
    lines = []
    for label, a, z in spans:
        for tag, src in ((('before', before), ('after', after)) if before else (('', after),)):
            rows = [r for r in csv.DictReader(open(src / 'faces.csv')) if a <= float(r['t']) <= z]
            step = max(1, len(rows) // per); lines.append((f'{label} · {tag}' if tag else label, rows[::step][:per], src))
    W, H = 150, 128
    sheet = Image.new('RGB', (150 + W * per, 50 + H * len(lines)), PAPER)
    d = ImageDraw.Draw(sheet); d.text((10, 14), title, fill=INK, font=font(20))
    for j, (label, rows, src) in enumerate(lines):
        y = 50 + j * H
        d.text((6, y + 54), label, fill=INK, font=font(12))
        for i, r in enumerate(rows):
            face = {k: float(v) for k, v in r.items() if k not in ('frame', 't', 'beat', 'mood')}
            im = Image.open(src / 'frames' / f'r-{int(r["frame"]):05d}.png').convert('RGBA').crop((200, 160, 440, 360)).resize((W, H - 14), Image.LANCZOS)
            sheet.paste(im, (150 + i * W, y), im)
            score, _ = reads_pleased(face); flag = mark and score < 0.35
            d.text((150 + i * W + 4, y + H - 14), f'{float(r["t"]):.2f} s', fill=RED if flag else INK, font=font(11))
            if flag: d.rectangle([150 + i * W, y, 150 + (i + 1) * W - 2, y + H - 2], outline=RED, width=2)
    sheet.save(out, quality=88)


def turn(before, after, out):
    """The look-up (--smile-turn): how shut the eyes are as the mesh shows them, frame by frame, before and after (a
    plot, with the head's turn), and the eyes over the reopening as the head turns back, every frame (60 fps)."""
    def load(src, kind):
        rows = list(csv.DictReader(open(src / f'turn-{kind}.csv')))
        shut = lambda r: max(float(r['sent_eyes_happy']), float(r['sent_eyes_proud']), (float(r['sent_blink_L']) + float(r['sent_blink_R'])) / 2)
        return [(float(r['t']), shut(r), float(r['head_yaw']), int(r['frame'])) for r in rows]
    W, PH, M = 1500, 220, 60
    kinds = ['smile', 'happyEyes']
    sheet = Image.new('RGB', (W, 60 + len(kinds) * (PH + 40) + 2 * len(kinds) * 112 + 40), PAPER)
    d = ImageDraw.Draw(sheet); f = font(13)
    d.text((10, 12), "The look-up smile, frame by frame: how shut Moku's eyes are as the mesh shows them (before: weights in 24ths; after: 240ths, smile-led arcs)", fill=INK, font=font(18))
    y = 50
    colours = {'before': (196, 64, 52), 'after': (52, 110, 70)}
    for kind in kinds:
        data = {tag: load(src, kind) for tag, src in (('before', before), ('after', after))}
        t0, t1 = 0, 4
        d.rectangle([M, y, W - 20, y + PH], outline=(200, 196, 186))
        d.text((M, y - 18), f'{kind}: eyes shut (0 open, 1 closed arcs); thin grey: head turn', fill=INK, font=f)
        X = lambda t: M + (t - t0) / (t1 - t0) * (W - 20 - M)
        for tag, rows in data.items():
            pts = [(X(t), y + PH - v * (PH - 10) - 5) for t, v, _, _ in rows if t0 <= t <= t1]
            for a, b in zip(pts, pts[1:]): d.line([a, b], fill=colours[tag], width=2)
            for p in pts: d.ellipse([p[0] - 1.5, p[1] - 1.5, p[0] + 1.5, p[1] + 1.5], fill=colours[tag])
            yaw = [(X(t), y + PH / 2 - yw * 2.5) for t, _, yw, _ in rows if t0 <= t <= t1]
            for a, b in zip(yaw, yaw[1:]): d.line([a, b], fill=(190, 186, 176), width=1)
        for i, tag in enumerate(colours): d.text((W - 200, y + 8 + i * 16), tag, fill=colours[tag], font=f)
        for s in range(5): d.text((X(s) - 4, y + PH + 4), f'{s} s', fill=INK, font=f)
        y += PH + 40
    # The eyes as the head turns back: 14 frames from where the lids start to open.
    for kind in kinds:
        for tag, src in (('before', before), ('after', after)):
            rows = load(src, kind)
            start = next((i for i, (t, v, _, _) in enumerate(rows) if t > 2.4 and v < max(r[1] for r in rows) - 0.001), 0)
            d.text((10, y + 40), f'{kind}\n{tag}', fill=colours[tag], font=f)
            for j, (t, v, _, n) in enumerate(rows[start:start + 14]):
                im = Image.open(src / f'eyes-{kind}' / f'e-{n:04d}.png').convert('RGBA').resize((95, 50), Image.LANCZOS)
                sheet.paste(im, (100 + j * 99, y + 20), im)
                d.text((100 + j * 99, y + 74), f'{v:.3f}', fill=INK, font=f)
                d.text((100 + j * 99, y + 90), f'{t:.3f}s', fill=(120, 120, 110), font=font(11))
            y += 112
    sheet.save(out, quality=90)


if __name__ == '__main__':
    if sys.argv[1] == 'turn':
        turn(Path(sys.argv[2]), Path(sys.argv[3]), Path(sys.argv[4])); sys.exit()
    if sys.argv[1] == 'compare':
        compare(Path(sys.argv[2]), Path(sys.argv[3]), Path(sys.argv[4]), sys.argv[5], sys.argv[6:]); sys.exit()
    if sys.argv[1] in ('strips', 'reel-strips'):
        # strips <before> <after> …: before over after; reel-strips <reel> …: one reel, nothing outlined.
        one = sys.argv[1] == 'reel-strips'; at = 3 if one else 4
        spans = [(s.split(':')[0], float(s.split(':')[1]), float(s.split(':')[2])) for s in sys.argv[at + 2:]]
        strips(None if one else Path(sys.argv[2]), Path(sys.argv[at - 1]), Path(sys.argv[at]), sys.argv[at + 1], spans, mark=not one); sys.exit()
    kind, src, dst = sys.argv[1], Path(sys.argv[2]), Path(sys.argv[3])
    tag = sys.argv[sys.argv.index('--tag') + 1] if '--tag' in sys.argv else 'before'
    every = int(sys.argv[sys.argv.index('--every') + 1]) if '--every' in sys.argv else 3
    dst.mkdir(parents=True, exist_ok=True)
    survey(src, dst, tag) if kind == 'survey' else reel(src, dst, tag, every)
