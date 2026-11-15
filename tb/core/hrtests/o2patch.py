import sys
d=open(sys.argv[1],'rb').read()
ts=int.from_bytes(d[0x0a:0x0e],'little'); t=d[0x30:0x30+ts]
base=0x38
out=open(sys.argv[2],'w')
for i in range(0,len(t),2):
    a=(base+i)//2
    out.write("%05x %02x\n%05x %02x\n"%(a,t[i],0x4000+a,t[i+1]))
print(len(t),'bytes')
