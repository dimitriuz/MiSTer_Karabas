# prototype: turn VHDL direct instantiations of Verilog modules into component instantiations
import re,glob,sys,os
d=sys.argv[1]
def strip_comments(s):
    s=re.sub(r'/\*.*?\*/','',s,flags=re.S); return re.sub(r'//[^\n]*','',s)
vmods={}
for f in glob.glob(os.path.join(d,'*.v')):
    s=strip_comments(open(f,errors='replace').read())
    for m in re.finditer(r'\bmodule\s+(\w+)\s*(#\s*\((.*?)\)\s*)?\((.*?)\)\s*;',s,re.S):
        vmods[m.group(1).lower()]=(m.group(1),m.group(3) or '',m.group(4))
vhd_ents=set()
for f in glob.glob(os.path.join(d,'*.vhd')):
    for m in re.finditer(r'^\s*entity\s+(\w+)\s+is',open(f,errors='replace').read(),re.I|re.M): vhd_ents.add(m.group(1).lower())
def rng(r):
    if not r: return None
    a,b=r.strip()[1:-1].split(':'); return f"({a.strip()} downto {b.strip()})"
def comp(name):
    n,params,ports=vmods[name]
    gens=[]
    for p in re.split(r',(?![^\[]*\])',params):
        m=re.match(r'\s*parameter\s+(\[[^\]]*\]\s*)?(\w+)\s*=\s*(.*)',p.strip(),re.S)
        if not m: continue
        if m.group(1): continue
        v=m.group(3).strip()
        if v.startswith('"'): gens.append(f"{m.group(2)} : string := {v}")
        elif re.fullmatch(r'-?\d+',v): gens.append(f"{m.group(2)} : integer := {v}")
        elif re.fullmatch(r"\d*'[bdh][0-9a-fA-F_]+",v):
            b,x=v.split("'")[1][0],v.split("'")[1][1:].replace('_','')
            gens.append(f"{m.group(2)} : integer := {int(x,{'b':2,'d':10,'h':16}[b])}")
        else: gens.append(f"{m.group(2)} : integer")
    pl=[]
    for p in re.split(r',(?![^\[]*\])',ports):
        m=re.match(r'\s*(input|output|inout)\s+(wire|reg)?\s*(signed)?\s*(\[[^\]]*\])?\s*(\w+)\s*(=\s*(.*))?$',p.strip(),re.S)
        if not m: raise SystemExit(f"cannot parse port {p!r} of {n}")
        dr={'input':'in','output':'out','inout':'inout'}[m.group(1)]
        r=rng(m.group(4))
        dv=''
        if m.group(7) is not None and dr == "in":
            v=m.group(7).strip()
            mm=re.fullmatch(r"(\d*)'([bdh])([0-9a-fA-F_]+)",v)
            if v in ('0',) or (mm and int(mm.group(3).replace('_',''),{'b':2,'d':10,'h':16}[mm.group(2)])==0) or re.fullmatch(r"\{\w+\{1'b0\}\}",v): dv=" := (others => '0')" if r else " := '0'"
            elif (mm and mm.group(2)=='b' and set(mm.group(3))=={'1'}) or re.fullmatch(r"\{\w+\{1'b1\}\}",v) or (mm and mm.group(2)=='h' and set(mm.group(3).lower())=={'f'}): dv=" := (others => '1')" if r else " := '1'"
            else: raise SystemExit(f"default {v!r} of {n}")
        if dr == "in" and not dv: dv=" := (others => '0')" if r else " := '0'"
        pl.append((f"{m.group(5)} : {dr} std_logic_vector{r}" if r else f"{m.group(5)} : {dr} std_logic")+dv)
    g=("  generic (\n    "+";\n    ".join(gens)+"\n  );\n") if gens else ""
    return f"component {n}\n{g}  port (\n    "+";\n    ".join(pl)+"\n  );\nend component;\n"
for f in glob.glob(os.path.join(d,'*.vhd')):
    s=open(f,errors='replace').read()
    used=[m.group(1) for m in re.finditer(r'entity\s+work\.(\w+)',s,re.I) if m.group(1).lower() in vmods and m.group(1).lower() not in vhd_ents]
    if not used: continue
    names=sorted(set(u.lower() for u in used))
    declared={m.group(1).lower() for m in re.finditer(r'^\s*component\s+(\w+)',s,re.I|re.M)}
    for u in names: s=re.sub(r'entity\s+work\.'+u+r'\b',vmods[u][0],s,flags=re.I)
    decl="".join(comp(u) for u in names if u not in declared)
    s,c=re.subn(r'(architecture\s+\w+\s+of\s+\w+\s+is\s*\n)',lambda m:m.group(1)+decl,s,count=1,flags=re.I)
    assert c==1,f
    open(f,'w').write(s); print("rewrote",os.path.basename(f),names)
