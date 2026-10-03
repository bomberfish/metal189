#!/usr/bin/env python3
"""Scan jars for constant-pool references to a package prefix (default org/lwjgl/).
Prints owner.name desc with reference counts."""
import sys, zipfile, struct, collections

def refs(data):
    if data[:4] != b'\xca\xfe\xba\xbe': return []
    n = struct.unpack('>H', data[8:10])[0]
    pos = 10; cp = [None]*n; i = 1
    while i < n:
        tag = data[pos]
        if tag == 1:
            ln = struct.unpack('>H', data[pos+1:pos+3])[0]
            cp[i] = ('utf8', data[pos+3:pos+3+ln].decode('utf-8', 'replace')); pos += 3+ln
        elif tag in (3, 4): pos += 5
        elif tag in (5, 6): pos += 9; i += 1
        elif tag == 7: cp[i] = ('class', struct.unpack('>H', data[pos+1:pos+3])[0]); pos += 3
        elif tag == 8: pos += 3
        elif tag in (9, 10, 11):
            c, nt = struct.unpack('>HH', data[pos+1:pos+5]); cp[i] = ('ref', tag, c, nt); pos += 5
        elif tag == 12:
            a, b = struct.unpack('>HH', data[pos+1:pos+5]); cp[i] = ('nat', a, b); pos += 5
        elif tag == 15: pos += 4
        elif tag == 16: pos += 3
        elif tag == 18: pos += 5
        else: raise ValueError('bad tag %d' % tag)
        i += 1
    out = []
    for e in cp:
        if e and e[0] == 'ref':
            _, tag, c, nt = e
            cname = cp[cp[c][1]][1]
            _, a, b = cp[nt]
            out.append((cname, cp[a][1], cp[b][1], {9: 'F', 10: 'M', 11: 'I'}[tag]))
        elif e and e[0] == 'class':
            pass
    return out

prefix = 'org/lwjgl/'
args = sys.argv[1:]
if args and args[0].startswith('--prefix='):
    prefix = args[0].split('=', 1)[1]; args = args[1:]
cnt = collections.Counter(); users = collections.defaultdict(set)
for jar in args:
    z = zipfile.ZipFile(jar)
    for nm in z.namelist():
        if not nm.endswith('.class'): continue
        for (c, n, d, k) in refs(z.read(nm)):
            if c.startswith(prefix):
                key = '%s %s.%s %s' % (k, c, n, d); cnt[key] += 1; users[key].add(nm[:-6])
for key, v in sorted(cnt.items()):
    print('%5d %s   [%s]' % (v, key, ','.join(sorted(users[key])[:4])))
