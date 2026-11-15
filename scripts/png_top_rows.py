# White rows near the top of RGB PNG screenshots (the HR console bell band).
# png_top_rows.py shot.png...
import zlib,struct,sys
def load(p):
    d=open(p,'rb').read(); i=8; idat=b''
    while i<len(d):
        l=struct.unpack('>I',d[i:i+4])[0]; t=d[i+4:i+8]; c=d[i+8:i+8+l]
        if t==b'IHDR': w,h=struct.unpack('>II',c[:8])
        if t==b'IDAT': idat+=c
        i+=12+l
    raw=zlib.decompress(idat); bpp=3; st=w*bpp; out=[]; prev=bytearray(st); o=0
    for y in range(h):
        f=raw[o]; o+=1; line=bytearray(raw[o:o+st]); o+=st
        for x in range(st):
            a=line[x-bpp] if x>=bpp else 0; b=prev[x]; c=prev[x-bpp] if x>=bpp else 0
            if f==1: line[x]=(line[x]+a)&255
            elif f==2: line[x]=(line[x]+b)&255
            elif f==3: line[x]=(line[x]+(a+b)//2)&255
            elif f==4:
                pp=a+b-c; pa,pb,pc=abs(pp-a),abs(pp-b),abs(pp-c)
                line[x]=(line[x]+(a if pa<=pb and pa<=pc else b if pb<=pc else c))&255
        out.append(line); prev=line
    return w,h,out
for p in sys.argv[1:]:
    w,h,rows=load(p)
    lit=[sum(1 for x in range(0,w*3,3) if r[x]>128) for r in rows[:60]]
    full=sum(1 for v in lit if v>w*0.9)
    print(p.split('/')[-1], 'rows0-59 >90%% white:', full, 'first rows lit:', lit[:3], lit[48:52])
