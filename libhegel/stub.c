// The engine for platforms libhegel has no build for, such as iOS: every
// call fails, so that Hegel builds and links there, and a property reports
// that the engine is unavailable instead of running.
//
// The functions that return a `hegel_result_t` are in stub-generated.c,
// which Scripts/generate-engine-stub.sh writes from hegel.h. This file has
// the ones that return something else; the script leaves out every function
// defined here.

#include "hegel.h"

static const char unavailable[] = "libhegel isn't available on this platform";

// What a constructor returns. No call reads through a handle: they all fail
// first.
static char handle;

void hegel_output_stderr(void *_user_data, const char *line, size_t len) {
    (void)_user_data;
    (void)line;
    (void)len;
}

hegel_output_callback_t hegel_output_stderr_callback(void) {
    return hegel_output_stderr;
}

hegel_context_t *hegel_context_new(void) {
    return (hegel_context_t *)&handle;
}

hegel_string_t hegel_context_last_error(const hegel_context_t *ctx) {
    (void)ctx;
    hegel_string_t message = {.data = unavailable, .len = sizeof unavailable - 1};
    return message;
}
