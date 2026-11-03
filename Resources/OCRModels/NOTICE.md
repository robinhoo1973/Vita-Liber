# Bundled OCR model notices

Vita Liber uses a locally executed PaddleOCR export. Original architecture and weights are credited to the PaddleOCR authors:

- **PP-OCRv6_small_rec** — PaddlePaddle, PaddleOCR v3.7.0 (2026-06-11); Apache-2.0.
  Source: https://github.com/PaddlePaddle/PaddleOCR
  Official ONNX inference bundle: `PP-OCRv6_small_rec_onnx_infer.tar`.
- **ONNX Runtime** — Microsoft; MIT. Runtime is provided by the existing `onnxruntime-libs` package already linked through sherpa-onnx.

No model weights are downloaded at runtime. The recognition model runs only on-device, in memory, and never writes images or text to disk except when the user explicitly enables OCR diagnostics for a non-sensitive document.
