import sys
d=open(sys.argv[1],'rb').read();tb=int.from_bytes(d[6:8],'big');ts=int.from_bytes(d[8:12],'big');t=d[tb:tb+ts]
print(' '.join('%04x'%int.from_bytes(t[i:i+2],'big') for i in range(0,len(t),2)))
