#!/usr/bin/env python3
"""Builds iTalk's on-device voice references.

Each voice is a few short reference recordings (one per style) generated with Qwen3-TTS CustomVoice (Apache-2.0) on this Mac and
encoded to MOSS-TTS-Nano codec codes. The phone never needs the encoder: a voice is just a small JSON of codes.

  make_voices.py <workdir>   → <workdir>/wav/<voice>-<style>.wav and <workdir>/json/<voice>-<style>.json
"""
import os, subprocess, sys

work = sys.argv[1]
SPEECH = os.environ.get("SPEECH", "/private/tmp/claude-501/-Users-almurat-Documents-ChatGPT-italk/dcfc7f81-115f-4776-a864-4abd1636dda5/scratchpad/speech-swift/.build/release/speech")
HERE = os.path.dirname(os.path.abspath(__file__))
BENCH = os.environ.get("BENCH", os.path.join(HERE, "..", "neural-bench", ".build", "release", "neural-bench"))
MOSS = os.environ.get("MOSS", os.path.expanduser("~/Library/Caches/qwen3-speech/models/aufklarer/MOSS-TTS-Nano-100M-CoreML"))

VOICES = [("xiaoqing", "vivian"), ("xiaoya", "serena"), ("laofu", "uncle_fu"), ("dylan", "dylan")]
STYLES = {
    "neutral": ("今天天气真不错，我们可以慢慢聊聊最近发生的事情，有什么想法都可以告诉我。", "Speak naturally."),
    "cheerful": ("太好了，这真是个好消息！我们今晚一起去庆祝一下吧，我已经等不及了。", "用开心、活泼、充满笑意的语气说话。"),
    "calm": ("不用着急，慢慢来。先深呼吸一下，我们一步一步把事情理清楚，一切都会好起来的。", "用温柔、平静、舒缓的语气说话。"),
}
os.makedirs(os.path.join(work, "wav"), exist_ok=True)
os.makedirs(os.path.join(work, "json"), exist_ok=True)
for vid, speaker in VOICES:
    for style, (text, instruct) in STYLES.items():
        wav = os.path.join(work, "wav", f"{vid}-{style}.wav")
        js = os.path.join(work, "json", f"{vid}-{style}.json")
        if not os.path.exists(wav):
            subprocess.run([SPEECH, "speak", "--engine", "qwen3", "--model", "customVoice", "--speaker", speaker, "--instruct", instruct, text, "-o", wav],
                           capture_output=True, text=True, check=True)
        if not os.path.exists(js):
            subprocess.run([BENCH, "encode", MOSS, wav, js, vid], capture_output=True, text=True, check=True)
        print(vid, style, "ok", flush=True)
