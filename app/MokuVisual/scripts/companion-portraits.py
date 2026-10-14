"""The welcome's companion tiles, from the app's own renders (the website's clips, which website/scripts/export-motion.py
makes with the app's renderer): per companion, a still portrait (companion-<id>.png) and its hello clip
(hello-<id>.webp: the wave, 144 px square at 24 fps, cropped so the whole wave fits and the feet rest on the bottom).
Run from the repo root after re-exporting the clips:
python3 app/MokuVisual/scripts/companion-portraits.py [--from-branch <branch>]   (Tetsu's clips may live on a branch
until they're on the site)."""
import io, subprocess, sys
from pathlib import Path
from PIL import Image

repo = Path(__file__).resolve().parents[3]
out = repo / 'app/MokuVisual/Sources/MokuVisual/Resources'
branch = sys.argv[sys.argv.index('--from-branch') + 1] if '--from-branch' in sys.argv else None
HELLO_SIDE, HELLO_FPS = 144, 24

def clip(path):
    if (repo / path).exists() and not branch:
        return Image.open(repo / path)
    data = subprocess.run(['git', '-C', str(repo), 'show', f'{branch or "HEAD"}:{path}'], capture_output=True, check=True).stdout
    return Image.open(io.BytesIO(data))

def frames(im):
    for index in range(getattr(im, 'n_frames', 1)):
        im.seek(index)
        yield im.convert('RGBA')

def portrait(companion, folder):
    im = clip(f'{folder}content-idle.webp').convert('RGBA')
    left, top, right, bottom = im.getbbox()
    side = max(right - left, bottom - top) + 16
    cx, cy = (left + right) // 2, (top + bottom) // 2
    square = Image.new('RGBA', (side, side), (0, 0, 0, 0))
    square.paste(im.crop((cx - side // 2, cy - side // 2, cx - side // 2 + side, cy - side // 2 + side)), (0, 0))
    square.resize((192, 192), Image.LANCZOS).save(out / f'companion-{companion}.png', optimize=True)

def hello(companion, folder):
    wave = list(frames(clip(f'{folder}content-wave.webp')))
    boxes = [frame.getbbox() for frame in wave]
    left, top = min(b[0] for b in boxes), min(b[1] for b in boxes)
    right, bottom = max(b[2] for b in boxes), max(b[3] for b in boxes)
    side = int(max(right - left, bottom - top) * 1.06)
    x0, y1 = (left + right) // 2 - side // 2, bottom + int(side * 0.02)
    box = (x0, y1 - side, x0 + side, y1)
    small = []
    for frame in wave:
        square = Image.new('RGBA', (side, side), (0, 0, 0, 0))
        square.paste(frame.crop(box), (0, 0))
        small.append(square.resize((HELLO_SIDE, HELLO_SIDE), Image.LANCZOS))
    path = out / f'hello-{companion}.webp'
    small[0].save(path, save_all=True, append_images=small[1:], duration=round(1000 / HELLO_FPS), loop=0, quality=88, method=6)
    return len(small), path.stat().st_size // 1024

for companion, folder in [('moku', 'website/public/motion/'), ('tetsu', 'website/public/motion/tetsu/')]:
    portrait(companion, folder)
    count, size = hello(companion, folder)
    print(companion, (out / f'companion-{companion}.png').stat().st_size // 1024, 'KB portrait;', count, 'frames,', size, 'KB hello')
