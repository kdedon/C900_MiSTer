import sys
from PIL import Image
im=Image.open(sys.argv[1]).convert('L');P=im.load()
W,H=im.size
ys=[0]+list(map(int,open('ys.txt').read().split()))
# compare screen against itself shifted by the stipple period in screen space: find vertical period in rows
def row(r): return [P[x,ys[r]] for x in range(48,1403)]
# vertical period: rows r and r+p identical over desktop
for p in (2,4,8,16):
    same=sum(1 for r in range(0,100) if row(r)==row(r+p)); print('vper',p,same)
ref=[row(r) for r in range(4)]
diff=[]
for r in range(800):
    rw=row(r); rf=ref[r%4]
    xs=[i+48 for i in range(len(rw)) if rw[i]!=rf[i]]
    if xs: diff.append((r,min(xs),max(xs),len(xs)))
# compress: print ranges of rows
prev=None
for d in diff:
    print(d) if (d[3]<200) else None
