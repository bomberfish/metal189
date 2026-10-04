#!/bin/bash
# A/B an engine option inside one run: tools/bench_ab.sh KEY OFFVALUE ONVALUE [W H] [run-client args]
# Frames run one at a time on the GPU (option 8), so "gpu" is each variant's exact GPU frame time.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
sed -e "s/{K}/$1/g" -e "s/{OFF}/$2/g" -e "s/{ON}/$3/g" "$ROOT/tools/bench/ab.tmpl" > "$ROOT/run/bench_ab.txt"
LOG=${BENCH_LOG:-/tmp/m189-bench-ab.log}
BENCH_LOG=$LOG BENCH_SCRIPT="$ROOT/run/bench_ab.txt" "$ROOT/tools/bench.sh" "${4:-3440}" "${5:-1440}" "${@:6}" >/dev/null
python3 - "$LOG" <<'PY'
import sys,re,collections
fps=collections.defaultdict(list); gpu=collections.defaultdict(list); cur=None
for l in open(sys.argv[1]):
    m=re.search(r'\] fps 4 ((on|off)\d+)$',l.strip())
    if m: cur=m.group(1); continue
    m=re.search(r'fps ((on|off)\d+) = ([\d.]+)',l)
    if m: fps[m.group(2)].append(float(m.group(3))); cur=None; continue
    m=re.search(r'gpu frame time avg ([\d.]+)',l)
    if m and cur: gpu[re.sub(r'\d','',cur)].append(float(m.group(1)))
    if 'Exception' in l or 'FATAL' in l: print(l.strip())
for k in ('off','on'):
    g=gpu[k]; f=fps[k]
    print('%-3s fps %s mean %.1f | gpu ms %s mean %.3f'%(k,' '.join('%.0f'%v for v in f),sum(f)/max(1,len(f)),' '.join('%.2f'%v for v in g),sum(g)/max(1,len(g))))
PY
