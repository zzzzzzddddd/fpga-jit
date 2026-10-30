#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
audio_rc_snr.py -- 数字侧全对但喇叭里只有电流声？量一下【模拟重建】够不够。

【为什么要它】
  一阶 sigma-delta 把量化噪声整形成 f^2 推到高频，靠的完全是后面的
  模拟低通把它滤掉。本工程的 RC 是 1kΩ + 10nF（第二十二版；原来那组
  100Ω + 0.1µF 的 τ 完全相同，只是引脚电流大 10 倍）：
        fc = 1/(2*pi*1k*10n) = 15.9kHz
  这是【一阶】低通，只有 20dB/decade。如果整形后的噪声压不住，
  喇叭里就会是一片"电流声"，语音被埋在下面 —— 听起来正好就是
  "有电流声、没有文字播报"。

【两个读数要分清】
  * 宽带 SNR（默认模式看这个）：RC 自己的相移也算进"失真"，所以
    **测试音模式下这个数会偏低**，不要用它下结论。
  * 单频点 THD+N（--tone 模式看这个）：才是测试音的真正判据。
  * THD+N 随记录长度**变好**（10ms 34.6 / 40ms 40.5 / 80ms 43.5 dB）：
    一阶调制器的近直流分量以 1/(pi*k) 的旁瓣漏进 1kHz 那个 bin，
    k = fc*N/fs 随 N 变大 ⇒ 漏得少。所以别用短记录下结论。

  这个脚本把 audio_pwm.v 的调制器【逐拍照抄】，再把 1bit 输出过一遍
  RC（离散一阶 IIR），然后把结果低通到 8kHz 和理想值比，算出音频带内 SNR。

【判据】
  SNR 好（>= 30dB）→ 重建没问题，问题在 RC 之后的功放/接线。
  SNR 差（< 15dB） → 一定是模拟低通不够，要么加极点，要么换二阶调制器。

【用法】
  python tools/audio_rc_snr.py                      # 01.wav，默认 100Ω/0.1µF
  python tools/audio_rc_snr.py --ms 20 --r 1000 --c 1e-8
  python tools/audio_rc_snr.py --order 2            # 两极 RC（级联）
