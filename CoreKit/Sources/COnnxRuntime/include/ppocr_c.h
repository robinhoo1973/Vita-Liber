#ifndef PPORC_C_H
#define PPORC_C_H

#ifdef __cplusplus
extern "C" {
#endif

// Returns a static C string describing the loaded ONNX Runtime version,
// or an error marker if the runtime could not be initialized.
const char* ort_runtime_version(void);

#ifdef __cplusplus
}
#endif

#endif /* PPORC_C_H */
