# MOSS-TTS-Nano runtime — provenance and licenses

- The Swift files in this folder are adapted from `soniqo/speech-swift`, `Sources/MossTTSNano` (Apache License 2.0,
  https://github.com/soniqo/speech-swift). Changes: renamed to `MossNano*`, removed the `AudioCommon` dependency and the Hugging Face
  downloader (iTalk installs models through its hash-verified `ModelStore`), added a mono stream and local audio loading helpers.
- Model: MOSS-TTS-Nano-100M (OpenMOSS / MOSI.AI, Apache License 2.0) converted to Core ML by `aufklarer/MOSS-TTS-Nano-100M-CoreML`
  (Apache License 2.0). Review both licenses again before shipping a release build.
