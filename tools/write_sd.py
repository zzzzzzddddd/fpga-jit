#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
write_sd.py — 把 sd_image.img 里的素材段【裸扇区】写进 TF 卡

============================================================================
【为什么不用 dd】
============================================================================
Git Bash 里访问物理盘的写法是 `//./PhysicalDrive2`，MSYS 的路径转换经常
把它改坏；而且盘号写错一位就是清掉系统盘，没有回读校验的话你根本不知道
写没写对。这个脚本做三件事：
  1) --list 打印所有物理盘的 盘号/型号/大小/总线，让你能一眼认出哪张是卡
  2) 写之前核对目标盘够不够大，并把它将要覆盖的扇区范围原样打印出来
  3) 写完之后【整段回读比对】，不一致就明确报错

============================================================================
【为什么不用 python 的 os.open / os.write】
============================================================================
2026-09-30 实测踩过：用 `os.open(r"\\\\.\\PhysicalDrive1", os.O_RDWR|os.O_BINARY)`
打得开、`os.lseek` 也成功，但第一个 `os.write` 就抛
    OSError: [Errno 9] Bad file descriptor
—— CRT 的 fd 对物理盘句柄不认（`_wopen` 返回的 fd 后续 `_write` 失败）。
所以这里【完全绕开 CRT】，直接用 kernel32 的
    CreateFileW / SetFilePointerEx / WriteFile / ReadFile / FlushFileBuffers
这类句柄本来就不该走 CRT。报错也从 GetLastError() 拿真实的 Win32 错误码，
比 errno 好定位得多。

============================================================================
【只写素材段，不动卡的前 8 MiB】
============================================================================
不写整个 28 MiB 镜像，只写 [16000, 57344) 这一段扇区 —— 也就是 RTL 真正
会去读的范围（图 16000+2048k，音频 32768+4096k）。
卡的前 8 MiB（含分区表和 FAT）原样不动，所以写错了重跑一次就行。

============================================================================
用法
============================================================================
    python tools/write_sd.py --list
    python tools/write_sd.py --drive 2            # 只看计划，不写
    python tools/write_sd.py --drive 2 --yes      # 真写

★ 必须用【管理员】权限的命令行 ★ 否则 CreateFileW 会返回 5 (拒绝访问)。
  Win+X -> "终端(管理员)" / "Windows PowerShell(管理员)"，然后 cd 到工程目录。

