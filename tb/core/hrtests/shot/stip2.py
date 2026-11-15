exec(open('stip.py').read().split('ref=')[0])
ref=[row(r) for r in range(4)]
for r in range(800):
    rw=row(r); rf=ref[r%4]
    xs=[i+48 for i in range(len(rw)) if rw[i]!=rf[i] and not (148<=r<=552 and 704<=i+48<=1244)]
    if xs: print(r,xs[:12],len(xs))
