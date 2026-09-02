#include "onnxruntime_c_api.h"
#include "ppocr_c.h"

// Thin C wrapper so Swift only sees a clean C function; the C compiler
// handles ORT's struct/function-pointer types on our behalf.
const char* ort_runtime_version(void) {
    const OrtApiBase* base = OrtGetApiBase();
    if (base == NULL) {
        return "OrtGetApiBase:null";
    }
    const OrtApi* api = base->GetApi(ORT_API_VERSION);
    if (api == NULL) {
        return "GetApi:null";
    }
    const char* version = base->GetVersionString();
    return version != NULL ? version : "unknown";
}
