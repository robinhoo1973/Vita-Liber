/*
 * PP-OCRv6 rec-only ONNX Runtime C bridge.
 *
 * The Apple slices link the already-present `onnxruntime-libs` static
 * framework (the same package identity used by sherpa-onnx). Linux builds a
 * stub so CoreKit swift test stays green without ORT.
 */
#include "ocr_bridge.h"

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>

#if defined(__APPLE__)
#if __has_include(<onnxruntime/onnxruntime_c_api.h>)
#include <onnxruntime/onnxruntime_c_api.h>
#else
#include <onnxruntime_c_api.h>
#endif

typedef struct {
    OrtEnv *env;
    OrtSession *session;
    OrtMemoryInfo *memory_info;
    char *input_name;
    char *lengths_name;   /* 双输入会话（CnOCR）的第二输入；单输入会话为 NULL */
    char *output_name;
} OCRSession;

static char g_error[1024];

static const OrtApi *ocr_api(void) {
    static const OrtApi *api = NULL;
    if (api == NULL) {
        const OrtApiBase *base = OrtGetApiBase();
        if (base != NULL) api = base->GetApi(ORT_API_VERSION);
    }
    return api;
}

static int ocr_check(const OrtApi *api, OrtStatus *status, const char *where) {
    if (status == NULL) return 0;
    const char *message = api->GetErrorMessage(status);
    snprintf(g_error, sizeof(g_error), "%s: %s", where, message == NULL ? "unknown ORT error" : message);
    api->ReleaseStatus(status);
    return -1;
}

static void *ocr_session_create_common(const void *model_data, size_t model_len,
                                       const char *input_name, const char *lengths_name,
                                       const char *output_name, int intra_threads) {
    g_error[0] = '\0';
    const OrtApi *api = ocr_api();
    if (api == NULL) { snprintf(g_error, sizeof(g_error), "OrtGetApiBase returned no API"); return NULL; }
    if (model_data == NULL || model_len == 0) { snprintf(g_error, sizeof(g_error), "empty model"); return NULL; }
    if (input_name == NULL || input_name[0] == '\0' ||
        output_name == NULL || output_name[0] == '\0') {
        snprintf(g_error, sizeof(g_error), "empty tensor name");
        return NULL;
    }
    if (lengths_name != NULL && lengths_name[0] == '\0') {
        snprintf(g_error, sizeof(g_error), "empty lengths tensor name");
        return NULL;
    }

    OCRSession *ctx = (OCRSession *)calloc(1, sizeof(OCRSession));
    if (ctx == NULL) { snprintf(g_error, sizeof(g_error), "out of memory"); return NULL; }
    ctx->input_name = strdup(input_name);
    ctx->output_name = strdup(output_name);
    ctx->lengths_name = lengths_name == NULL ? NULL : strdup(lengths_name);
    if (ctx->input_name == NULL || ctx->output_name == NULL ||
        (lengths_name != NULL && ctx->lengths_name == NULL)) {
        snprintf(g_error, sizeof(g_error), "out of memory");
        free(ctx->input_name);
        free(ctx->lengths_name);
        free(ctx->output_name);
        free(ctx);
        return NULL;
    }

    if (ocr_check(api, api->CreateEnv(ORT_LOGGING_LEVEL_WARNING, "vitalocr", &ctx->env), "CreateEnv") != 0) goto fail;

    OrtSessionOptions *options = NULL;
    if (ocr_check(api, api->CreateSessionOptions(&options), "CreateSessionOptions") != 0) goto fail;
    if (intra_threads > 0) {
        if (ocr_check(api, api->SetIntraOpNumThreads(options, intra_threads), "SetIntraOpNumThreads") != 0) {
            api->ReleaseSessionOptions(options);
            goto fail;
        }
    }
    if (ocr_check(api, api->CreateSessionFromArray(ctx->env, model_data, model_len, options, &ctx->session), "CreateSessionFromArray") != 0) {
        api->ReleaseSessionOptions(options);
        goto fail;
    }
    api->ReleaseSessionOptions(options);

    if (ocr_check(api, api->CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &ctx->memory_info), "CreateCpuMemoryInfo") != 0) goto fail;
    return ctx;

fail:
    if (ctx->memory_info != NULL) api->ReleaseMemoryInfo(ctx->memory_info);
    if (ctx->session != NULL) api->ReleaseSession(ctx->session);
    if (ctx->env != NULL) api->ReleaseEnv(ctx->env);
    free(ctx->input_name);
    free(ctx->lengths_name);
    free(ctx->output_name);
    free(ctx);
    return NULL;
}

void *ocr_session_create(const void *model_data, size_t model_len,
                         const char *input_name, const char *output_name,
                         int intra_threads) {
    return ocr_session_create_common(model_data, model_len, input_name, NULL,
                                     output_name, intra_threads);
}

