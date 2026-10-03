#!/usr/bin/env python3
"""Top / inclusive method counts for the client thread from a `jfr print --json` dump."""
import json, sys, collections
d = json.load(open(sys.argv[1]))
thread = sys.argv[2] if len(sys.argv) > 2 else 'Client thread'
top = collections.Counter(); incl = collections.Counter(); n = 0
for e in d['recording']['events']:
    v = e['values']
    if v.get('sampledThread', {}).get('javaName') != thread: continue
    st = v.get('stackTrace')
    if not st: continue
    fr = st['frames']; n += 1
    nm = lambda f: f['method']['type']['name'].split('/')[-1] + '.' + f['method']['name']
    top[nm(fr[0])] += 1
    seen = set()
    for f in fr[:60]:
        k = nm(f)
        if k not in seen: seen.add(k); incl[k] += 1
print('samples', n)
for k, c in top.most_common(30): print('%5d %5.1f%%  %s' % (c, 100.0 * c / n, k))
print('--- inclusive')
for k, c in incl.most_common(50): print('%5d %5.1f%%  %s' % (c, 100.0 * c / n, k))
