#!/usr/bin/env python3
"""Whether two app bundles are the same bytes: every file's contents, every link's target, every mode.
Usage: scripts/same-app.py <a.app> <b.app>. Exits 1 and names the differences when they aren't.
Sparkle's deltas check the installed app's hash, so the DMG's app and the update zip's app must match (notarize.sh)."""
import hashlib, os, stat, sys

def tree(root):
    out = {}
    for folder, dirs, files in os.walk(root, followlinks=False):
        for name in dirs + files:
            path = os.path.join(folder, name); rel = os.path.relpath(path, root); st = os.lstat(path)
            if stat.S_ISLNK(st.st_mode): out[rel] = ('link', os.readlink(path), st.st_mode & 0o777)
            elif stat.S_ISDIR(st.st_mode): out[rel] = ('dir', '', st.st_mode & 0o777)
            else:
                with open(path, 'rb') as f: out[rel] = ('file', hashlib.sha256(f.read()).hexdigest(), st.st_mode & 0o777)
    return out

a, b = tree(sys.argv[1]), tree(sys.argv[2])
problems = [f'only in {sys.argv[1]}: {k}' for k in sorted(set(a) - set(b))] + [f'only in {sys.argv[2]}: {k}' for k in sorted(set(b) - set(a))] \
    + [f'differs: {k}' for k in sorted(set(a) & set(b)) if a[k] != b[k]]
for line in problems[:20]: print(line)
sys.exit(1 if problems else 0)
