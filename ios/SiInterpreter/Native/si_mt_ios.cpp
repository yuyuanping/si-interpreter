// Offline translation via llama.cpp (vendored, shared with the Android build) running
// the Tencent Hunyuan Hy-MT2-1.8B / Gemma 4 GGUF. Logic ported 1:1 from
// app/src/main/cpp/si-mt.cpp — only the JNI boundary became this C ABI.
#include <algorithm>
#include <cstring>
#include <string>
#include <vector>

#include "si_mt_ios.h"
#include "llama.h"

#include <os/log.h>
static os_log_t si_log = os_log_create("com.qoder.si", "SiMt");

static llama_model *   g_model   = nullptr;
static llama_context * g_ctx     = nullptr;
static const llama_vocab * g_vocab = nullptr;
static int   g_n_threads = 4;
static std::string g_chat_template;   // from GGUF metadata; empty -> raw-instruction fallback

bool si_mt_init(const char * model_path, int n_threads) {
    g_n_threads = n_threads > 0 ? n_threads : 4;

    llama_model_params mparams = llama_model_default_params();
    // mmap by default: RSS stays low, pages fault in as used
    g_model = llama_model_load_from_file(model_path, mparams);
    if (!g_model) {
        os_log_error(si_log, "model load failed: %{public}s", model_path);
        return false;
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
        os_log_error(si_log, "context create failed");
        return false;
    }

    char buf[8192] = {0};
    if (llama_model_meta_val_str(g_model, "tokenizer.chat_template", buf, sizeof(buf)) > 0) {
        g_chat_template = buf;
        os_log_info(si_log, "chat template from GGUF: %{public}s", g_chat_template.c_str());
    } else {
        os_log_info(si_log, "no chat template in GGUF, using raw instruction mode");
    }
    os_log_info(si_log, "init ok threads=%d n_ctx=%d", g_n_threads, (int) cparams.n_ctx);
    return true;
}

int si_mt_translate(const char * prompt, int max_tokens, char * out_buf, int out_cap) {
    if (!g_ctx || !g_model || !g_vocab || !prompt || !out_buf || out_cap <= 1) return 0;
    std::string text = prompt;

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
                os_log_error(si_log, "tokenize failed (templated)");
                return 0;
            }
        }
    }
    if (tokens.empty()) {
        int32_t n_prompt = -llama_tokenize(g_vocab, text.c_str(), (int32_t) text.size(),
                                           nullptr, 0, true, true);
        tokens.resize(n_prompt);
        if (llama_tokenize(g_vocab, text.c_str(), (int32_t) text.size(), tokens.data(),
                           n_prompt, true, true) < 0) {
            os_log_error(si_log, "tokenize failed (raw)");
            return 0;
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
        os_log_error(si_log, "prompt too long: %d tokens", (int) tokens.size());
        llama_sampler_free(smpl);
        return 0;
    }

    int64_t n_pos = 0;
    for (int32_t i = 0; i < (int32_t) tokens.size(); i += 256) {
        int32_t n_chunk = std::min(256, (int32_t) tokens.size() - i);
        llama_batch batch = llama_batch_get_one(&tokens[i], n_chunk);
        if (llama_decode(g_ctx, batch) != 0) {
            os_log_error(si_log, "prompt decode failed at %d", i);
            llama_sampler_free(smpl);
            return 0;
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

    int written = 0;
    if (!out.empty() && out_cap > 1) {
        written = (int) std::min(out.size(), (size_t)(out_cap - 1));
        std::memcpy(out_buf, out.data(), (size_t) written);
        out_buf[written] = '\0';
    } else {
        out_buf[0] = '\0';
    }
    return written;
}

void si_mt_free(void) {
    if (g_ctx) { llama_free(g_ctx); g_ctx = nullptr; }
    if (g_model) { llama_model_free(g_model); g_model = nullptr; }
    g_vocab = nullptr;
    g_chat_template.clear();
    os_log_info(si_log, "freed");
}