"""
import argparse
import os
import struct
import sys


def load_wav_samples(path, limit, skip):
    b = open(path, "rb").read()
    if b[0:4] != b"RIFF" or b[8:12] != b"WAVE":
        raise ValueError("不是 RIFF/WAVE")
    i = 12
    while i + 8 <= len(b):
        cid = b[i:i + 4]
        csz = struct.unpack("<I", b[i + 4:i + 8])[0]
        if cid == b"data":
            d = b[i + 8:i + 8 + csz]
            n = len(d) // 2
            a = min(skip, n)
            n = min(n - a, limit)
            return list(struct.unpack("<%dh" % n, d[2 * a:2 * (a + n)]))
        i += 8 + csz + (csz & 1)
    raise ValueError("没有 data 块")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--wav", default=os.path.join("sd_assets", "01.wav"))
    ap.add_argument("--ms", type=float, default=25.0)
    ap.add_argument("--skip", type=int, default=6000)
    ap.add_argument("--osr", type=int, default=6250)
    ap.add_argument("--fclk", type=float, default=100e6)
    ap.add_argument("--r", type=float, default=100.0, help="串联电阻(欧)")
    ap.add_argument("--c", type=float, default=1e-7, help="对地电容(法)")
    ap.add_argument("--order", type=int, default=1, help="RC 极点个数(1 或 2)")
    ap.add_argument("--vdd", type=float, default=3.3)
    ap.add_argument("--tone", type=float, default=0.0,
                    help=">0 时不用 WAV，改成一个正弦测试音（Hz）")
    ap.add_argument("--amp", type=float, default=0.875,
                    help="测试音幅度（相对满幅，默认 0.875）")
    a = ap.parse_args()

    if a.tone > 0:
        fs = a.fclk / a.osr
        nsamp = int(fs * a.ms / 1000.0)
        import math
        amp = a.amp * 32767.0
        x = [int(round(amp * math.sin(2 * math.pi * a.tone * i / fs)))
             for i in range(nsamp)]
        print("测试音 %.1f Hz, 幅度 %.3f 满幅, 采样率 %.1f kHz (OSR=%d)"
              % (a.tone, a.amp, fs / 1000.0, a.osr))
    else:
        nsamp = int(16000 * a.ms / 1000.0)
        x = load_wav_samples(a.wav, nsamp, a.skip)
        if not x:
            print("没读到样本")
            return 1

    tau = a.r * a.c
    fc = 1.0 / (2 * 3.141592653589793 * tau)
    if a.tone <= 0:
        print("WAV %s  %d 个样本（%.1f ms）" % (a.wav, len(x), len(x) / 16.0))
    print("RC = %.0fΩ + %.3gF  ⇒  tau = %.3g s, 单极点 fc = %.1f Hz, 阶数 %d"
          % (a.r, a.c, tau, fc, a.order))

    dt = 1.0 / a.fclk
    alpha = dt / tau
    if alpha > 1.0:
        alpha = 1.0

    # ---- 调制器（照抄 audio_pwm.v）----
    S18 = 1 << 17
    MASK = (1 << 18) - 1

    def wrap18(v):
        v &= MASK
        return v - (1 << 18) if v & S18 else v

    acc = 0
    pwm = 0
    v1 = a.vdd * 0.5
    v2 = a.vdd * 0.5
    ideal = []      # 理想：每个样本周期应有的平均电压
    got = []        # 实际：RC 之后的电压（取每个样本周期末）
    raw_mean = []   # 未滤波的 1bit 平均（参考）

    for s in x:
        osum = 0
        for _ in range(a.osr):
            fb = 32767 if pwm else -32768
            acc = wrap18(acc + s - fb)
            pwm = 1 if acc >= 0 else 0
            pin = a.vdd if pwm else 0.0
            v1 += (pin - v1) * alpha
            if a.order >= 2:
                v2 += (v1 - v2) * alpha
            osum += pin
        ideal.append(a.vdd * (s + 32768) / 65535.0)
        got.append(v2 if a.order >= 2 else v1)
        raw_mean.append(osum / a.osr)

    # ---- 低通到 8kHz（两级一阶 IIR），把两边都限带后再比 ----
    #   ★ 系数必须用【这一段自己的采样率】算，不能写死 16000 ★
    #     测试音模式下的采样率是 fclk/osr，跟 WAV 的 16kHz 不是一回事。
    fs_sig = (a.fclk / a.osr) if a.tone > 0 else 16000.0
    flp = 8000.0
    al = 1.0 - pow(2.718281828459045, -2 * 3.141592653589793 * flp / fs_sig)

    def lp(seq):
        y1 = y2 = seq[0]
        out = []
        for v in seq:
            y1 += (v - y1) * al
            y2 += (y1 - y2) * al
            out.append(y2)
        return out

    i_lp = lp(ideal)
    g_lp = lp(got)

    def rms(seq):
        return (sum(v * v for v in seq) / len(seq)) ** 0.5

    m_i = sum(i_lp) / len(i_lp)
    sig = rms([v - m_i for v in i_lp])
    err = [g - i for g, i in zip(g_lp, i_lp)]
    noi = rms(err)
    snr = 20 * 3.321928094887362 * (1e-9)  # placeholder, replaced below
    import math
    snr = 20 * math.log10(sig / noi) if noi > 0 else float("inf")

    print()
    print("音频带内(<=8kHz)  信号 RMS = %.4f V   失真/噪声 RMS = %.4f V" % (sig, noi))
    print("⇒ SNR = %.1f dB" % snr)
    print("（理想峰值幅度 %.4f V）" % ((max(ideal) - min(ideal)) / 2.0))
    print("（滤波后峰值幅度 %.4f V）" % ((max(got) - min(got)) / 2.0))

    if a.tone > 0:
        # ★ 上面那个"噪声"里有一大块是 RC 自己在 1kHz 上的相移（线性失真，
        #   不是噪声）。用单频点 DFT 把 1kHz 分量单独量出来，剩下的才是
        #   真正的失真/噪声（THD+N）。★
        import math
        N = len(g_lp)
        m = sum(g_lp) / N
        re = sum((v - m) * math.cos(2 * math.pi * a.tone * i / fs_sig)
                 for i, v in enumerate(g_lp))
        im = sum((v - m) * math.sin(2 * math.pi * a.tone * i / fs_sig)
                 for i, v in enumerate(g_lp))
        comp_peak = 2.0 * math.hypot(re, im) / N          # 1kHz 分量峰值
        comp_rms = comp_peak / math.sqrt(2.0)
        tot_rms = rms([v - m for v in g_lp])
        resid = math.sqrt(max(0.0, tot_rms * tot_rms - comp_rms * comp_rms))
        thdn = 20 * math.log10(comp_rms / resid) if resid > 0 else float("inf")
        print()
        print("★ 只认 1kHz 分量（THD+N）：")
        print("   1kHz 分量峰值 = %.4f V   （理想 %.4f V）"
              % (comp_peak, (max(ideal) - min(ideal)) / 2.0))
        print("   总 RMS = %.4f V   残余(THD+N) RMS = %.4f V"
              % (tot_rms, resid))
        print("   THD+N = %.1f dB   ⇒ %.2f %%"
              % (thdn, 100.0 / (10 ** (thdn / 20.0))))

    # ★ 判据必须【按模式分开】，否则会给出误导性的结论 ★
    #   测试音模式：上面那个宽带 SNR 里有一大块是 RC 在 1kHz 上的相移
    #   （线性失真，不是噪声），只有单频点 THD+N 才是对的判据。
    #   用宽带 SNR 去判会得到"勉强"，而实际 THD+N 有 40dB —— 自相矛盾。
    print()
    if a.tone > 0:
        if thdn >= 30:
            print("=> ✓ 模拟重建够用：1kHz 测试音的 THD+N = %.1f dB（%.2f%%）"
                  % (thdn, 100.0 / (10 ** (thdn / 20.0))))
            print("   ⇒ 数字侧 + RC 都没问题，去查功放/接线/供电共地。")
            return 0
        if thdn >= 20:
            print("=> ~ 勉强：THD+N = %.1f dB，测试音能听见但是脏的" % thdn)
            print("   （注意上面那个宽带 SNR 不要看，它把 RC 相移算成了噪声）")
            return 0
        print("=> ✗ 模拟重建不够：THD+N = %.1f dB，整形噪声压不住" % thdn)
        print("   修法二选一：① 增加 RC 极点（--order 2 或再串一节）")
        print("               ② 换二阶 sigma-delta（把噪声再往高频推）")
        return 1

    if snr >= 30:
        print("=> ✓ 模拟重建够用：语音在音频带内远高于残余噪声")
        print("   ⇒ 数字侧 + RC 都没问题，去查功放/接线/供电共地。")
        return 0
    if snr >= 15:
        print("=> ~ 勉强：噪声可闻但语音应当还听得见")
        return 0
    print("=> ✗ 模拟重建不够：整形噪声压不住，语音会被埋在一片电流声里")
    print("   修法二选一：① 增加 RC 极点（--order 2 或再串一节）")
    print("               ② 换二阶 sigma-delta（把噪声再往高频推）")
    return 1


if __name__ == "__main__":
    sys.exit(main())
