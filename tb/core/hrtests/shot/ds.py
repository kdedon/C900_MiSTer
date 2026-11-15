import sys
from PIL import Image
im=Image.open(sys.argv[1]).convert('L')
W,H=im.size
x0,x1=48,1392
def px(dx,dy):
    sx=x0+(dx+0.5)*(x1-x0)/1024; sy=(dy+0.5)*H/800
    return im.getpixel((int(sx),int(sy)))
cx,cy,r=int(sys.argv[2]),int(sys.argv[3]),int(sys.argv[4])
print('    '+''.join(str((x)%10) for x in range(cx-r,cx+r)))
for y in range(cy-r,cy+r):
    print('%4d'%y+''.join('#' if px(x,y)<128 else '.' for x in range(cx-r,cx+r)))
