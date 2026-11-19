# Voice listening pack (2026-10-30)
The four voices that ship with iTalk (MOSS-TTS-Nano, on-device), each reading four test sentences, synthesized on the Mac by `tools/neural-bench library` (GPU, real-time factor 0.45–0.60 on the Mac; the iPhone measured 0.5–0.8 in the foreground). AAC, 48 kHz source.

| voice | character | files |
| --- | --- | --- |
| 云舒 `moss-yunshu` | 明亮、自然、有笑意（女） | `moss-yunshu-*.m4a` |
| 书瑶 `moss-shuyao` | 温和、清晰、亲切（女） | `moss-shuyao-*.m4a` |
| 老傅 `moss-laofu` | 成熟、沉稳、娓娓道来（男） | `moss-laofu-*.m4a` |
| 阿京 `moss-ajing` | 年轻、轻松、带京腔（男） | `moss-ajing-*.m4a` |

Sentences: `zh-chat` 明天杭州天气不错，最高二十五度，适合出门走走，不过早晚有点凉，记得带件外套。 · `zh-comfort` 别担心，这种事情很常见，我们一步一步来解决，一定没问题的。 · `en-chat` Sure, I can set an alarm for ten tomorrow morning. Do you want it to repeat on weekdays? · `mix` 这个 meeting 改到下午三点了，记得提前 prepare 一下 slides，然后把 deadline 发给我。

What to listen for: mixed Chinese/English in `mix` (no accent break at "meeting"/"slides"/"deadline"), numbers in `zh-chat`, warmth in `zh-comfort`. Measured intelligibility (round-trip ASR character error rate) was 0.076 for MOSS versus 0.21–0.25 for the Kokoro voices it replaced (`docs/measurements`, `tools/tts-eval`); that is a machine score, not a substitute for your ears.
