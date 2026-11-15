# t11: dshell-hole model. Cursor drawn by kernel XOR, smgr white clip fill
# with its hide dropped, kernel erase at the same place -> full arrow left.
PAT=[0xfffc,0xfff8,0xfff0,0xffe0,0xffc0,0xffc0,0xffe0,0xfff0,
     0xfff8,0xfffc,0xf3fe,0xe1ff,0x80ff,0x007f,0x003e,0x001c]
X=508
sh=X&7
rows=[((p<<16)>>sh)&0xffffffff for p in PAT]
L=[]
e=L.append
e("start:")
e("\tldl\trr14, $0x08001000")
def merge(y,xb):
    for r,v in enumerate(rows):
        a=0x3E000000+(y+r)*128+xb
        for k in range(3):
            b=(v>>(24-8*k))&0xff
            if b==0: continue
            e("\tldl\trr12, $0x%08X"%(a+k))
            e("\tldb\trl1, @rr12")
            e("\txorb\trl1, $0x%02X"%b)
            e("\tldb\t@rr12, rl1")
def fillbg(y):
    for r in range(-1,17):
        for wb in range(60,70,2):
            e("\tldl\trr12, $0x%08X"%(0x3E000000+(y+r)*128+wb))
            e("\tld\tr1, $0xAAAA")
            e("\tld\t@rr12, r1")
def clrclip(y):
    # clip left edge x=507: word at byte 62 keeps pixels 496..506
    for r in range(16):
        base=0x3E000000+(y+r)*128
        e("\tldl\trr12, $0x%08X"%(base+62))
        e("\tld\tr1, @rr12")
        e("\tand\tr1, $0xFFE0")
        e("\tld\t@rr12, r1")
        for wb in (64,66):
            e("\tldl\trr12, $0x%08X"%(base+wb))
            e("\tld\tr1, $0")
            e("\tld\t@rr12, r1")
YA,YB=20,60
fillbg(YA); fillbg(YB)
merge(YA,X//8)          # A: cursor drawn
merge(YB,X//8)          # B: cursor drawn
clrclip(YA)             # A: smgr fill, hide dropped (dmgr is event manager)
merge(YB,X//8)          # B: hide honoured: erase, fill, redraw
clrclip(YB)
merge(YB,X//8)
merge(YA,X//8)          # mouse moves: kernel erases at the old place
merge(YB,X//8)
e("2:")
e("\tjr\t2b")
open('t11.s','w').write('\n'.join(L)+'\n')
