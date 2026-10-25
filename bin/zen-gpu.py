#!/usr/bin/env python3
"""zen-conky GPU helper.

Reads NVIDIA GPU temperature / load / power through NVML (libnvidia-ml),
which works without nvidia-smi. To avoid keeping a runtime-suspended dGPU
awake it only queries while the GPU is already active, and after a few idle
(0% load) readings backs off to a long interval so the driver can suspend it.

usage: zen-gpu.py OUTFILE [PID]   # exits when PID (conky) goes away
"""
import ctypes
import glob
import os
import sys
import time

OUT = sys.argv[1]
WATCH = int(sys.argv[2]) if len(sys.argv) > 2 else None
FAST, SLOW, IDLE_READS = 5, 30, 3


def read(path):
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return None


def find_gpu():
    for d in sorted(glob.glob('/sys/bus/pci/devices/*')):
        if read(d + '/vendor') == '0x10de' and (read(d + '/class') or '').startswith('0x03'):
            return d
    return None


class Util(ctypes.Structure):
    _fields_ = [('gpu', ctypes.c_uint), ('memory', ctypes.c_uint)]


class Mem(ctypes.Structure):
    _fields_ = [('total', ctypes.c_ulonglong), ('free', ctypes.c_ulonglong), ('used', ctypes.c_ulonglong)]


def query(nvml):
    if nvml.nvmlInit_v2() != 0:
        return None
    try:
        h = ctypes.c_void_p()
        if nvml.nvmlDeviceGetHandleByIndex_v2(0, ctypes.byref(h)) != 0:
            return None
        temp, power, util, mem = ctypes.c_uint(), ctypes.c_uint(), Util(), Mem()
        nvml.nvmlDeviceGetTemperature(h, 0, ctypes.byref(temp))  # 0 = GPU core sensor
        if nvml.nvmlDeviceGetPowerUsage(h, ctypes.byref(power)) != 0:
            power.value = 0
        nvml.nvmlDeviceGetUtilizationRates(h, ctypes.byref(util))
        nvml.nvmlDeviceGetMemoryInfo(h, ctypes.byref(mem))
        return temp.value, util.gpu, power.value / 1000, mem.used >> 20, mem.total >> 20
    finally:
        nvml.nvmlShutdown()  # never hold the device open between reads


def write(line):
    tmp = OUT + '.tmp'
    with open(tmp, 'w') as f:
        f.write(line + '\n')
    os.replace(tmp, OUT)


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def main():
    dev = find_gpu()
    if not dev:
        return
    try:
        nvml = ctypes.CDLL('libnvidia-ml.so.1')
    except OSError:
        return
    idle = 0
    while WATCH is None or alive(WATCH):
        now = int(time.time())
        if read(dev + '/power/runtime_status') == 'active':
            q = query(nvml)
            if q:
                write('%d %d %d %.1f %d %d' % ((now,) + q))
                idle = idle + 1 if q[1] == 0 else 0
        else:
            write('%d asleep' % now)
            idle = 0
        time.sleep(SLOW if idle >= IDLE_READS else FAST)


if __name__ == '__main__':
    main()
