# Decode the C900_DISK_DEBUG overlay from MiSTer screenshots: 40 words of
# 32 bit cells, 20 rows of two.  disk_dbg_decode.py shot.png...
import sys
from PIL import Image
for f in sys.argv[1:]:
    im = Image.open(f).convert('RGB')
    print(f)
    for row in range(20):
        line=[]
        for c in range(2):
            v = 0; bad=0
            for bit in range(32):
                nib, bn = divmod(bit, 4)
                x = 14 + c * 356 + nib * 44 + bn * 10
                y = 242 + row * 9
                r, g, b = im.getpixel((x, y))
                on = g > 160 and r < 100
                off = 40 < r < 120 and abs(r-g) < 10
                if not on and not off: bad += 1
                v = (v << 1) | on
            line.append('w%-2d %08X%s' % (row*2+c, v, '?' if bad else ''))
        print('   '.join(line))
