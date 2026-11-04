#!/usr/bin/env python3
"""Move app lib/ files into this repo's lib/src/, leaving an export shim behind.

  python3 tool/coremove.py [--dry] lib-path.dart[=core-path.dart] ...

Paths are relative to the app's lib/ (the sibling ../xprs) and to lib/src/
here. A file that still imports app-only code is REFUSED with the reason, so
cut that edge first (a CoreHost seam, or move the dependency too).

Each moved file's imports are rewritten: to a relative path when the target
moves too (or already lives in core), to the final package: URI when the target
is a re-export shim, and refused when the target stays in the app.
"""
import os, re, sys
HERE=os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP=os.path.join(os.path.dirname(HERE),'xprs','lib'); CORE=os.path.join(HERE,'lib','src')
args=[a for a in sys.argv[1:] if not a.startswith('--')]
DRY='--dry' in sys.argv
mapping={}
for a in args:
    src,_,dst=a.partition('=')
    mapping[os.path.normpath(src)]=os.path.normpath(dst or src)
DIR=re.compile(r"""^(\s*(?:import|export)\s+)'([^']+)'((?:\s+if\s*\([^)]*\)\s*'[^']+')*)([^;]*);""", re.M)
def shim_exports(rel):
    """If app file [rel] only re-exports package URIs, return [(uri, clause)]."""
    p=os.path.join(APP,rel)
    if not os.path.exists(p): return None
    src=open(p).read()
    body=re.sub(r"/\*.*?\*/","",src,flags=re.S)
    body='\n'.join(l for l in body.splitlines() if l.strip() and not l.strip().startswith('//'))
    ex=re.findall(r"export\s+'([^']+)'([^;]*);", body)
    rest=re.sub(r"export\s+'[^']+'[^;]*;","",body).strip()
    if ex and not rest and all(u.startswith('package:') for u,_ in ex): return ex
    return None
def shim_target(rel):
    ex=shim_exports(rel)
    return ex[0][0] if ex and len(ex)==1 and not ex[0][1].strip() else None
problems=[]
def resolve(uri, from_rel_app, from_rel_core):
    if uri.startswith('dart:'): return uri
    if uri.startswith('package:') and not uri.startswith('package:xprs/'): return uri
    tgt = uri[13:] if uri.startswith('package:xprs/') else os.path.normpath(os.path.join(os.path.dirname(from_rel_app), uri))
    if tgt in mapping:
        return os.path.relpath(mapping[tgt], os.path.dirname(from_rel_core))
    st=shim_target(tgt)
    if st:
        if st.startswith('package:xprs_core/src/'):
            return os.path.relpath(st[len('package:xprs_core/src/'):], os.path.dirname(from_rel_core))
        return st
    problems.append(f"{from_rel_app}: imports app-only {tgt}")
    return uri
def rewrite(src, rel_app, rel_core):
    def sub(m):
        kw,uri,cond,rest=m.groups()
        # A multi-export shim: one directive per export, its own show/hide kept.
        if not cond and (uri.startswith('package:xprs/') or not uri.startswith(('package:','dart:'))):
            tgt = uri[13:] if uri.startswith('package:xprs/') else os.path.normpath(os.path.join(os.path.dirname(rel_app), uri))
            ex = None if tgt in mapping else shim_exports(tgt)
            if ex and len(ex)>1:
                if rest.strip(): problems.append(f"{rel_app}: {uri}{rest} needs a manual split"); return m.group(0)
                return '\n'.join(f"{kw}'{u}'{c};" for u,c in ex)
        new=resolve(uri, rel_app, rel_core)
        conds=re.sub(r"'([^']+)'", lambda c: "'"+resolve(c.group(1), rel_app, rel_core)+"'", cond)
        return f"{kw}'{new}'{conds}{rest};"
    return DIR.sub(sub, src)
HDR="// Moved to the shared core package (xprs-dev/core). This shim keeps the\n// app's existing imports working; new code should import package:xprs_core.\n"
out={}
for a,c in mapping.items():
    out[(a,c)]=rewrite(open(os.path.join(APP,a)).read(), a, c)
if problems:
    print("REFUSED:"); [print("  ",p) for p in sorted(set(problems))]; sys.exit(1)
for (a,c),src in out.items():
    print(f"move {a} -> core/lib/src/{c}")
    if DRY: continue
    dst=os.path.join(CORE,c); os.makedirs(os.path.dirname(dst),exist_ok=True)
    open(dst,'w').write(src)
    open(os.path.join(APP,a),'w').write(HDR+f"export 'package:xprs_core/src/{c}';\n")
