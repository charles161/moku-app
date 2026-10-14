#!/usr/bin/env python3
"""Reject missing clips, partial/stale coverage, clipping, islands and bind mismatches."""
import json,sys
from pathlib import Path
report=Path(sys.argv[1]);assets=Path(sys.argv[2]);rows=json.loads(report.read_text())
moods=['content','happy','proud','curious','concerned','disappointed','annoyed','sleepy']
clips=['idle']+sorted(p.stem for p in (assets/'character/anims').glob('*.usdz'))
assert len(rows)==len(moods)*len(clips), 'Incomplete render audit'
assert {(r['mood'],r['clip']) for r in rows}=={(m,c) for m in moods for c in clips}, 'Missing mood/clip combination'
for r in rows:
 assert r['pass'] and not r['failures'], f"Silhouette failure: {r['mood']}/{r['clip']}"
 assert r['bindDelta']<.0001, f"Asset bind mismatch: {r['clip']}"
 assert (r['frames']==1 if r['clip']=='idle' else r['frames']>=r['duration']*12), 'Incomplete sampling'
print(f"PASS: {len(rows)} combinations; {sum(r['frames'] for r in rows)} frames at 12 Hz plus endpoints")