void *ocr_session_create2(const void *model_data, size_t model_len,
                          const char *input_name, const char *lengths_input_name,
                          const char *output_name, int intra_threads) {
    return ocr_session_create_common(model_data, model_len, input_name, lengths_input_name,
                                     output_name, intra_threads);
}

void ocr_session_free(void *handle) {
    if (handle == NULL) return;
    OCRSession *ctx = (OCRSession *)handle;
    const OrtApi *api = ocr_api();
    if (api != NULL) {
        if (ctx->memory_info != NULL) api->ReleaseMemoryInfo(ctx->memory_info);
        if (ctx->session != NULL) api->ReleaseSession(ctx->session);
        if (ctx->env != NULL) api->ReleaseEnv(ctx->env);
    }
    free(ctx->input_name);
    free(ctx->lengths_name);
    free(ctx->output_name);
    free(ctx);
}

int ocr_session_run(void *handle,
                    const float *input,
                    int64_t height,
                    int64_t width,
                    float **out_buffer,
                    size_t *out_count,
                    int64_t *out_timesteps,
                    int64_t *out_classes) {
    g_error[0] = '\0';
    if (out_buffer != NULL) *out_buffer = NULL;
    if (out_count != NULL) *out_count = 0;
    if (out_timesteps != NULL) *out_timesteps = 0;
    if (out_classes != NULL) *out_classes = 0;
    if (handle == NULL || input == NULL || out_buffer == NULL || out_count == NULL ||
        out_timesteps == NULL || out_classes == NULL) {
        snprintf(g_error, sizeof(g_error), "invalid arguments");
        return -1;
    }
    if (height <= 0 || width <= 0 ||
        (uint64_t)height > SIZE_MAX / 3 / (uint64_t)width) {
        snprintf(g_error, sizeof(g_error), "invalid input shape %lldx%lld",
                 (long long)height, (long long)width);
        return -1;
    }
    OCRSession *ctx = (OCRSession *)handle;
    const OrtApi *api = ocr_api();
    if (api == NULL) { snprintf(g_error, sizeof(g_error), "ORT API unavailable"); return -1; }

    const int64_t shape[4] = {1, 3, height, width};
    const size_t element_count = (size_t)3 * (size_t)height * (size_t)width;
    if (element_count > SIZE_MAX / sizeof(float)) {
        snprintf(g_error, sizeof(g_error), "input tensor too large");
        return -1;
    }
    OrtValue *input_tensor = NULL;
    if (ocr_check(api, api->CreateTensorWithDataAsOrtValue(
                          ctx->memory_info, (void *)input, element_count * sizeof(float),
                          shape, 4, ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &input_tensor),
                  "CreateTensor") != 0) return -1;

    const char *input_names[] = {ctx->input_name};
    const char *output_names[] = {ctx->output_name};
    OrtValue *output = NULL;
    int failed = ocr_check(api, api->Run(ctx->session, NULL, input_names,
                                         (const OrtValue *const *)&input_tensor, 1,
                                         output_names, 1, &output),
                            "Run");
    api->ReleaseValue(input_tensor);
    if (failed != 0) {
        if (output != NULL) api->ReleaseValue(output);
        return -1;
    }

    OrtTensorTypeAndShapeInfo *info = NULL;
    if (ocr_check(api, api->GetTensorTypeAndShape(output, &info), "GetTensorTypeAndShape") != 0) {
        api->ReleaseValue(output);
        return -1;
    }
    size_t count = 0;
    size_t dim_count = 0;
    int64_t dims[4] = {0, 0, 0, 0};
    ONNXTensorElementDataType element_type = ONNX_TENSOR_ELEMENT_DATA_TYPE_UNDEFINED;
    if (ocr_check(api, api->GetTensorShapeElementCount(info, &count), "GetTensorShapeElementCount") != 0 ||
        ocr_check(api, api->GetDimensionsCount(info, &dim_count), "GetDimensionsCount") != 0 ||
        dim_count < 2 || dim_count > 4 ||
        ocr_check(api, api->GetDimensions(info, dims, 4), "GetDimensions") != 0 ||
        ocr_check(api, api->GetTensorElementType(info, &element_type), "GetTensorElementType") != 0 ||
        element_type != ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT) {
        api->ReleaseTensorTypeAndShapeInfo(info);
        api->ReleaseValue(output);
        return -1;
    }
    api->ReleaseTensorTypeAndShapeInfo(info);

    // rec 输出 [1,T,C]，det 输出 [1,1,H,W]：统一取最后两维为行×列，
    // 其余维度必须为 1（batch/channel）。rank 2 的 [H,W] 也接受。
    for (size_t i = 0; i + 2 < dim_count; i++) {
        if (dims[i] != 1) {
            snprintf(g_error, sizeof(g_error), "invalid output leading dim %zu = %lld",
                     i, (long long)dims[i]);
            api->ReleaseValue(output);
            return -1;
        }
    }
    const int64_t rows = dims[dim_count - 2];
    const int64_t cols = dims[dim_count - 1];
    if (rows <= 0 || cols <= 0 ||
        (uint64_t)rows > SIZE_MAX / (uint64_t)cols ||
        (uint64_t)rows * (uint64_t)cols != (uint64_t)count ||
        count > SIZE_MAX / sizeof(float)) {
        snprintf(g_error, sizeof(g_error), "invalid output shape %lldx%lld (rank %zu, count=%zu)",
                 (long long)rows, (long long)cols, dim_count, count);
        api->ReleaseValue(output);
        return -1;
    }

    void *raw = NULL;
    if (ocr_check(api, api->GetTensorMutableData(output, &raw), "GetTensorMutableData") != 0 || raw == NULL) {
        api->ReleaseValue(output);
        return -1;
    }
    float *copy = (float *)malloc(count * sizeof(float));
    if (copy == NULL) {
        snprintf(g_error, sizeof(g_error), "out of memory for output");
        api->ReleaseValue(output);
        return -1;
    }
    memcpy(copy, raw, count * sizeof(float));
    api->ReleaseValue(output);

    *out_buffer = copy;
    *out_count = count;
    *out_timesteps = rows;
    *out_classes = cols;
    return 0;
}

