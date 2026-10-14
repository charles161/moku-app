"""Export native Moku motion to transparent WebP, without changing the app.

Run from any directory: python3 website/scripts/export-motion.py [--companion tetsu]
Requires macOS 15+, Xcode command-line tools and Pillow with WebP support.
All compilation and PNG intermediates stay in the ignored website/review folder.
Moku's clips go to public/motion/; another companion's, from assets/character/<id>/, to
public/motion/<id>/ under the same names, and the site's switcher shows it from then on.

Every clip also gets a half-size copy, <name>.320.webp, for phones and slow connections
(native-motion.js picks it): the same frames, resized and encoded like the drift clip.
  --encode-only   re-encode every clip and its copy from the captured frames
  --variants      write only the half-size copies, from the captured frames, or, for a clip
                  with none captured here, from the published clip's own frames; the
                  published clips stay byte for byte. Re-encoding only: nothing is redrawn.
The manifest gives each file's URL with ?v=<its hash>, so vercel.json can cache it for good.
"""
from pathlib import Path
import hashlib
import json
import os
import shutil
import subprocess
import sys
from PIL import Image, ImageSequence

companion = sys.argv[sys.argv.index('--companion') + 1] if '--companion' in sys.argv else 'moku'
if companion not in ('moku', 'tetsu'):
    sys.exit(f'Unknown companion: {companion}')
site = Path(__file__).resolve().parents[1]
repo = site.parent
staging = site / 'review/motion-export'
frames = staging / ('frames' if companion == 'moku' else f'frames-{companion}')
variants_only = '--variants' in sys.argv


def render():
    """Builds the capture package from the app's sources and renders every clip's frames."""
    sources = staging / 'Sources'
    native = sources / 'MokuVisual'
    native.mkdir(parents=True, exist_ok=True)
    shutil.copytree(repo / 'app/MokuVisual/Sources/MokuVisual', native, dirs_exist_ok=True)
    with (native / 'RealityCharacter.swift').open('a') as file:
        file.write('\n' + (site / 'scripts/NativeWebMotion.swift').read_text())
    capture = sources / 'Capture'
    capture.mkdir(exist_ok=True)
    (staging / 'Package.swift').write_text('''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "MokuWebCapture", platforms: [.macOS(.v15)],
    dependencies: [.package(path: %s)],
    targets: [
        .target(name: "MokuVisual", dependencies: [.product(name: "MokuKit", package: "MokuKit")], resources: [.process("Resources")]),
        .executableTarget(name: "Capture", dependencies: ["MokuVisual"])
    ])
''' % json.dumps(str(repo / 'app/MokuKit')))
    (capture / 'main.swift').write_text('''import AppKit
import MokuVisual
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
Task { @MainActor in
    do {
        try await MokuWebMotionExporter.export(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("Native capture failed: \\(error)\\n".utf8))
        exit(1)
    }
}
app.run()
''')
    assets = staging / 'assets'
    assets.mkdir(exist_ok=True)
    for source in (repo / 'assets').iterdir():
        if source.name == 'runtime':
            continue
        link = assets / source.name
        if not link.exists():
            link.symlink_to(source, target_is_directory=source.is_dir())
    (assets / 'runtime').mkdir(exist_ok=True)
    for source in (repo / 'assets/runtime').iterdir():
        dest = assets / 'runtime' / source.name
        if source.name == 'studio.json':
            # The app's own light (Charles picked the new light for the app and the site, 2026-10-04). A slightly wider
            # lens than the app's framing (20.5° rather than 18°) leaves headroom, so a raised ear never touches the
            # frame's top; the site's CSS scales the clips by WEB_SCALE to keep Moku's size and place.
            studio = json.loads(source.read_text())
            studio['camera']['fieldOfView'] = 20.5
            dest.write_text(json.dumps(studio, indent=2))
        elif not dest.exists():
            dest.symlink_to(source, target_is_directory=source.is_dir())
    frames.mkdir(exist_ok=True)
    subprocess.run(['swift', 'build', '-c', 'release', '-j', '4', '--package-path', str(staging)], check=True)
    env = {**os.environ, 'MOKU_ASSETS_DIR': str(assets), 'MOKU_COMPANION': companion}
    subprocess.run([str(staging / '.build/release/Capture'), str(frames)], env=env, check=True)



if '--encode-only' not in sys.argv and not variants_only:
    render()

folder = '' if companion == 'moku' else f'{companion}/'
output = site / 'public/motion' / folder
output.mkdir(parents=True, exist_ok=True)
# Half the clips' 640 px: what a phone's corner shows in the wide shot, at 3x.
SMALL = 320


