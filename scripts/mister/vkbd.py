# Virtual USB keyboard through uinput: vkbd.py <code>[+<code>...] [...]
# Each argument is a chord of Linux key codes pressed in order, released in reverse.
import fcntl, os, struct, sys, time
EV_SYN, EV_KEY = 0, 1
fd = os.open('/dev/uinput', os.O_WRONLY | os.O_NONBLOCK)
fcntl.ioctl(fd, 0x40045564, EV_KEY)
for k in range(1, 128):
    fcntl.ioctl(fd, 0x40045565, k)
dev = struct.pack('80sHHHHi', b'vkbd', 3, 0x1234, 0x5678, 1, 0) + b'\0' * (64 * 4 * 4)
os.write(fd, dev)
fcntl.ioctl(fd, 0x5501)
time.sleep(3)
def ev(t, c, v):
    s = time.time()
    os.write(fd, struct.pack('llHHi', int(s), int((s % 1) * 1e6), t, c, v))
def key(c, v):
    ev(EV_KEY, c, v); ev(EV_SYN, 0, 0); time.sleep(0.08)
for chord in sys.argv[1:]:
    ks = [int(x) for x in chord.split('+')]
    for k in ks: key(k, 1)
    for k in reversed(ks): key(k, 0)
    time.sleep(0.3)
time.sleep(1)
fcntl.ioctl(fd, 0x5502)
os.close(fd)
