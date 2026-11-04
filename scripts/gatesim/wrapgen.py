import re, sys
# wrapgen.py <netlist.vo> <rtl.sv> <module> : renames the netlist module to <module>_gl
# and writes wrap.sv, a <module> with the RTL's port list around it.
vo, rtl, mod = sys.argv[1:4]
v = open(vo).read()
open('gl.vo', 'w').write(re.sub(r'^module %s \(' % mod, 'module %s_gl (' % mod, v, count=1, flags=re.M))
conns = []
for m in re.finditer(r'^(input|output)\s+(\[\d+:\d+\])?\s*(\w+);', v, re.M):
    d, rng, name = m.groups()
    mm = re.match(r'^(\w+?)_(\d+)_(\d+)$', name)
    if mm and not rng:
        conns.append('.%s(%s[%s][%s])' % (name, mm.group(1), mm.group(2), mm.group(3)))
    else:
        conns.append('.%s(%s)' % (name, name))
src = open(rtl).read()
hdr = re.search(r'^module %s\b.*?\);' % mod, src, re.M | re.S).group(0)
hdr = re.sub(r'\s*import [^;]*;', '', hdr)
open('wrap.sv', 'w').write(hdr + '\n  %s_gl u (\n    ' % mod + ',\n    '.join(conns) + ');\nendmodule\n')