def durations(milliseconds, count):
    # Each frame is due at the floor of its ideal time. Rounding up can land a frame
    # a fraction of a millisecond after its 60 Hz vsync, and the browser then shows
    # it a whole frame late (a 30 fps clip judders). Whole milliseconds, same total.
    return [(i + 1) * milliseconds // count - i * milliseconds // count for i in range(count)]


def light(images, temporary, milliseconds, method=3, **options):
    # The drift's clip is the heaviest and the hero waits on it: quality 72 with sparse keyframes is 2.27 to 1.48 MB
    # and looks the same on the page (47 dB against quality 88, composited on the paper).
    images[0].save(temporary, format='WEBP', save_all=True, append_images=images[1:], duration=durations(milliseconds, len(images)), loop=1, quality=72, method=method, minimize_size=False, allow_mixed=False, kmin=30, kmax=60, **options)


def encode(images, destination, milliseconds, name):
    temporary = destination.with_name(f'.{destination.name}.tmp')
    if len(images) == 1:
        images[0].save(temporary, format='WEBP', lossless=True, method=6)
    elif name == 'content-to-disappointed':
        light(images, temporary, milliseconds)
    else:
        images[0].save(temporary, format='WEBP', save_all=True, append_images=images[1:], duration=durations(milliseconds, len(images)), loop=1, quality=88, method=3, minimize_size=False, allow_mixed=False, kmin=9, kmax=17)
    temporary.replace(destination)


def encode_small(images, destination, milliseconds):
    """The half-size copy: resized with premultiplied alpha (no dark fringe on the fur), then the drift clip's light
    encoding, with the encoder's slowest method and its alpha at quality 60. At 320 px the outline's alpha is about
    half the file; at 60 it's a quarter smaller, and the edges look the same, even under the camera's 2.2x close-up
    (website/README.md, Native motion export)."""
    small = [image.convert('RGBa').resize((SMALL, SMALL), Image.LANCZOS).convert('RGBA') for image in images]
    temporary = destination.with_name(f'.{destination.name}.tmp')
    if len(small) == 1:
        small[0].save(temporary, format='WEBP', lossless=True, method=6)
    else:
        light(small, temporary, milliseconds, method=6, alpha_quality=60)
    temporary.replace(destination)
    for image in small:
        image.close()


def published(name, spec):
    """A clip's frames as published, for a clip with none captured here (--variants only). The encoder merged
    frames that didn't change into one longer frame; each captured frame is the one showing at its start time."""
    clip = Image.open(output / f'{name}.webp')
    shown, end = [], 0
    for frame in ImageSequence.Iterator(clip):
        image = frame.convert('RGBA')  # decoding the frame is what sets its duration
        end += frame.info.get('duration', 0)
        shown.append((end, image))
    milliseconds = round(spec['seconds'] * 1000)
    starts = [i * milliseconds // spec['frames'] for i in range(spec['frames'])]
    images = [next((image for until, image in shown if start < until), shown[-1][1]) for start in starts]
    if len(images) > 1 and end != milliseconds:
        sys.exit(f'{name}: the published clip lasts {end} ms, the manifest {milliseconds}')
    return images


def address(path):
    # The file's URL with its content's hash, so a re-export is a new URL and the old one can be cached for good.
    return f'/motion/{folder}{path.name}?v={hashlib.sha256(path.read_bytes()).hexdigest()[:10]}'


if variants_only:
    manifest = json.loads((output / 'manifest.json').read_text())
    captured = json.loads((frames / 'captures.json').read_text()) if (frames / 'captures.json').exists() else {}
else:
    manifest = json.loads((frames / 'captures.json').read_text())
    captured = manifest
for name, spec in manifest.items():
    milliseconds = round(spec['seconds'] * 1000)
    from_frames = name in captured and captured[name]['frames'] == spec['frames'] and (frames / name / '0000.png').exists()
    images = [Image.open(frames / name / f'{i:04d}.png').convert('RGBA') for i in range(spec['frames'])] if from_frames else published(name, spec)
    destination = output / f'{name}.webp'
    if not variants_only:
        encode(images, destination, milliseconds, name)
    small = output / f'{name}.{SMALL}.webp'
    encode_small(images, small, milliseconds)
    spec['duration'] = milliseconds
    spec['url'] = address(destination)
    spec['bytes'] = destination.stat().st_size
    spec['variants'] = {str(SMALL): {'url': address(small), 'bytes': small.stat().st_size}}
    print(f'Encoded {name}: {spec["bytes"] // 1024} KB, {SMALL} px {spec["variants"][str(SMALL)]["bytes"] // 1024} KB{"" if from_frames else " (from the published clip)"}', flush=True)
    for image in images:
        image.close()
(output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
print(f'Exported {len(manifest)} native motions.', flush=True)