int ocr_session_run2(void *handle,
                     const float *input,
                     int64_t height,
                     int64_t width,
                     int64_t length,
                     float **out_buffer,
                     size_t *out_count,
                     int64_t *out_timesteps,
                     int64_t *out_classes) {
    g_error[0] = '\0';
    if (out_buffer != NULL) *out_buffer = NULL;
    if (out_count != NULL) *out_count = 0;
    if (out_timesteps != NULL) *out_timesteps = 0;
    if (out_classes != NULL) *out_classes = 0;
    if (handle == NULL || input == NULL || out_buffer == NULL || out_count == NULL ||
        out_timesteps == NULL || out_classes == NULL) {
        snprintf(g_error, sizeof(g_error), "invalid arguments");
        return -1;
    }
    if (height <= 0 || width <= 0 || length <= 0 ||
        (uint64_t)height > SIZE_MAX / (uint64_t)width) {
        snprintf(g_error, sizeof(g_error), "invalid input shape %lldx%lld (len %lld)",
                 (long long)height, (long long)width, (long long)length);
        return -1;
    }
    OCRSession *ctx = (OCRSession *)handle;
    if (ctx->lengths_name == NULL) {
        snprintf(g_error, sizeof(g_error), "session has no lengths input");
        return -1;
    }
    const OrtApi *api = ocr_api();
    if (api == NULL) { snprintf(g_error, sizeof(g_error), "ORT API unavailable"); return -1; }

    const int64_t x_shape[4] = {1, 1, height, width};
    const size_t element_count = (size_t)height * (size_t)width;
    if (element_count > SIZE_MAX / sizeof(float)) {
        snprintf(g_error, sizeof(g_error), "input tensor too large");
        return -1;
    }
    OrtValue *x_tensor = NULL;
    if (ocr_check(api, api->CreateTensorWithDataAsOrtValue(
                          ctx->memory_info, (void *)input, element_count * sizeof(float),
                          x_shape, 4, ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &x_tensor),
                  "CreateTensor(x)") != 0) return -1;

    const int64_t lengths_shape[1] = {1};
    int64_t length_value = length;
    OrtValue *lengths_tensor = NULL;
    if (ocr_check(api, api->CreateTensorWithDataAsOrtValue(
                          ctx->memory_info, &length_value, sizeof(int64_t),
                          lengths_shape, 1, ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64, &lengths_tensor),
                  "CreateTensor(lengths)") != 0) {
        api->ReleaseValue(x_tensor);
        return -1;
    }

    const char *input_names[] = {ctx->input_name, ctx->lengths_name};
    const OrtValue *input_values[] = {x_tensor, lengths_tensor};
    const char *output_names[] = {ctx->output_name};
    OrtValue *output = NULL;
    int failed = ocr_check(api, api->Run(ctx->session, NULL, input_names,
                                         (const OrtValue *const *)input_values, 2,
                                         output_names, 1, &output),
                            "Run");
    api->ReleaseValue(x_tensor);
    api->ReleaseValue(lengths_tensor);
    if (failed != 0) {
        if (output != NULL) api->ReleaseValue(output);
        return -1;
    }

    OrtTensorTypeAndShapeInfo *info = NULL;
    if (ocr_check(api, api->GetTensorTypeAndShape(output, &info), "GetTensorTypeAndShape") != 0) {
        api->ReleaseValue(output);
        return -1;
    }
    size_t count = 0;
    size_t dim_count = 0;
    int64_t dims[4] = {0, 0, 0, 0};
    ONNXTensorElementDataType element_type = ONNX_TENSOR_ELEMENT_DATA_TYPE_UNDEFINED;
    if (ocr_check(api, api->GetTensorShapeElementCount(info, &count), "GetTensorShapeElementCount") != 0 ||
        ocr_check(api, api->GetDimensionsCount(info, &dim_count), "GetDimensionsCount") != 0 ||
        dim_count < 2 || dim_count > 4 ||
        ocr_check(api, api->GetDimensions(info, dims, 4), "GetDimensions") != 0 ||
        ocr_check(api, api->GetTensorElementType(info, &element_type), "GetTensorElementType") != 0 ||
        element_type != ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT) {
        api->ReleaseTensorTypeAndShapeInfo(info);
        api->ReleaseValue(output);
        return -1;
    }
    api->ReleaseTensorTypeAndShapeInfo(info);

    for (size_t i = 0; i + 2 < dim_count; i++) {
        if (dims[i] != 1) {
            snprintf(g_error, sizeof(g_error), "invalid output leading dim %zu = %lld",
                     i, (long long)dims[i]);
            api->ReleaseValue(output);
            return -1;
        }
    }
    const int64_t rows = dims[dim_count - 2];
    const int64_t cols = dims[dim_count - 1];
    if (rows <= 0 || cols <= 0 ||
        (uint64_t)rows > SIZE_MAX / (uint64_t)cols ||
        (uint64_t)rows * (uint64_t)cols != (uint64_t)count ||
        count > SIZE_MAX / sizeof(float)) {
        snprintf(g_error, sizeof(g_error), "invalid output shape %lldx%lld (rank %zu, count=%zu)",
                 (long long)rows, (long long)cols, dim_count, count);
        api->ReleaseValue(output);
        return -1;
    }

    void *raw = NULL;
    if (ocr_check(api, api->GetTensorMutableData(output, &raw), "GetTensorMutableData") != 0 || raw == NULL) {
        api->ReleaseValue(output);
        return -1;
    }
    float *copy = (float *)malloc(count * sizeof(float));
    if (copy == NULL) {
        snprintf(g_error, sizeof(g_error), "out of memory for output");
        api->ReleaseValue(output);
        return -1;
    }
    memcpy(copy, raw, count * sizeof(float));
    api->ReleaseValue(output);

    *out_buffer = copy;
    *out_count = count;
    *out_timesteps = rows;
    *out_classes = cols;
    return 0;
}