★ 盘号一定要对着 --list 的输出核对 ★ 这是本脚本唯一无法替你兜住的地方。
"""

import argparse
import ctypes
import os
import subprocess
import sys
from ctypes import wintypes

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except AttributeError:
    pass

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
IMG = os.path.join(ROOT, "sd_image.img")

SECTOR = 512
# 必须与 tools/layout_sd.py 的布局常量一致
IMG_BASE_SEC, IMG_STRIDE, N_IMG = 16000, 2048, 6
AUDIO_BASE_SEC, FRAG_STRIDE, N_AUD = 32768, 4096, 6
TOTAL_SEC = AUDIO_BASE_SEC + (N_AUD - 1) * FRAG_STRIDE + FRAG_STRIDE   # 57344

WRITE_FIRST_SEC = IMG_BASE_SEC                    # 16000
WRITE_BYTES = (TOTAL_SEC - WRITE_FIRST_SEC) * SECTOR
CHUNK = 1 << 20                                   # 1 MiB = 4096 扇区，天然对齐


# ===========================================================================
# Win32 裸盘读写
# ===========================================================================
GENERIC_READ      = 0x80000000
GENERIC_WRITE     = 0x40000000
FILE_SHARE_READ   = 0x00000001
FILE_SHARE_WRITE  = 0x00000002
OPEN_EXISTING     = 3
INVALID_HANDLE    = ctypes.c_void_p(-1).value

k32 = ctypes.WinDLL("kernel32", use_last_error=True)

k32.CreateFileW.restype = wintypes.HANDLE
k32.CreateFileW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD,
                            wintypes.LPVOID, wintypes.DWORD, wintypes.DWORD,
                            wintypes.HANDLE]
k32.SetFilePointerEx.restype = wintypes.BOOL
k32.SetFilePointerEx.argtypes = [wintypes.HANDLE, ctypes.c_longlong,
                                 ctypes.POINTER(ctypes.c_longlong), wintypes.DWORD]
k32.WriteFile.restype = wintypes.BOOL
k32.WriteFile.argtypes = [wintypes.HANDLE, wintypes.LPCVOID, wintypes.DWORD,
                          ctypes.POINTER(wintypes.DWORD), wintypes.LPVOID]
k32.ReadFile.restype = wintypes.BOOL
k32.ReadFile.argtypes = [wintypes.HANDLE, wintypes.LPVOID, wintypes.DWORD,
                         ctypes.POINTER(wintypes.DWORD), wintypes.LPVOID]
k32.FlushFileBuffers.restype = wintypes.BOOL
k32.FlushFileBuffers.argtypes = [wintypes.HANDLE]
k32.CloseHandle.restype = wintypes.BOOL
k32.CloseHandle.argtypes = [wintypes.HANDLE]
k32.DeviceIoControl.restype = wintypes.BOOL
k32.DeviceIoControl.argtypes = [wintypes.HANDLE, wintypes.DWORD, wintypes.LPVOID,
                                wintypes.DWORD, wintypes.LPVOID, wintypes.DWORD,
                                ctypes.POINTER(wintypes.DWORD), wintypes.LPVOID]

IOCTL_STORAGE_GET_DEVICE_NUMBER = 0x002D1080
FSCTL_LOCK_VOLUME               = 0x00090018
FSCTL_DISMOUNT_VOLUME           = 0x00090020


class STORAGE_DEVICE_NUMBER(ctypes.Structure):
    _fields_ = [("DeviceType",     wintypes.DWORD),
                ("DeviceNumber",   wintypes.DWORD),
                ("PartitionNumber", wintypes.DWORD)]


def lock_volumes_on_disk(disk_number):
    """
    把 disk_number 这块盘上所有已挂载的卷 lock + dismount。

    ★ 为什么必须做这一步 ★
      2026-09-30 实测：CreateFileW 以 GENERIC_READ|GENERIC_WRITE 打开
      \\\\.\\PhysicalDrive1 【成功】，SetFilePointerEx 也成功，但第一个
      WriteFile 就返回 ERROR_ACCESS_DENIED(5)。
      原因：只要盘上的卷还挂着文件系统，Windows 就拒绝往这块物理盘裸写。
      必须先对每个卷发 FSCTL_LOCK_VOLUME + FSCTL_DISMOUNT_VOLUME ——
      Win32DiskImager / balenaEtcher 都是这么做的。

    返回 (保持打开的卷句柄列表, 失败原因列表)。
    ★ 句柄必须在【写完之后】才关闭 —— 关掉句柄，锁就释放了。★
    """
    kept, failed = [], []
    for letter in "ABCDEFGHIJKLMNOPQRSTUVWXYZ":
        path = "\\\\.\\%s:" % letter
        h = k32.CreateFileW(path, GENERIC_READ | GENERIC_WRITE,
                            FILE_SHARE_READ | FILE_SHARE_WRITE,
                            None, OPEN_EXISTING, 0, None)
        if h == INVALID_HANDLE or h is None:
            continue

        sdn = STORAGE_DEVICE_NUMBER()
        ret = wintypes.DWORD(0)
        ok = k32.DeviceIoControl(h, IOCTL_STORAGE_GET_DEVICE_NUMBER, None, 0,
                                 ctypes.byref(sdn), ctypes.sizeof(sdn),
                                 ctypes.byref(ret), None)
        if not ok or sdn.DeviceNumber != disk_number:
            k32.CloseHandle(h)          # 这块盘不是我们要的，别留句柄
            continue

        # 锁卷。注意：卷已经被锁住时也会返回 5，那种情况反而说明可以继续。
        lock_ok  = k32.DeviceIoControl(h, FSCTL_LOCK_VOLUME, None, 0, None, 0,
                                       ctypes.byref(ret), None)
        lock_err = ctypes.get_last_error()
        # 卸载卷，让文件系统松手（不关句柄，锁才留得住）
        k32.DeviceIoControl(h, FSCTL_DISMOUNT_VOLUME, None, 0, None, 0,
                            ctypes.byref(ret), None)

        if lock_ok or lock_err == 5:
            kept.append(h)
            print("       已锁定并卸载 %s（%s）"
                  % (path, "锁成功" if lock_ok else "已被锁住，视作可用"))
        else:
            failed.append((path, lock_err))
            k32.CloseHandle(h)

    return kept, failed

# GetLastError 的中文说明（只列本脚本真会碰到的）
ERR_TEXT = {
    2:   "系统找不到指定的盘 —— 盘号不存在",
    5:   "拒绝访问 —— 多半是没有用【管理员】权限运行，或卡正被别的程序占着",
    21:  "设备未就绪 —— 读卡器里没卡，或卡没插稳",
    23:  "数据错误(CRC) —— 卡本身有问题",
    87:  "参数错误(ERROR_INVALID_PARAMETER) —— 写入的偏移/长度不是 512 的倍数",
    1224: "介质受写保护 —— 卡上的写保护开关打开了",
}


class DiskError(Exception):
    pass


def _err(where, code):
    return DiskError("%s 失败，Win32 错误 %d：%s"
                     % (where, code, ERR_TEXT.get(code, "（未收录的错误码）")))


class RawDisk:
    """按字节偏移读写物理盘。所有 offset / length 必须是 SECTOR 的倍数。"""

    def __init__(self, number):
        self.path = "\\\\.\\PhysicalDrive%d" % number
        self.h = k32.CreateFileW(self.path,
                                 GENERIC_READ | GENERIC_WRITE,
                                 FILE_SHARE_READ | FILE_SHARE_WRITE,
                                 None, OPEN_EXISTING, 0, None)
        if self.h == INVALID_HANDLE or self.h is None:
            raise _err("CreateFileW(%s)" % self.path,
                       ctypes.get_last_error())

    def seek(self, offset):
        newpos = ctypes.c_longlong(0)
        if not k32.SetFilePointerEx(self.h, ctypes.c_longlong(offset),
                                    ctypes.byref(newpos), 0):
            raise _err("SetFilePointerEx(%d)" % offset, ctypes.get_last_error())

    def write(self, data):
        n = len(data)
        assert n % SECTOR == 0, "写入长度必须是 %d 的倍数" % SECTOR
        buf = ctypes.create_string_buffer(data, n)
        done = 0
        while done < n:
            written = wintypes.DWORD(0)
            if not k32.WriteFile(self.h,
                                 ctypes.cast(ctypes.byref(buf, done), wintypes.LPCVOID),
                                 n - done, ctypes.byref(written), None):
                raise _err("WriteFile(偏移 %d)" % done, ctypes.get_last_error())
            if written.value == 0:
                raise DiskError("WriteFile 写了 0 字节但没有报错 —— 卡可能已经拔了")
            done += written.value

    def read(self, n):
        buf = ctypes.create_string_buffer(n)
        done = 0
        while done < n:
            got = wintypes.DWORD(0)
            if not k32.ReadFile(self.h, ctypes.cast(ctypes.byref(buf, done), wintypes.LPVOID),
                                n - done, ctypes.byref(got), None):
                raise _err("ReadFile(偏移 %d)" % done, ctypes.get_last_error())
            if got.value == 0:
                raise DiskError("ReadFile 读到 0 字节 —— 卡可能已经拔了")
            done += got.value
        return buf.raw[:n]

    def flush(self):
        if not k32.FlushFileBuffers(self.h):
            raise _err("FlushFileBuffers", ctypes.get_last_error())

    def close(self):
        if self.h:
            k32.CloseHandle(self.h)
            self.h = None


# ===========================================================================
def list_disks():
    """借 PowerShell 的 Get-Disk 列盘。比 wmic 可靠（wmic 在新版 Windows 已移除）。"""
    ps = ("Get-Disk | Sort-Object Number | "
          "Select-Object Number,FriendlyName,@{n='GB';e={[math]::Round($_.Size/1GB,1)}},"
          "BusType,PartitionStyle | ConvertTo-Csv -NoTypeInformation")
    try:
        out = subprocess.check_output(["powershell", "-NoProfile", "-Command", ps],
                                      stderr=subprocess.STDOUT, timeout=30)
    except (OSError, subprocess.SubprocessError) as e:
        print("!! 调 PowerShell 列盘失败：%s" % e)
        print("   手动查：Win+X -> 磁盘管理，或 PowerShell 里 `Get-Disk`")
        return False

    print("物理盘列表（认准型号和大小，SD 卡通常 BusType=USB/SD）：")
    print()
    for i, line in enumerate(out.decode("utf-8", "replace").strip().splitlines()):
        print("  %s" % line)
        if i == 0:
            print("  " + "-" * 60)
    print()
    print("  上面表头的 Number 就是 --drive 要填的盘号。")
    return True


def disk_size_bytes(n):
    try:
        out = subprocess.check_output(
            ["powershell", "-NoProfile", "-Command", "(Get-Disk -Number %d).Size" % n],
            stderr=subprocess.STDOUT, timeout=30)
    except (OSError, subprocess.SubprocessError):
        return None
    s = out.decode("utf-8", "replace").strip()
    return int(s) if s.isdigit() else None


# ===========================================================================
def main():
    ap = argparse.ArgumentParser(
        description="把 sd_image.img 的素材段裸写进 TF 卡（带回读校验）")
    ap.add_argument("--list", action="store_true", help="只列出物理盘，不写任何东西")
    ap.add_argument("--drive", type=int, default=None,
                    help=r"目标盘号 N，对应 \\.\PhysicalDriveN")
    ap.add_argument("--yes", action="store_true",
                    help="真的开始写。不加这个参数只打印计划")
    args = ap.parse_args()

    if args.list or args.drive is None:
        if not list_disks():
            return 1
        if args.drive is None:
            print()
            print("下一步：python tools/write_sd.py --drive <N>   （先看计划，不写）")
        return 0

    if not os.path.isfile(IMG):
        print("!! 找不到 %s" % IMG)
        print("   先生成：python tools/gen_sd_assets.py 然后 python tools/layout_sd.py")
        return 1

    img_size = os.path.getsize(IMG)
    need = TOTAL_SEC * SECTOR
    if img_size < need:
        print("!! %s 只有 %d 字节，至少需要 %d 字节（%d 扇区）"
              % (IMG, img_size, need, TOTAL_SEC))
        return 1

    print("镜像      : %s  (%d 字节)" % (IMG, img_size))
    print("目标      : \\\\.\\PhysicalDrive%d" % args.drive)
    print()
    print("将写入    : 扇区 [%d, %d)  共 %d 扇区 = %d 字节 (%.1f MiB)"
          % (WRITE_FIRST_SEC, TOTAL_SEC, TOTAL_SEC - WRITE_FIRST_SEC,
             WRITE_BYTES, WRITE_BYTES / 1048576.0))
    print("            img0..5.bmp @ %d + %d*k   (k=0..%d)"
          % (IMG_BASE_SEC, IMG_STRIDE, N_IMG - 1))
    print("            aud0..5.pcm @ %d + %d*k   (k=0..%d)"
          % (AUDIO_BASE_SEC, FRAG_STRIDE, N_AUD - 1))
    print()
    print("★ 卡的前 8 MiB（扇区 0..%d）原样不动 ★" % (WRITE_FIRST_SEC - 1))

    sz = disk_size_bytes(args.drive)
    if sz is None:
        print("目标盘大小: 读不到，请你【自己核对盘号】")
    else:
        print("目标盘大小: %.1f GiB  (%d 字节)" % (sz / 1073741824.0, sz))
        if sz < need:
            print()
            print("!! 【停下】这块盘装不下 %d 字节的素材段。" % need)
            return 1

    if not args.yes:
        print()
        print("-- 当前是【只看计划】模式，没有写任何东西 --")
        print("   确认盘号没错，再加上 --yes 真写：")
        print("   python tools/write_sd.py --drive %d --yes" % args.drive)
        return 0

    # ---- 打开物理盘 ----
    try:
        disk = RawDisk(args.drive)
    except DiskError as e:
        print()
        print("!! %s" % e)
        if "拒绝访问" in str(e):
            print("   确认这个窗口是【管理员】开的（标题栏会写「管理员」）。")
        return 1

    try:
        src = open(IMG, "rb")
    except OSError as e:
        disk.close()
        print("!! 打不开镜像：%s" % e)
        return 1

    # ---- 锁定并卸载这块盘上的卷 ----
    #   不做的下场就是 WriteFile 报 ERROR_ACCESS_DENIED(5)，见上面函数的注释。
    print()
    print("锁定盘上的卷 ...")
    vols, lock_failed = lock_volumes_on_disk(args.drive)
    if not vols:
        print("       ！没锁到任何卷。")
        print("         要么这块盘本来就没有挂载的卷（那可以继续），")
        print("         要么每个卷都被别的程序占着（关掉所有资源管理器窗口、")
        print("         关掉杀毒软件的实时监控，再重试）。")
    for path, code in lock_failed:
        print("       ！%s 锁卷失败，Win32 错误 %d：%s"
              % (path, code, ERR_TEXT.get(code, "?")))

    try:
        base = WRITE_FIRST_SEC * SECTOR
        src.seek(base)
        disk.seek(base)

        # ---- 写 ----
        print()
        print("写入中 ...")
        done = 0
        while done < WRITE_BYTES:
            n = min(CHUNK, WRITE_BYTES - done)
            buf = src.read(n)
            if len(buf) != n:
                raise IOError("镜像读到一半就没了（偏移 %d）" % (done,))
            disk.write(buf)
            done += n
            sys.stdout.write("\r       写入  %5.1f%%  (%d / %d 字节)"
                             % (100.0 * done / WRITE_BYTES, done, WRITE_BYTES))
            sys.stdout.flush()
        disk.flush()
        print()

        # ---- 回读校验 ----
        # ★ 这一步是"写没写对"唯一可靠的证据。少了它，写错盘号也一样静默。
        print("回读校验中 ...")
        src.seek(base)
        disk.seek(base)
        vdone = 0
        while vdone < WRITE_BYTES:
            n = min(CHUNK, WRITE_BYTES - vdone)
            a = src.read(n)
            b = disk.read(n)
            if a != b:
                bad = next(i for i in range(min(len(a), len(b))) if a[i] != b[i])
                print()
                print("!! 【校验失败】扇区 %d、段内偏移 %d 处不一致"
                      % (WRITE_FIRST_SEC + (vdone + bad) // SECTOR, bad))
                return 1
            vdone += n
            sys.stdout.write("\r       校验  %5.1f%%" % (100.0 * vdone / WRITE_BYTES))
            sys.stdout.flush()
        print()
        print()
        print("完成：%d 字节写入并回读校验一致。" % WRITE_BYTES)
        print()
        print("下一步：拔卡 -> 插回板子 -> 上电。预期：")
        print("  数码管 D1 一闪而过（1->2->3->4->1），底图 = 卡图 0（青色 P0），")
        print("  界面 = 三表总览。")
        print()
        print("  若 D1 停在 2：卡通，但扇区 16000 不是合法 BMP。")
        print("  若 D1 一直是 1 或 0：SD 初始化没过（卡型/接触）。")
        print()
        print("  注意：卡现在是【裸卡】，文件管理器打开会提示格式化 —— 别格。")
        return 0
    except (DiskError, OSError) as e:
        print()
        print("!! 写/校验过程中出错：%s" % e)
        return 1
    finally:
        src.close()
        disk.close()
        # ★ 卷锁必须在【写和校验都做完之后】才放开。
        #   提前关句柄 = 提前解锁，后面的写就又会被拒。★
        for h in vols:
            k32.CloseHandle(h)


if __name__ == "__main__":
    sys.exit(main())
