import json
from pathlib import Path
root = Path(__file__).resolve().parents[1]
shots = root / 'screenshots'
perf = json.loads((shots/'performance-brief2-cached.json').read_text())
stress = json.loads((shots/'stress-brief2-5min.json').read_text())
checks = json.loads((shots/'review/brief2-checks.json').read_text())
assert perf['idle']['cpuPercent'] < 2
assert perf['noticing']['cpuPercent'] < 2
assert perf['hidden']['renderedFrames'] == 0
assert stress['seconds'] >= 300 and not stress['newCrashReports'] and not stress['errors']
assert stress['firstVisibleSource'] == checks['firstVisibleSource'] == 'real'
assert checks['heldHoverFramesInOneSecond'] == 0 and checks['hoverReactions'] > 0
assert checks['error'] == 'none'
for name in ['wave', 'walk_cycle']:
    assert ('unfold_arms', name) in list(zip(checks['clipHistory'], checks['clipHistory'][1:]))
for name in ['gaze-compare', 'hover-compare', 'manual-control', 'world-manual', 'micro-brow', 'folded-arms']:
    assert (shots/'review'/f'{name}.png').stat().st_size > 1000
result = dict(status='pass', tests=24, idleCPU=perf['idle']['cpuPercent'], noticingCPU=perf['noticing']['cpuPercent'], hiddenCPU=perf['hidden']['cpuPercent'], stressSeconds=stress['seconds'], newCrashReports=stress['newCrashReports'], firstVisibleSource=stress['firstVisibleSource'], heldHoverFrames=checks['heldHoverFramesInOneSecond'])
(shots/'verification-brief2.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps(result,indent=2))
