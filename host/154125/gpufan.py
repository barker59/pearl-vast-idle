#!/usr/bin/python3 -I
# Set GeForce fan speed via NVML (nvidia-smi can't on GeForce).
# gpufan.py get | set <gpu> <pct> | auto <gpu>     (set/auto need root)
import ctypes, sys
nv = ctypes.CDLL("libnvidia-ml.so.1")
def ck(r):
    if r: raise SystemExit(f"NVML error {r}")
ck(nv.nvmlInit_v2())
def handle(i):
    h = ctypes.c_void_p(); ck(nv.nvmlDeviceGetHandleByIndex_v2(i, ctypes.byref(h))); return h
def fans(h):
    n = ctypes.c_uint(); ck(nv.nvmlDeviceGetNumFans(h, ctypes.byref(n))); return n.value
cmd = sys.argv[1]
if cmd == "get":
    c = ctypes.c_uint(); ck(nv.nvmlDeviceGetCount_v2(ctypes.byref(c)))
    for i in range(c.value):
        h = handle(i); lo, hi = ctypes.c_uint(), ctypes.c_uint()
        ck(nv.nvmlDeviceGetMinMaxFanSpeed(h, ctypes.byref(lo), ctypes.byref(hi)))
        sp = []
        for f in range(fans(h)):
            s = ctypes.c_uint(); ck(nv.nvmlDeviceGetFanSpeed_v2(h, f, ctypes.byref(s))); sp.append(s.value)
        print(f"gpu{i} fans={sp} range={lo.value}-{hi.value}%")
elif cmd == "set":
    h = handle(int(sys.argv[2])); p = int(sys.argv[3])
    for f in range(fans(h)): ck(nv.nvmlDeviceSetFanSpeed_v2(h, f, p))
elif cmd == "auto":
    h = handle(int(sys.argv[2]))
    for f in range(fans(h)): ck(nv.nvmlDeviceSetDefaultFanSpeed_v2(h, f))
