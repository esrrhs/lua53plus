#!/usr/bin/env python3
"""Build both libraries in isolation; interleave fresh-process repetitions."""
import hashlib, json, os, pathlib, platform, shlex, shutil, statistics, subprocess, sys, tarfile
from check_gc_metrics import evaluate
ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = pathlib.Path(os.environ.get('GC_BENCH_DIR', ROOT / 'validation-results' / 'benchmark')).resolve()
OUT.mkdir(parents=True, exist_ok=True)
SHA = 'f681aa518233bc407e23acf0f5887c884f17436f000d453b2491a9f11a52400c'
archive = OUT / 'lua-5.3.4.tar.gz'
if not archive.exists():
    subprocess.run(['curl','-fL','--connect-timeout','20','--max-time','180','https://www.lua.org/ftp/lua-5.3.4.tar.gz','-o',str(archive)],check=True)
if hashlib.sha256(archive.read_bytes()).hexdigest() != SHA:
    raise SystemExit('official Lua 5.3.4 SHA256 mismatch')
base = OUT / 'lua-5.3.4'
with tarfile.open(archive) as f:
    # Always restore sources from the verified archive, even on repeated runs.
    # Only src is needed; upstream documentation is read-only, so extracting
    # the whole archive again would fail on a second benchmark invocation.
    members = [m for m in f.getmembers() if m.name.startswith('lua-5.3.4/src/')]
    f.extractall(OUT, members=members, **({'filter': 'data'} if hasattr(tarfile, 'data_filter') else {}))
plus = OUT / 'plus'
(plus / 'src').mkdir(parents=True, exist_ok=True)
for p in (ROOT / 'src').iterdir():
    if p.suffix in ('.c','.h') or p.name == 'Makefile': shutil.copy2(p,plus / 'src' / p.name)
cc = shlex.split(os.environ.get('CC','cc'))
cflags = shlex.split(os.environ.get('GC_BENCH_CFLAGS','-O2 -std=gnu99 -DLUA_USE_POSIX -DLUA_USE_DLOPEN'))
ldflags = shlex.split(os.environ.get('GC_BENCH_LDFLAGS','-lm' + ('' if sys.platform=='darwin' else ' -ldl')))
for name, directory in [('baseline',base),('plus',plus)]:
    src = directory / 'src'
    with (OUT / (name+'-build.log')).open('w') as log:
        subprocess.run(['make','clean'],cwd=src,stdout=log,stderr=subprocess.STDOUT,check=True)
        # Same compiler, optimization and defines, no ltests/asserts/sanitizers.
        subprocess.run(['make','liblua.a','CC='+shlex.join(cc),'CFLAGS='+shlex.join(cflags),'MYCFLAGS='],cwd=src,stdout=log,stderr=subprocess.STDOUT,check=True)
        subprocess.run(cc+cflags+['-I'+str(src),str(ROOT/'bench/gc_metrics.c'),str(src/'liblua.a')]+ldflags+['-o',str(OUT/(name+'-runner'))],stdout=log,stderr=subprocess.STDOUT,check=True)
# Quantify listprev alone without changing/running a collector: a header-only
# counterfactual excludes just the two declarations (padding included).
shadow = OUT / 'layout-without-listprev'
shadow.mkdir(exist_ok=True)
for p in (plus/'src').glob('*.h'):
    data=p.read_text()
    if p.name=='lobject.h':
        lines=data.splitlines(True)
        removed=[line for line in lines if 'GCObject *listprev;' in line]
        if len(removed)!=2: raise SystemExit('listprev layout changed; update probe')
        data=''.join(line for line in lines if line not in removed)
    (shadow/p.name).write_text(data)
probe=OUT/'layout.c'
probe.write_text('#include <stdio.h>\n#include "lobject.h"\nint main(void){printf("%zu %zu",sizeof(Table),sizeof(Udata));return 0;}\n')
subprocess.run(cc+cflags+['-I'+str(shadow),str(probe),'-o',str(OUT/'layout-probe')],check=True)
no_prev=list(map(int,subprocess.check_output([str(OUT/'layout-probe')],text=True).split()))
n = int(os.environ.get('GC_BENCH_SAMPLES','10000'))
reps = int(os.environ.get('GC_BENCH_REPEATS','5'))
if reps<3: raise SystemExit('at least 3 repetitions required')
results = {'baseline':[], 'plus':[]}
# One discarded full-process warmup of each; each measured process also warms 500 ticks.
for name in results: subprocess.run([str(OUT/(name+'-runner')),str(n)],check=True,stdout=subprocess.DEVNULL)
for i in range(reps):
    for name in (['baseline','plus'] if i%2==0 else ['plus','baseline']):
        results[name].append(json.loads(subprocess.check_output([str(OUT/(name+'-runner')),str(n)],text=True)))
medians = {name:{k:statistics.median(x[k] for x in rows) for k in rows[0]} for name,rows in results.items()}
ratios = {k:medians['plus'][k]/medians['baseline'][k] for k in medians['plus'] if medians['baseline'][k]}
# No default pass/fail budgets invented from one shared host. Opt in using a
# JSON file calibrated from your dedicated runner's repeated historical data.
# Wide budgets can use both a relative ratio AND absolute slack in the same unit.
gates = json.loads(pathlib.Path(os.environ['GC_BENCH_LIMITS']).read_text()) if os.environ.get('GC_BENCH_LIMITS') else {}
failed = evaluate(medians, gates)
report = {'machine':platform.platform(),'compiler':subprocess.check_output(cc+['--version'],text=True).splitlines()[0],
          'revision':subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),
          'worktree_status':subprocess.check_output(['git','status','--short'],cwd=ROOT,text=True),
          'workload':{'resident_tables':20000,'pairs_per_tick':64,'warmup_ticks':500,'gc_step_kb':0,'discarded_process_runs_per_engine':1,'repeats':reps},
          'cflags':cflags,'ldflags':ldflags,'official_sha256':SHA,'raw':results,'medians':medians,'ratios':ratios,
          'listprev_bytes_per_object':{'Table':medians['plus']['sizeof_table']-no_prev[0], 'Udata':medians['plus']['sizeof_udata']-no_prev[1]},
          'gates':gates,'failed':failed,'gate_mode':'enforced' if gates else 'report-only'}
(OUT/'metrics.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps({'medians':medians,'ratios':ratios,'gate_mode':report['gate_mode'],'listprev_bytes_per_object':report['listprev_bytes_per_object'],'failed':failed},indent=2))
if failed: sys.exit(1)
