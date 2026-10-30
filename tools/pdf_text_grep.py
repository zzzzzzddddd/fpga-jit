# -*- coding: utf-8 -*-
"""
pdf_text_grep.py —— 不装 poppler 也能从 PDF 里抠文本。

原理：PDF 里文字通常在 `stream ... endstream` 块内，且多是 FlateDecode(=zlib)。
     把每个 stream 解压出来，再从里面的 Tj / TJ 操作符里抽括号中的字符串。
     对纯文字型 PDF（手册）够用；扫描件/嵌入式 CID 字体会抠不出来 ——
     那就换别的办法，不要在这上面耗。

用法：python tools/pdf_text_grep.py <pdf> <关键词...>
      关键词给多个就是"或"，打印命中的行和它的上下文。
"""
import re
import sys
import zlib


def streams(data):
    for m in re.finditer(rb"stream\r?\n", data):
        start = m.end()
        end = data.find(b"endstream", start)
        if end < 0:
            continue
        raw = data[start:end]
        for cand in (raw, raw.rstrip(b"\r\n")):
            try:
                yield zlib.decompress(cand)
                break
            except Exception:
                continue


def text_of(blob):
    """把一段解压后的 PDF 内容流里的可见文本抽出来。"""
    out = []
    # 括号字符串：(...)  里面 \\( \\) \\\\ 是转义
    for m in re.finditer(rb"\((?:[^()\\]|\\.)*\)", blob):
        s = m.group(0)[1:-1]
        s = s.replace(b"\\(", b"(").replace(b"\\)", b")").replace(b"\\\\", b"\\")
        try:
            out.append(s.decode("latin-1"))
        except Exception:
            pass
    return "".join(out)


def main():
    path = sys.argv[1]
    keys = [k.lower() for k in sys.argv[2:]]
    data = open(path, "rb").read()
    total = 0
    for blob in streams(data):
        if not any(op in blob for op in (b"Tj", b"TJ")):
            continue
        t = text_of(blob)
        if len(t) < 8:
            continue
        if not keys or any(k in t.lower() for k in keys):
            print(t)
            print("-" * 70)
            total += 1
    print(f"### 命中 {total} 段（关键词：{keys if keys else '全部'}）")


if __name__ == "__main__":
    main()
