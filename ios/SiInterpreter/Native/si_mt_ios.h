// C ABI bridge to llama.cpp for the iOS app — the Swift counterpart of the Android
// JNI surface in app/src/main/cpp/si-mt.cpp. One model, one context, one blocking
// translate call; all heavy work happens on the caller's background queue.
//
// Memory contract: si_mt_translate writes into the caller's buffer and never retains
// it, so Swift can hand a fixed [CChar] array without any ownership dance.
#ifndef SI_MT_IOS_H
#define SI_MT_IOS_H

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Loads the GGUF and builds a 1024-token context. Returns false on failure;
/// llama.cpp internal errors are routed to os_log/console under "SiMt".
bool si_mt_init(const char *model_path, int n_threads);

/// Translates one prompt. Writes at most out_cap-1 bytes plus NUL; returns the
/// number of bytes written (0 on failure/empty). NOT thread-safe: callers serialize
/// (the engine's translate loop is the only caller).
int si_mt_translate(const char *prompt, int max_tokens, char *out, int out_cap);

void si_mt_free(void);

#ifdef __cplusplus
}
#endif

#endif // SI_MT_IOS_H
