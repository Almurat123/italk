#!/usr/bin/env python3
"""Objective checks for TTS samples (no listening): speed, prosody statistics, pauses, ASR round trip.

  analyze.py <eval-dir> [--asr-cmd "<command that prints path<TAB>transcript for each wav given as arguments>"]

Prosody statistics are proxies, not a MOS: very low pitch variation and flat energy correlate with "robotic" delivery, long
silences with stalls. They rank candidates for human listening; they do not replace it.
"""
import sys, os, csv, json, subprocess, shlex, math
import numpy as np, soundfile as sf
from scipy.signal import resample_poly

SENT = {}
here = os.path.dirname(os.path.abspath(__file__))
for line in open(os.path.join(here, "sentences.tsv"), encoding="utf-8"):
    if "\t" in line:
        k, v = line.rstrip("\n").split("\t", 1); SENT[k] = v

def load16k(path):
    x, sr = sf.read(path, always_2d=True)
    x = x.mean(axis=1).astype(np.float64)
    if sr != 16000:
        g = math.gcd(sr, 16000); x = resample_poly(x, 16000 // g, sr // g)
    return x

def f0_track(x, sr=16000, fmin=70, fmax=420):
    win, hop = int(0.040 * sr), int(0.010 * sr)
    out = []
    for s in range(0, len(x) - win, hop):
        seg = x[s:s + win] * np.hanning(win)
        e = float(np.sum(seg ** 2))
        if e < 1e-4 * win: out.append(0.0); continue
        ac = np.correlate(seg, seg, mode="full")[win - 1:]
        lo, hi = int(sr / fmax), int(sr / fmin)
        if hi >= len(ac): out.append(0.0); continue
        lag = lo + int(np.argmax(ac[lo:hi]))
        out.append(sr / lag if ac[lag] / (ac[0] + 1e-9) > 0.35 else 0.0)
    return np.array(out)

def prosody(x):
    f0 = f0_track(x)
    v = f0[f0 > 0]
    semis = 12 * np.log2(v / np.median(v)) if len(v) > 20 else np.array([0.0])
    frame = int(0.020 * 16000)
    rms = np.array([math.sqrt(np.mean(x[i:i + frame] ** 2) + 1e-12) for i in range(0, len(x) - frame, frame)])
    db = 20 * np.log10(rms + 1e-9)
    thr = max(db.max() - 38, -75)
    voiced = db > thr
    # internal pauses: silence runs >= 180 ms between voiced regions
    idx = np.where(voiced)[0]
    pauses = []
    if len(idx) > 2:
        run = 0
        for i in range(idx[0], idx[-1] + 1):
            if not voiced[i]: run += 1
            else:
                if run * 0.02 >= 0.18: pauses.append(run * 0.02)
                run = 0
    dur = len(x) / 16000
    return {
        "f0_median_hz": float(np.median(v)) if len(v) else 0.0,
        "f0_std_semitones": float(np.std(semis)),
        "f0_range_semitones": float(np.percentile(semis, 95) - np.percentile(semis, 5)) if len(v) > 20 else 0.0,
        "energy_std_db": float(np.std(db[voiced])) if voiced.any() else 0.0,
        "voiced_fraction": float(voiced.mean()),
        "pauses": len(pauses), "pause_total_s": float(sum(pauses)), "longest_pause_s": float(max(pauses)) if pauses else 0.0,
        "clipping": float(np.mean(np.abs(x) > 0.99)),
        "seconds": dur,
    }

def edit_distance(a, b):
    dp = list(range(len(b) + 1))
    for i in range(1, len(a) + 1):
        prev, dp[0] = dp[0], i
        for j in range(1, len(b) + 1):
            cur = dp[j]
            dp[j] = min(dp[j] + 1, dp[j - 1] + 1, prev + (a[i - 1] != b[j - 1]))
            prev = cur
    return dp[-1]

CN_DIGIT = {"零": 0, "〇": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9}
CN_UNIT = {"十": 10, "百": 100, "千": 1000}

def cn_number(run):
    """'二十五' -> 25, '一万两千三百四十五' -> 12345, '三十' -> 30. Returns None when the run is not a plain number."""
    total, section, digit, seen = 0, 0, 0, False
    for ch in run:
        if ch in CN_DIGIT: digit = CN_DIGIT[ch]; seen = True
        elif ch in CN_UNIT:
            section += (digit or 1) * CN_UNIT[ch]; digit = 0; seen = True
        elif ch == "万": total += (section + digit or 1) * 10000; section = digit = 0; seen = True
        else: return None
    return total + section + digit if seen else None

def norm(s):
    """Letters, digits and Chinese characters only; Chinese numerals become Arabic so '二十五度' equals '25度'."""
    import re
    s = s.lower().replace("百分之", "").replace("%", "").replace("％", "")
    s = re.sub(r"[零〇一二三四五六七八九十百千万两]+", lambda m: str(cn_number(m.group(0)) if cn_number(m.group(0)) is not None else m.group(0)), s)
    keep = []
    for ch in s:
        if ch.isalnum() or '一' <= ch <= '鿿': keep.append(ch)
    return "".join(keep)

def main():
    root = sys.argv[1]
    asr = None
    if "--asr-cmd" in sys.argv: asr = sys.argv[sys.argv.index("--asr-cmd") + 1]
    rows = []
    transcripts = {}
    if asr:
        wavs = []
        for label in sorted(os.listdir(root)):
            d = os.path.join(root, label)
            if os.path.isfile(os.path.join(d, "times.tsv")):
                wavs += [os.path.join(d, sid + ".wav") for sid in SENT if os.path.isfile(os.path.join(d, sid + ".wav"))]
        out = subprocess.run(shlex.split(asr) + wavs, capture_output=True, text=True).stdout
        for line in out.splitlines():
            if "\t" in line:
                path, text = line.split("\t", 1); transcripts[path] = text
    for label in sorted(os.listdir(root)):
        d = os.path.join(root, label)
        tsv = os.path.join(d, "times.tsv")
        if not os.path.isfile(tsv): continue
        times = {}
        for r in csv.reader(open(tsv), delimiter="\t"):
            if len(r) >= 5: times[r[1]] = (float(r[2]), float(r[3]), r[4])
        for sid, text in SENT.items():
            wav = os.path.join(d, sid + ".wav")
            if not os.path.isfile(wav) or sid not in times or times[sid][2] != "0": continue
            x = load16k(wav)
            p = prosody(x)
            wall, adur, _ = times[sid]
            p.update(engine=label, id=sid, wall_s=wall, audio_s=adur, rtf_incl_load=wall / max(adur, 1e-6), chars_per_s=len(norm(text)) / max(p["seconds"], 1e-6))
            if asr:
                heard = transcripts.get(wav, "")
                hyp, ref = norm(heard), norm(text)
                p["asr"] = heard
                p["cer"] = edit_distance(ref, hyp) / max(len(ref), 1)
            rows.append(p)
    json.dump(rows, open(os.path.join(root, "analysis.json"), "w"), ensure_ascii=False, indent=1)
    # summary by engine
    engines = sorted({r["engine"] for r in rows})
    print(f"{'engine':26s} n  f0Std(st) f0Rng(st) enStd(dB) pauses/s  chars/s  rtf(incl.load)" + ("   CER" if asr else ""))
    for e in engines:
        rs = [r for r in rows if r["engine"] == e]
        m = lambda k: float(np.mean([r[k] for r in rs]))
        pps = float(np.mean([r["pauses"] / r["seconds"] for r in rs]))
        print(f"{e:26s} {len(rs):2d} {m('f0_std_semitones'):8.2f} {m('f0_range_semitones'):9.2f} {m('energy_std_db'):9.2f} {pps:9.2f} {m('chars_per_s'):8.2f} {m('rtf_incl_load'):9.2f}" + (f"  {m('cer'):.3f}" if asr else ""))

if __name__ == "__main__":
    main()
