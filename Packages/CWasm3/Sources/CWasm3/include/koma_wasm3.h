// Small helpers for the Swift glue in Koma.
#ifndef koma_wasm3_h
#define koma_wasm3_h

#include "wasm3.h"

/// The userdata pointer that was given to m3_LinkRawFunctionEx.
static inline void * _Nullable koma_wasm3_userdata(IM3ImportContext _Nullable context) {
    return context ? context->userdata : 0;
}

#endif
