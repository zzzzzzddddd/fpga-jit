#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
revert_to_v31.py -- 把 src/hud 下三个源文件倒放回【第三十一版】的状态。

背景：本工程没有版本控制（不是 git 仓库），也没有任何 .bak。v31 之后我在
hud_data_gen.v / hud_panel.v / gen_hud_assets.py 上共做了 16 笔 Edit。
但本会话的 transcript（jsonl）里存着每一笔 Edit 的 old_string / new_string，
所以可以【倒序重放】把它们撤掉 —— 比重凭记忆重写可靠得多。

判据：
  * v31 的 bit 建于本地 2026-10-05 17:13:58（UTC 09:13:58）。
    本脚本用 UTC 2026-10-06T00:00:00Z 当分界线：**10-06 的编辑全撤**。
    （已核对：10-05 的最后一笔编辑是 09:02:32Z，早于 v31 构建，属 v31 及其以前。）
  * 每笔倒放都要求 new_string 在文件里**恰好出现 1 次**；出现 0 次或多次都报错
    —— 那说明有别的机制改过文件（比如用 PowerShell 写盘），倒放就不可信了。

用法：
    python tools/_selftest/revert_to_v31.py            # 干跑，写 *.reverted
    python tools/_selftest/revert_to_v31.py --write    # 真正落盘（先自己备份！）
"""

import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
TRANSCRIPT = os.path.join(
    r"C:\Users\1\.claude\projects\D--fpga-anlu-C-1",
    "f8f18fc3-7aca-4c67-a06a-f04ecac0a5c5.jsonl",
)

CUTOFF = "2026-10-06T00:00:00"          # 这之后（含）的编辑全撤

TARGETS = {
    "hud_data_gen.v":   os.path.join(ROOT, "src", "hud", "hud_data_gen.v"),
    "hud_panel.v":      os.path.join(ROOT, "src", "hud", "hud_panel.v"),
    "gen_hud_assets.py": os.path.join(ROOT, "tools", "gen_hud_assets.py"),
}


def collect():
    """扫 transcript，按时间顺序收集目标文件上的 Edit。"""
    ops = []
    with open(TRANSCRIPT, "r", encoding="utf-8") as f:
        for lineno, raw in enumerate(f, 1):
            if ".v" not in raw and ".py" not in raw:
                continue
            try:
                rec = json.loads(raw)
            except json.JSONDecodeError:
                continue
            ts = rec.get("timestamp", "")
            msg = rec.get("message") or {}
            content = msg.get("content")
            if not isinstance(content, list):
                continue
            for blk in content:
                if not isinstance(blk, dict):
                    continue
                if blk.get("type") != "tool_use":
                    continue
                if blk.get("name") != "Edit":
                    continue
                inp = blk.get("input") or {}
                fp = inp.get("file_path") or ""
                for key, path in TARGETS.items():
                    if os.path.normcase(fp) == os.path.normcase(path):
                        ops.append({
                            "lineno": lineno,
                            "ts": ts,
                            "file": key,
                            "old": inp.get("old_string", ""),
                            "new": inp.get("new_string", ""),
                        })
    return ops


def main():
    write = "--write" in sys.argv
    ops = collect()

    print("转录里找到的、本工程源文件上的 Edit 共 %d 笔" % len(ops))
    print("")

    # 只留分界线之后的，按时间倒序
    todo = [o for o in ops if o["ts"] >= CUTOFF]
    todo.sort(key=lambda o: (o["ts"], o["lineno"]), reverse=True)

    print("要倒放的（>= %s，共 %d 笔）：" % (CUTOFF, len(todo)))
    for o in todo:
        print("    %s  L%-6d %s" % (o["ts"], o["lineno"], o["file"]))
    print("")

    by_file = {}
    for o in todo:
        by_file.setdefault(o["file"], []).append(o)

    ok = True
    out = {}
    for key, path in TARGETS.items():
        if not os.path.exists(path):
            print("!! 找不到 %s" % path)
            ok = False
            continue
        text = open(path, "r", encoding="utf-8").read()
        orig_len = len(text)

        for o in by_file.get(key, []):
            n = text.count(o["new"])
            if n != 1:
                print("!! %s  L%d: new_string 在文件里出现 %d 次（要求 1 次），倒放不可信"
                      % (key, o["lineno"], n))
                ok = False
                continue
            text = text.replace(o["new"], o["old"], 1)
            print("   %-18s L%-6d 撤销 ok  (%d -> %d 字符)"
                  % (key, o["lineno"], len(o["new"]), len(o["old"])))

        out[key] = text
        print("   %-18s 长度 %d -> %d" % (key, orig_len, len(text)))

    if not ok:
        print("")
        print("=== 有一步不干净：**没有落盘**，先人工看 ===")
        return 1

    print("")
    if write:
        for key, path in TARGETS.items():
            with open(path, "w", encoding="utf-8", newline="") as f:
                f.write(out[key])
            print("已写回 %s" % path)
        print("=== 落盘完成。下一步：用 RED_MIN=88.0 重新生成 hud_rom_dial.v，")
        print("    然后 place seed 6 重综合，比对 bit 是否 == 4BEF9CB0... ===")
    else:
        for key, path in TARGETS.items():
            dst = path + ".reverted"
            with open(dst, "w", encoding="utf-8", newline="") as f:
                f.write(out[key])
            print("干跑：已写 %s" % dst)
        print("=== 干跑完成，核对后再加 --write ===")
    return 0


if __name__ == "__main__":
    sys.exit(main())
