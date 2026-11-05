# Bundled OCR model notices

Vita Liber uses a locally executed PaddleOCR export. Original architecture and weights are credited to the PaddleOCR authors:

- **PP-OCRv6_small_det** — PaddlePaddle, PP-OCRv6 (2026); Apache-2.0.
  Source: https://huggingface.co/PaddlePaddle/PP-OCRv6_small_det_onnx (`inference.onnx`, sha256 d73e0058…).
- **PP-OCRv6_small_rec** — PaddlePaddle, PaddleOCR v3.7.0 (2026-06-11); Apache-2.0.
  Source: https://github.com/PaddlePaddle/PaddleOCR
  Official ONNX inference bundle: `PP-OCRv6_small_rec_onnx_infer.tar` (byte-identical to `PP-OCRv6_small_rec_onnx/inference.onnx`).
- **ONNX Runtime** — Microsoft; MIT. Runtime is provided by the existing `onnxruntime-libs` package already linked through sherpa-onnx.

No model weights are downloaded at runtime. Detection and recognition run only on-device, in memory, and never write images or text to disk except when the user explicitly enables OCR diagnostics for a non-sensitive document.
