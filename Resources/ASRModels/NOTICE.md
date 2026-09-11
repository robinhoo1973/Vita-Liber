# Bundled speech model notices

Vita Liber uses locally executed model exports. Original architectures and weights are credited to their authors:

- **Qwen3-ASR-0.6B** — Qwen Team, Alibaba Cloud; Apache-2.0. ONNX export: Wasser1462 / sherpa-onnx contributors. Source: https://github.com/QwenLM/Qwen3-ASR
- **Dolphin-small CTC** — Dataocean AI and Tsinghua University; Apache-2.0. This is the 2025 CTC-only export, not Dolphin-CN-Dialect. Source: https://github.com/DataoceanAI/Dolphin
- **Streaming bilingual Zipformer** — k2-fsa/icefall and pfluo contributors; Apache-2.0. Source: https://huggingface.co/pfluo/k2fsa-zipformer-chinese-english-mixed
- **Whisper-small** — Copyright (c) 2022 OpenAI; MIT. Source: https://github.com/openai/whisper
- **Silero VAD** — Copyright (c) 2020-present Silero Team; MIT. Source: https://github.com/snakers4/silero-vad
- **sherpa-onnx** — k2-fsa contributors; Apache-2.0. ONNX Runtime — Microsoft contributors; MIT (runtime notices accompany its distribution).

Export versions, source URLs, checksums, and file sizes are recorded in manifest.json and the generated resolved-manifest.json. Vita Liber consumes the listed exports without retraining. Model coverage claims and upstream benchmark results do not establish medical-dictation accuracy on a user's device.

The Apache-2.0 text is in LICENSE-APACHE-2.0.txt. The following MIT text applies separately to Whisper and Silero VAD under the copyright notices above:

## MIT License

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
