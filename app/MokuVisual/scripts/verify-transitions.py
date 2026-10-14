import json, sys
rows = json.load(open(sys.argv[1]))
moods = {'content','happy','proud','curious','concerned','disappointed','annoyed','sleepy'}
expected = {(a,b) for a in moods for b in moods if a != b}
assert {(r['from'],r['to']) for r in rows} == expected, 'Missing transition coverage'
assert len(rows) == 56
for r in rows:
    assert r['fps'] == 60 and r['frames'] == 181
    assert r['pass'] and not r['failures'], (r['from'],r['to'],r['failures'][:3])
    assert r['longestHorizontalRun'] <= 5
print('PASS: 56 directed transitions, 10,136 samples; horizontal hold <=5 frames at 60Hz, no stub or detached silhouette.')

from pathlib import Path
blink = json.load(open(Path(sys.argv[1]).with_name('blink.json')))
assert blink['pass'] and all(0 <= x <= .28 for x in blink['closedToOpenIrisHeight']), blink
print('PASS: closed iris thickness gate.')
