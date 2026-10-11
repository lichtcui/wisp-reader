#!/usr/bin/env python3
"""macOS libproc-based process sampler (ps/top/pgrep are unusable per project notes).

proc_pid_rusage(pid, RUSAGE_INFO_V2, buf) layout (64-bit):
  0..16 uuid | 16 user_time | 24 system_time | 32 pkg_idle_wkups | 40 interrupt_wkups
  48 pageins | 56 wired_size | 64 resident_size | 72 phys_footprint
"""
import ctypes, ctypes.util, os, time

_lib = ctypes.CDLL(ctypes.util.find_library("proc") or "/usr/lib/libproc.dylib")
_lib.proc_pid_rusage.restype = ctypes.c_int
_lib.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
RUSAGE_INFO_V2 = 2
BUF = ctypes.create_string_buffer(1024)


def rusage(pid):
    """Return (resident_bytes, phys_footprint_bytes) or (None, None)."""
    if _lib.proc_pid_rusage(pid, RUSAGE_INFO_V2, BUF) != 0:
        return None, None
    raw = BUF.raw
    res = int.from_bytes(raw[64:72], "little")
    foot = int.from_bytes(raw[72:80], "little")
    return res, foot


def rss_bytes(pid):
    return rusage(pid)[0]


def loadavg():
    return os.getloadavg()


if __name__ == "__main__":
    import sys
    pid = int(sys.argv[1]) if len(sys.argv) > 1 else os.getpid()
    print("self   ", rusage(os.getpid()))
    print("target ", pid, rusage(pid))
    print("loadavg", loadavg())
