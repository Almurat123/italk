import subprocess, os, json, sys, wave, struct
import numpy as np
import onnxruntime as ort
from transformers import WhisperFeatureExtractor

HERE = os.path.dirname(os.path.abspath(__file__))
AUDIO = os.path.join(HERE, 'audio'); os.makedirs(AUDIO, exist_ok=True)
VOICES = {'zh': ['Flo (Chinese (China mainland))', 'Eddy (Chinese (China mainland))'], 'en': ['Flo (English (US))', 'Eddy (English (US))']}

# (language, full sentence, prefix after which the speaker is still going — or None when the sentence is finished)
ITEMS = []
zh_complete = ["明天杭州天气怎么样", "帮我设一个明天早上七点的闹钟", "把音量调大一点", "今天有什么新闻", "提醒我下午三点开会", "我想听一首周杰伦的歌", "现在几点了", "给我讲个笑话", "打开手电筒", "帮我算一下三百六十乘以十二",
               "你觉得这样可以吗", "这个周末我们去爬山好不好", "谢谢你", "帮我查一下附近的咖啡店", "我的快递到哪里了"]
zh_cut = [("帮我设一个明天早上七点的闹钟", "帮我设一个明天早上七点的"), ("提醒我下午三点开会", "提醒我下午三点"), ("我想听一首周杰伦的歌", "我想听一首"), ("把音量调大一点", "把音量"),
          ("明天杭州天气怎么样", "明天杭州的"), ("给李明发一条短信说我会晚到十分钟", "给李明发一条短信说"), ("我昨天晚上大概十二点才睡觉", "我昨天晚上"), ("帮我查一下附近的咖啡店", "帮我查一下"),
          ("我想要订一张明天去北京的机票", "我想要"), ("这个会议改到下午三点然后提前准备幻灯片", "这个会议改到下午三点然后"), ("我觉得这个方案不错但是预算有点", "我觉得这个方案不错但是"),
          ("如果明天下雨的话我们就改到后天", "如果明天下雨的话"), ("你能不能帮我把这份文件发给", "你能不能帮我把这份文件发给"), ("我今天早上起来之后先去跑了步然后", "我今天早上起来之后先去跑了步然后"), ("提醒我每个星期一早上九点", "提醒我每个星期一早上九点")]
en_complete = ["what's the weather like in Hangzhou tomorrow", "set an alarm for seven tomorrow morning", "turn up the volume a little", "what's in the news today", "remind me about the meeting at three",
               "play some music by Jay Chou", "what time is it now", "tell me a joke", "turn on the flashlight", "thank you very much", "can you check for coffee shops nearby", "where is my package",
               "I think that plan sounds good to me", "send a message to Li Ming saying I will be ten minutes late", "call my mother please"]
en_cut = [("set an alarm for seven tomorrow morning", "set an alarm for"), ("remind me about the meeting at three", "remind me about the"), ("play some music by Jay Chou", "play some"),
          ("what's the weather like in Hangzhou tomorrow", "what's the weather like in"), ("send a message to Li Ming saying I will be late", "send a message to Li Ming saying"),
          ("I was thinking that maybe we could go hiking this weekend", "I was thinking that maybe we could"), ("can you check for coffee shops nearby", "can you check for"),
          ("I want to book a ticket to Beijing for tomorrow", "I want to"), ("the meeting was moved to three so please prepare the slides", "the meeting was moved to three and"),
          ("I think the plan is good but the budget is a bit", "I think the plan is good but"), ("if it rains tomorrow we should move it to the day after", "if it rains tomorrow"),
          ("could you please forward this file to", "could you please forward this file to"), ("this morning I woke up went for a run and then", "this morning I woke up went for a run and then"),
          ("remind me every Monday at nine", "remind me every Monday at"), ("call my", "call my")]
for t in zh_complete: ITEMS.append(('zh', t, None))
for full, cut in zh_cut: ITEMS.append(('zh', full, cut))
for t in en_complete: ITEMS.append(('en', t, None))
for full, cut in en_cut: ITEMS.append(('en', full, cut))

