#!/usr/bin/env python3
"""Builds the client classpath (and extracts arm64 natives) from Prism's metadata."""
import json, os, sys, zipfile

PRISM = os.path.expanduser('~/Library/Application Support/PrismLauncher')
LIB = os.path.join(PRISM, 'libraries')

def path_for(name, classifier=None):
    parts = name.split(':')
    group, art, ver = parts[0], parts[1], parts[2]
    cls = parts[3] if len(parts) > 3 else classifier
    fn = '%s-%s%s.jar' % (art, ver, ('-' + cls) if cls else '')
    return os.path.join(LIB, group.replace('.', '/'), art, ver, fn)

def main(natives_dir):
    cp = []
    natives = []
    for meta in ['net.minecraftforge/11.15.1.1902.json', 'net.minecraft/1.8.9.json', 'org.lwjgl/2.9.4-nightly-20150209.json']:
        d = json.load(open(os.path.join(PRISM, 'meta', meta)))
        for l in d.get('libraries', []):
            n = l['name']
            if l.get('natives'):
                cls = l['natives'].get('osx-arm64') or l['natives'].get('osx')
                if cls:
                    p = path_for(n, cls.replace('${arch}', '64'))
                    if os.path.exists(p): natives.append(p)
                continue
            p = path_for(n)
            if os.path.exists(p): cp.append(p)
            else: print('missing', p, file=sys.stderr)
        if 'mainJar' in d:
            cp.append(path_for(d['mainJar']['name']))
    os.makedirs(natives_dir, exist_ok=True)
    for j in natives:
        with zipfile.ZipFile(j) as z:
            for e in z.namelist():
                if e.startswith('META-INF') or e.endswith('/'): continue
                out = os.path.join(natives_dir, os.path.basename(e))
                with open(out, 'wb') as f: f.write(z.read(e))
    # keep order but drop duplicates
    seen = set(); res = []
    for p in cp:
        if p not in seen: seen.add(p); res.append(p)
    print(':'.join(res))

main(sys.argv[1])
