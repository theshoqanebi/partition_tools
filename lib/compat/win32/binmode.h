/* Force-included into the tools on Windows: make open()/fopen() default to
 * binary mode, as the AOSP sources assume POSIX semantics (no CRLF
 * translation, no Ctrl-Z EOF). */
#pragma once

#include <fcntl.h>
#include <stdlib.h>

namespace {
struct ForceBinaryMode {
    ForceBinaryMode() { _set_fmode(_O_BINARY); }
} force_binary_mode;
}  // namespace