def synth(text, voice, name):
    aiff = os.path.join(AUDIO, name + '.aiff'); wav = os.path.join(AUDIO, name + '.wav')
    if not os.path.exists(wav):
        subprocess.run(['say', '-v', voice, '-o', aiff, text], check=True)
        subprocess.run(['afconvert', '-f', 'WAVE', '-d', 'LEI16@16000', '-c', '1', aiff, wav], check=True); os.remove(aiff)
    with wave.open(wav) as w: return np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(np.float32) / 32768.0

sess = ort.InferenceSession(os.path.join(HERE, 'smart-turn-v3.2-cpu.onnx'), providers=['CPUExecutionProvider'])
fe = WhisperFeatureExtractor(chunk_length=8)
def predict(audio):
    audio = np.concatenate([audio, np.zeros(int(0.4 * 16000), dtype=np.float32)])        # the 0.4 s of silence a detector sees when it asks
    audio = audio[-8 * 16000:]
    if len(audio) < 8 * 16000: audio = np.pad(audio, (8 * 16000 - len(audio), 0))          # zeros go in FRONT: the end of speech sits at the right edge of the window, as in the model's reference code
    feats = fe(audio, sampling_rate=16000, return_tensors='np', padding='max_length', max_length=8 * 16000, truncation=True, do_normalize=True)['input_features'].astype(np.float32)
    return float(sess.run(None, {sess.get_inputs()[0].name: feats})[0].reshape(-1)[0])

rows = []
for i, (lang, full, cut) in enumerate(ITEMS):
    for v, voice in enumerate(VOICES[lang]):
        a_full = synth(full, voice, f'{lang}-{i:02d}-{v}-full')
        if cut:
            a_cut = synth(cut, voice, f'{lang}-{i:02d}-{v}-cut')
            audio = a_full[:min(len(a_full), max(int(0.35 * 16000), len(a_cut) - int(0.15 * 16000)))]         # the speaker keeps going: crop the full sentence where the prefix ends
        else: audio = a_full
        rows.append({'lang': lang, 'text': cut or full, 'complete': cut is None, 'p': predict(audio), 'seconds': round(len(audio) / 16000, 2), 'voice': v})
json.dump(rows, open(os.path.join(HERE, 'smart-turn-results.json'), 'w'), ensure_ascii=False, indent=1)
def report(rows, name):
    tp = sum(1 for r in rows if r['complete'] and r['p'] > 0.5); fn = sum(1 for r in rows if r['complete'] and r['p'] <= 0.5)
    tn = sum(1 for r in rows if not r['complete'] and r['p'] <= 0.5); fp = sum(1 for r in rows if not r['complete'] and r['p'] > 0.5)
    print(f'{name}: n={len(rows)} accuracy={(tp + tn) / len(rows):.2f}  complete→complete {tp}/{tp + fn}  unfinished→unfinished {tn}/{tn + fp}')
report(rows, 'all'); report([r for r in rows if r['lang'] == 'zh'], 'zh'); report([r for r in rows if r['lang'] == 'en'], 'en')

import itertools
def auc(rows):
    pos = [r['p'] for r in rows if r['complete']]; neg = [r['p'] for r in rows if not r['complete']]
    return sum((a > b) + 0.5 * (a == b) for a, b in itertools.product(pos, neg)) / (len(pos) * len(neg))
print('AUC all %.3f zh %.3f en %.3f' % (auc(rows), auc([r for r in rows if r['lang']=='zh']), auc([r for r in rows if r['lang']=='en'])))
for t in (0.3, 0.5, 0.7):
    ok = sum(1 for r in rows if (r['p'] > t) == r['complete']); print(f'threshold {t}: accuracy {ok / len(rows):.2f}')
import statistics
print('mean p complete %.2f unfinished %.2f' % (statistics.mean(r['p'] for r in rows if r['complete']), statistics.mean(r['p'] for r in rows if not r['complete'])))