void ocr_buffer_free(float *buffer) { free(buffer); }

const char *ocr_last_error(void) { return g_error; }

#else

static const char *k_unavailable = "ONNX Runtime bridge is only available on Apple platforms";

void *ocr_session_create(const void *model_data, size_t model_len,
                         const char *input_name, const char *output_name,
                         int intra_threads) {
    (void)model_data; (void)model_len; (void)input_name; (void)output_name;
    (void)intra_threads;
    return NULL;
}
void *ocr_session_create2(const void *model_data, size_t model_len,
                          const char *input_name, const char *lengths_input_name,
                          const char *output_name, int intra_threads) {
    (void)model_data; (void)model_len; (void)input_name; (void)lengths_input_name;
    (void)output_name; (void)intra_threads;
    return NULL;
}
void ocr_session_free(void *handle) { (void)handle; }
int ocr_session_run(void *handle, const float *input, int64_t height, int64_t width,
                    float **out_buffer, size_t *out_count, int64_t *out_timesteps,
                    int64_t *out_classes) {
    (void)handle; (void)input; (void)height; (void)width;
    if (out_buffer != NULL) *out_buffer = NULL;
    if (out_count != NULL) *out_count = 0;
    if (out_timesteps != NULL) *out_timesteps = 0;
    if (out_classes != NULL) *out_classes = 0;
    return -1;
}
int ocr_session_run2(void *handle, const float *input, int64_t height, int64_t width,
                     int64_t length, float **out_buffer, size_t *out_count,
                     int64_t *out_timesteps, int64_t *out_classes) {
    (void)handle; (void)input; (void)height; (void)width; (void)length;
    if (out_buffer != NULL) *out_buffer = NULL;
    if (out_count != NULL) *out_count = 0;
    if (out_timesteps != NULL) *out_timesteps = 0;
    if (out_classes != NULL) *out_classes = 0;
    return -1;
}
void ocr_buffer_free(float *buffer) { (void)buffer; }
const char *ocr_last_error(void) { return k_unavailable; }

#endif
