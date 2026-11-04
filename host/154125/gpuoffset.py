#!/usr/bin/python3 -I
# gpuoffset.py get <gpu> | set <gpu> <core|mem> <MHz> [pstate]   (set needs root)
import ctypes, sys
nv = ctypes.CDLL("libnvidia-ml.so.1")
class Off(ctypes.Structure):
    _fields_ = [("version", ctypes.c_uint), ("type", ctypes.c_int), ("pstate", ctypes.c_int),
                ("clockOffsetMHz", ctypes.c_int), ("minClockOffsetMHz", ctypes.c_int),
                ("maxClockOffsetMHz", ctypes.c_int)]
VER = ctypes.sizeof(Off) | (1 << 24)
TYPES = {"core": 0, "mem": 2}
def ck(r, what):
    if r: raise SystemExit(f"{what}: NVML error {r}")
ck(nv.nvmlInit_v2(), "init")
h = ctypes.c_void_p(); ck(nv.nvmlDeviceGetHandleByIndex_v2(int(sys.argv[2]), ctypes.byref(h)), "handle")
if sys.argv[1] == "get":
    for name, t in TYPES.items():
        for ps in (0, 1, 2):
            o = Off(version=VER, type=t, pstate=ps)
            r = nv.nvmlDeviceGetClockOffsets(h, ctypes.byref(o))
            print(f"{name} P{ps}: " + (f"{o.clockOffsetMHz} MHz (range {o.minClockOffsetMHz}..{o.maxClockOffsetMHz})" if r == 0 else f"err {r}"))
else:
    ps = int(sys.argv[5]) if len(sys.argv) > 5 else 0
    o = Off(version=VER, type=TYPES[sys.argv[3]], pstate=ps, clockOffsetMHz=int(sys.argv[4]))
    ck(nv.nvmlDeviceSetClockOffsets(h, ctypes.byref(o)), "set")
    print(f"gpu{sys.argv[2]} {sys.argv[3]} P{ps} offset -> {sys.argv[4]} MHz")
