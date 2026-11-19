#!/usr/bin/env python3
"""Counts REAL tokens of what the runner sends to a model, with that model's own tokenizer and chat template.

  python3 tools/context-probe/count_tokens.py <model dir> <dump.json> [<dump.json> …]

The dump files come from the probe tests (Packages/AppleSkills/Tests/AppleSkillsTests/ContextProbeTests.swift, ITALK_CONTEXT_DUMP=<folder>) or from the
app's -contextProbe run on a device. Needs `pip install tokenizers jinja2` (a throw-away venv is fine). Prints numbers only, never conversation content.
For every request: the rendered prompt length, the share of each part (system sections, tool schemas, each message), the output reservation, what is left
of the window, and the app's own character-based estimate next to the real count.
"""
import json, math, re, sys
from pathlib import Path
from jinja2.sandbox import ImmutableSandboxedEnvironment
from tokenizers import Tokenizer

def estimate(text: str) -> int:
    """Port of AgentRuntime.TokenEstimator.tokens(String): 1 per CJK character, 1 per 3.5 other characters, +4 per message."""
    cjk = other = 0
    for ch in text:
        v = ord(ch)
        if 0x3000 <= v <= 0x303F or 0x3400 <= v <= 0x4DBF or 0x4E00 <= v <= 0x9FFF or 0xF900 <= v <= 0xFAFF or 0xFF00 <= v <= 0xFFEF: cjk += 1
        else: other += 1
    return cjk + math.ceil(other / 3.5) + 4

def load(model_dir: Path):
    tok = Tokenizer.from_file(str(model_dir / "tokenizer.json"))
    env = ImmutableSandboxedEnvironment(trim_blocks=True, lstrip_blocks=True)
    env.filters["tojson"] = lambda x, ensure_ascii=False, indent=None, separators=None, sort_keys=False: json.dumps(x, ensure_ascii=ensure_ascii, indent=indent, separators=separators, sort_keys=sort_keys)
    def raise_exception(message): raise Exception(message)
    env.globals["raise_exception"] = raise_exception
    env.globals["strftime_now"] = lambda fmt: ""
    template = env.from_string((model_dir / "chat_template.jinja").read_text())
    return tok, template

def n(tok, text: str) -> int: return len(tok.encode(text, add_special_tokens=False).ids)

SECTION_MARKERS = [
    ("base prompt", r"^你是 iTalk 普通话助手"), ("clock", r"^当前时间："), ("memory", r"^【关于用户的已知信息"),
    ("tool rules (guided)", r"^需要查资料、联网搜索或操作设备时，直接调用"), ("tool rules (discovery)", r"^你可以使用这些技能"),
    ("tool rules (general)", r"^工具使用规则："), ("loaded skill", r"^\[已加载技能 "), ("force answer", r"^现在不能再调用任何工具"),
    ("voice", r"^这是语音对话"), ("tone instruction", r"^(语气标记|在回答中|如果需要标注|回答的语气|每一段)"),
]

def split_system(text: str):
    """The runner joins sections with a blank line; a loaded skill's own text may contain blank lines, so it runs until the next known section."""
    parts, current, label = [], [], None
    for block in text.split("\n\n"):
        hit = next((name for name, rx in SECTION_MARKERS if re.search(rx, block)), None)
        if hit and hit != "loaded skill" and label == "loaded skill" or hit and label != "loaded skill" or hit == "loaded skill":
            if current: parts.append((label or "other", "\n\n".join(current)))
            current, label = [block], hit
        else:
            current.append(block)
            if label is None: label = "other"
    if current: parts.append((label or "other", "\n\n".join(current)))
    merged = {}
    for name, body in parts: merged.setdefault(name, []).append(body)
    return {k: "\n\n".join(v) for k, v in merged.items()}

def report(tok, template, path: Path):
    doc = json.loads(path.read_text())
    window = doc["window"]
    print(f"\n=== {doc['scenario']}   window {window}   final state: {doc.get('finalState', '?')} {doc.get('failure', '') or ''}")
    for r in doc["requests"]:
        msgs, tools = r["messages"], r["tools"]
        text = template.render(messages=msgs, tools=tools or None, add_generation_prompt=True, enable_thinking=bool(r["reasoning"]))
        total = n(tok, text)
        reserve = r["maxTokens"]
        est_msgs = sum(estimate(m["content"]) for m in msgs)
        est_tools = sum(estimate(json.dumps(t, ensure_ascii=False)) for t in tools)
        print(f"-- request {r['index']} ({r['kind']}): prompt {total} tokens (real), output reservation {reserve}, left in window {window - total - reserve}"
              f"{'  ** DOES NOT FIT **' if total + reserve > window else ''}   [app estimate: messages {est_msgs} + tools {est_tools}]")
        sys_msgs = [m for m in msgs if m["role"] == "system"]
        if sys_msgs:
            for name, body in split_system(sys_msgs[0]["content"]).items():
                print(f"     system / {name:<22} {n(tok, body):>5} tokens  ({len(body)} chars; estimate {estimate(body)})")
        if tools:
            schema = sum(n(tok, json.dumps(t, ensure_ascii=False)) for t in tools)
            print(f"     tool schemas ({len(tools)} tools)        {schema:>5} tokens   (+ the template's fixed tool preamble)")
        for m in msgs:
            if m["role"] != "system": print(f"     {m['role']:<9}{'':<19}{n(tok, m['content']):>5} tokens  ({len(m['content'])} chars)")
        overhead = total - sum(n(tok, m['content']) for m in msgs) - sum(n(tok, json.dumps(t, ensure_ascii=False)) for t in tools)
        print(f"     chat-template overhead {'':<10}{overhead:>5} tokens")

if __name__ == "__main__":
    if len(sys.argv) < 3: sys.exit(__doc__)
    tok, template = load(Path(sys.argv[1]))
    for p in sys.argv[2:]: report(tok, template, Path(p))
