#ifndef OCR_BRIDGE_H
#define OCR_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// 创建 PP-OCRv6 rec ONNX 会话。成功返回非 NULL；失败返回 NULL，
/// 错误文本由 ocr_last_error() 读取。model_data 在调用期间必须有效。
void *ocr_session_create(const void *model_data, size_t model_len,
                         const char *input_name, const char *output_name,
                         int intra_threads);

void ocr_session_free(void *handle);

/// 同步推理一张 [1,3,height,width] 浮点张量（rec 48×width / det 检测图）。
/// 成功返回 0；输出 buffer 由本库 malloc，调用方用 ocr_buffer_free() 释放。
/// 输出 rank 2–4，leading dims 必须为 1；最后两维为行×列：
/// out_count = rows * cols；out_timesteps/out_classes 回填行/列（rec=T,C；det=H,W）。
int ocr_session_run(void *handle,
                    const float *input,
                    int64_t height,
                    int64_t width,
                    float **out_buffer,
                    size_t *out_count,
                    int64_t *out_timesteps,
                    int64_t *out_classes);

void ocr_buffer_free(float *buffer);

/// 最近一次错误（线程不安全；每次调用前清空）。
const char *ocr_last_error(void);

#ifdef __cplusplus
}
#endif

#endif
