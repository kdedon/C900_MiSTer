import sys
from PIL import Image
im=Image.open(sys.argv[1]).convert('L')
W,H=im.size; P=im.load()
xs=set(); ys=set()
for y in range(H):
    for x in range(1,W):
        if P[x,y]!=P[x-1,y]: xs.add(x)
for x in range(W):
    for y in range(1,H):
        if P[x,y]!=P[x,y-1]: ys.add(y)
xs=sorted(xs); ys=sorted(ys)
print(len(xs),xs[:10],xs[-10:]); print(len(ys),ys[:10],ys[-10:])
dx=[b-a for a,b in zip(xs,xs[1:])]; dy=[b-a for a,b in zip(ys,ys[1:])]
from collections import Counter
print(Counter(dx)); print(Counter(dy))
open('xs.txt','w').write(' '.join(map(str,xs))); open('ys.txt','w').write(' '.join(map(str,ys)))
