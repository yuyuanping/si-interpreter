// Offline translation via llama.cpp (vendored v0.9.0) running Tencent Hunyuan Hy-MT2-1.8B GGUF.
//
// The model is a translation-specialised instruction model (Apache-2.0): one user-turn prompt
// in, translated text out. We keep the native surface deliberately tiny — load / translate /
// free — because every feature we might want lives fine in the Kotlin layer.
#include <jni.h>
#include <android/log.h>
#include <string>
#include <vector>

#include "llama.h"

#define TAG "SiMt"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)

static llama_model *   g_model   = nullptr;
static llama_context * g_ctx     = nullptr;
static const llama_vocab * g_vocab = nullptr;
static int   g_n_threads = 4;
static std::string g_chat_template;   // from GGUF metadata; empty -> raw-instruction fallback

// route ggml/llama internal logs into logcat: without this a failed model load is silent
static void si_log_callback(ggml_log_level level, const char * text, void * /*user*/) {
    if (level == GGML_LOG_LEVEL_ERROR) LOGE("llama: %s", text);
    else if (level == GGML_LOG_LEVEL_WARN) LOGI("llama: %s", text);
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_qoder_si_LlamaMt_nativeInit(JNIEnv * env, jobject /*thiz*/, jstring jmodel_path,
                                     jint n_threads) {
    const char * model_path = env->GetStringUTFChars(jmodel_path, nullptr);
    g_n_threads = n_threads > 0 ? n_threads : 4;

    ggml_log_set(si_log_callback, nullptr);

    llama_model_params mparams = llama_model_default_params();
    // v0.9.0 loads mmap-by-default: RSS stays low, pages fault in as used
    g_model = llama_model_load_from_file(model_path, mparams);
    env->ReleaseStringUTFChars(jmodel_path, model_path);
    if (!g_model) {
        LOGE("model load failed: %s", model_path);
        return JNI_FALSE;
    }
    g_vocab = llama_model_get_vocab(g_model);

    llama_context_params cparams = llama_context_default_params();
    // prompt (~60 tokens) + output (<=512) for one spoken sentence fits easily; a larger
    // context only burns KV-cache RAM on a phone
    cparams.n_ctx     = 1024;
    cparams.n_batch   = 256;
    cparams.n_threads = g_n_threads;
    g_ctx = llama_init_from_model(g_model, cparams);
    if (!g_ctx) {
        LOGE("context create failed");
        return JNI_FALSE;
    }

    char buf[8192] = {0};
    if (llama_model_meta_val_str(g_model, "tokenizer.chat_template", buf, sizeof(buf)) > 0) {
        g_chat_template = buf;
        LOGI("chat template from GGUF: %.80s", g_chat_template.c_str());
    } else {
        LOGI("no chat template in GGUF, using raw instruction mode");
    }
    LOGI("init ok threads=%d n_ctx=%d", g_n_threads, (int) cparams.n_ctx);
    return JNI_TRUE;
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_qoder_si_LlamaMt_nativeTranslate(JNIEnv * env, jobject /*thiz*/, jstring jprompt,
                                          jint max_tokens) {
    if (!g_ctx || !g_model || !g_vocab) return env->NewStringUTF("");

    const char * prompt = env->GetStringUTFChars(jprompt, nullptr);
    std::string text = prompt;
    env->ReleaseStringUTFChars(jprompt, prompt);

    // Build the model input. Hy-MT2 has no system prompt; the instruction IS the user turn.
    // Apply the GGUF chat template when present so special tokens are right, else feed the
    // instruction raw after BOS — the model card's examples are plain instructions anyway.
    std::vector<llama_token> tokens;
    if (!g_chat_template.empty()) {
        llama_chat_message msgs[] = {{ "user", text.c_str() }};
        std::vector<char> fbuf(text.size() * 2 + 256);
        int32_t n = llama_chat_apply_template(g_chat_template.c_str(), msgs, 1, true,
                                              fbuf.data(), (int32_t) fbuf.size());
        if (n > (int32_t) fbuf.size()) {          // template outgrew the estimate: retry big
            fbuf.resize((size_t) n + 64);
            n = llama_chat_apply_template(g_chat_template.c_str(), msgs, 1, true,
                                          fbuf.data(), (int32_t) fbuf.size());
        }
        if (n > 0) {
            const char * rendered = fbuf.data();
            int32_t n_prompt = -llama_tokenize(g_vocab, rendered, n, nullptr, 0, true, true);
            tokens.resize(n_prompt);
            if (llama_tokenize(g_vocab, rendered, n, tokens.data(), n_prompt, true, true) < 0) {
                LOGE("tokenize failed (templated)");
                return env->NewStringUTF("");
            }
        }
    }
    if (tokens.empty()) {
        int32_t n_prompt = -llama_tokenize(g_vocab, text.c_str(), (int32_t) text.size(),
                                           nullptr, 0, true, true);
        tokens.resize(n_prompt);
        if (llama_tokenize(g_vocab, text.c_str(), (int32_t) text.size(), tokens.data(),
                           n_prompt, true, true) < 0) {
            LOGE("tokenize failed (raw)");
            return env->NewStringUTF("");
        }
    }

    // Each translation is independent: without clearing, the KV cache keeps every previous
    // turn's tokens and the model attends to stale context that is NOT in the current
    // prompt — quality decays turn over turn and the 1024 cache eventually fills.
    llama_memory_clear(llama_get_memory(g_ctx), true);

    // Tencent's recommended sampling: top_k 20 -> top_p 0.6 -> temp 0.7, with a mild
    // repeat penalty. Deterministic enough for MT, avoids the greedy repetition traps.
    llama_sampler_chain_params sparams = llama_sampler_chain_default_params();
    llama_sampler * smpl = llama_sampler_chain_init(sparams);
    llama_sampler_chain_add(smpl, llama_sampler_init_penalties(
        llama_vocab_n_tokens(g_vocab), 64, 1.05f, 0.0f, 0.0f));
    llama_sampler_chain_add(smpl, llama_sampler_init_top_k(20));
    llama_sampler_chain_add(smpl, llama_sampler_init_top_p(0.6f, 1));
    llama_sampler_chain_add(smpl, llama_sampler_init_temp(0.7f));
    llama_sampler_chain_add(smpl, llama_sampler_init_dist(LLAMA_DEFAULT_SEED));

    std::string out;
    out.reserve(256);
    int32_t n_ctx = llama_n_ctx(g_ctx);
    if ((int32_t) tokens.size() >= n_ctx - (int32_t) max_tokens) {
        LOGE("prompt too long: %d tokens", (int) tokens.size());
        llama_sampler_free(smpl);
        return env->NewStringUTF("");
    }

    int64_t n_pos = 0;
    for (int32_t i = 0; i < (int32_t) tokens.size(); i += 256) {
        int32_t n_chunk = std::min(256, (int32_t) tokens.size() - i);
        llama_batch batch = llama_batch_get_one(&tokens[i], n_chunk);
        if (llama_decode(g_ctx, batch) != 0) {
            LOGE("prompt decode failed at %d", i);
            llama_sampler_free(smpl);
            return env->NewStringUTF("");
        }
        n_pos += n_chunk;
    }

    llama_token new_token_id;
    while (true) {
        new_token_id = llama_sampler_sample(smpl, g_ctx, -1);
        if (llama_vocab_is_eog(g_vocab, new_token_id)) break;

        char piece[256];
        int32_t n = llama_token_to_piece(g_vocab, new_token_id, piece, sizeof(piece),
                                         0, true);
        if (n > 0) out.append(piece, (size_t) n);
        if ((int32_t) out.size() > max_tokens * 8 || out.size() > 4096) break;  // runaway cap

        llama_batch batch = llama_batch_get_one(&new_token_id, 1);
        if (llama_decode(g_ctx, batch) != 0) break;
        n_pos += 1;
        if (n_pos >= n_ctx) break;
    }
    llama_sampler_free(smpl);
    return env->NewStringUTF(out.c_str());
}

extern "C" JNIEXPORT void JNICALL
Java_com_qoder_si_LlamaMt_nativeFree(JNIEnv * /*env*/, jobject /*thiz*/) {
    if (g_ctx) { llama_free(g_ctx); g_ctx = nullptr; }
    if (g_model) { llama_model_free(g_model); g_model = nullptr; }
    g_vocab = nullptr;
    g_chat_template.clear();
    LOGI("freed");
}
