"""Capture the daily house from Moku's native renderer for the landing page.

Run: python3 website/scripts/export-house.py
Builds an isolated copy of the visual module; never changes app sources or assets.
"""
from pathlib import Path
import json
import os
import shutil
import subprocess
import sys
from PIL import Image

site = Path(__file__).resolve().parents[1]
repo = site.parent
staging = site / 'review/house-export'
native = staging / 'Sources/MokuVisual'
capture = staging / 'Sources/Capture'
capture.mkdir(parents=True, exist_ok=True)
shutil.copytree(repo / 'app/MokuVisual/Sources/MokuVisual', native, dirs_exist_ok=True)
(staging / 'Package.swift').write_text('''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "MokuHouseCapture", platforms: [.macOS(.v15)],
    dependencies: [.package(path: %s)],
    targets: [
        .target(name: "MokuVisual", dependencies: [.product(name: "MokuKit", package: "MokuKit")], resources: [.process("Resources")]),
        .executableTarget(name: "Capture", dependencies: ["MokuVisual", .product(name: "MokuKit", package: "MokuKit")])
    ])
''' % json.dumps(str(repo / 'app/MokuKit')))
(capture / 'main.swift').write_text('''import AppKit
import MokuKit
import MokuVisual
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
Task { @MainActor in
    do {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        let minutes = (0...DayHouse.pieces).map { Double($0) * DayHouse.minutesPerPiece }
        try await MokuVisualDiagnostics.dayHouseLookCheck(directory: directory, minutes: minutes)
        let data: [String: Any] = [
            "minutesPerPiece": DayHouse.minutesPerPiece, "pieces": DayHouse.pieces,
            "goalMinutes": DayHouse.goalMinutes, "pieceNames": DayHouse.pieceNames,
            "stages": DayHouse.stages.map { ["name": $0.name, "first": $0.first] as [String: Any] }
        ]
        try JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("progress.json"))
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("House capture failed: \\(error)\\n".utf8))
        exit(1)
    }
}
app.run()
''')
frames = staging / 'frames'
frames.mkdir(exist_ok=True)
if '--encode-only' not in sys.argv:
    subprocess.run(['swift', 'build', '-c', 'release', '--package-path', str(staging)], check=True)
    subprocess.run([str(staging / '.build/release/Capture'), str(frames)],
                   env={**os.environ, 'MOKU_ASSETS_DIR': str(repo / 'assets')}, check=True)

data = json.loads((frames / 'progress.json').read_text())
output = site / 'public/images/house'
output.mkdir(parents=True, exist_ok=True)
for piece in range(data['pieces'] + 1):
    minutes = round(piece * data['minutesPerPiece'])
    with Image.open(frames / f'houseday-{minutes:03}.png') as image:
        image.save(output / f'{minutes:03}.webp', format='WEBP', quality=92, method=6)
(site / 'src/house-data.json').write_text(json.dumps(data, indent=2) + '\n')
print(f"Exported {data['pieces'] + 1} native daily-house stages.", flush=True)
