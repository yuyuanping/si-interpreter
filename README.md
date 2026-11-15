# 同声传译 (离线 Android)

麦克风 → 流式语音识别 → 分句 → 翻译 → 双语字幕。运行期不联网。

## 当前状态

| 环节 | 状态 |
|---|---|
| 音频采集 (AudioRecord + 前台服务) | 完成，真机验证 ✓ |
| 流式识别 (sherpa-onnx 中英双语 Zipformer) | 完成，真机验证 ✓（识别质量受限于 2023 老模型） |
| VAD 门控 (Silero v5，防噪音幻觉) | 完成，真机验证 ✓ |
| 精识别 (SenseVoice-Small 离线整段解码) | 完成，真机验证 ✓ |
| 分句 (VAD 静音边界 + endpoint 兜底) | 完成，真机验证 ✓ |
| 翻译 (腾讯混元 Hy-MT2-1.8B + llama.cpp) | 代码完成，待真机验证 |
| TTS 配音 | 未做 |

整条链路：麦克风 → Silero VAD 门控 → 流式 Zipformer 实时上屏 → VAD 分段 → SenseVoice 整段精解码 → Hy-MT2 llama.cpp 翻译 → 双语字幕。运行期不联网。

翻译模型：tencent/Hy-MT2-1.8B-GGUF Q4_K_M（1.1 GB，Apache-2.0），llama.cpp v0.9.0
以源码形式 vendor 在 `app/src/main/cpp/llama.cpp`，JNI 见 `si-mt.cpp`。曾调研过的替代路线：
ONNX NLLB-600M（RTranslator 路线，慢）、Firefox Bergamot（无中文）、2bit/1.25bit 极限量化
（AngelSlim STQ 格式，上游 llama.cpp 尚不支持）——均被 Hy-MT2 路线取代。

## 环境

```
ANDROID_HOME = D:\android-sdk          (platform 35, build-tools 35.0.0, platform-tools)
JAVA_HOME    = C:\Program Files\Java\jdk-18.0.2
Gradle       = D:\gradle-dist\gradle-8.11.1
```

构建：

```bash
cd /d/dayly/同声传译
export JAVA_HOME="C:\\Program Files\\Java\\jdk-18.0.2" ANDROID_HOME="D:/android-sdk"
/d/gradle-dist/gradle-8.11.1/bin/gradle.bat :app:assembleDebug
# → app/build/outputs/apk/debug/app-arm64-v8a-debug.apk  (40 MB)
```

## 装模型：两条路

四个模型包（见 Bundles.kt），全部装好后才是完整链路：

| 包 | 作用 | 大小 |
|---|---|---|
| asr-zipformer-bilingual-int8 | 流式实时上屏 | 182 MB |
| asr-sensevoice-zh-en-int8 | VAD 分段整段精解码（最终文本） | 228 MB |
| vad-silero-v5 | 语音门控，防噪音幻觉 | 2.2 MB |
| mt-hymt2-1.8b-q4km | Hy-MT2 离线翻译 GGUF | 1.1 GB |

### A. adb push（手机完全不联网）

PC 上已下好（`D:\dayly\` 下 encoder/decoder/joiner/tokens/silero_vad/sensevoice-dl/mt-dl）：

```bash
# 统一路线：先 push 到 /data/local/tmp，再 run-as 拷进 filesDir（外部目录对 App 不可见的坑已踩过）
adb push D:\dayly\encoder.onnx /data/local/tmp/encoder.onnx
adb shell 'run-as com.qoder.si sh -c "cat /data/local/tmp/encoder.onnx > files/models/asr-zipformer-bilingual-int8/encoder.onnx"'
# 其余文件同理；GGUF 目标是 files/models/mt-hymt2-1.8b-q4km/model.gguf
```

然后 App 里点「推完后重新扫描」。

> 注意：卸载 app 会清空 filesDir，所有模型要重推。
> vivo 对已装应用 `adb install -r` 可能弹确认框，`adb uninstall` 后全新安装可绕过。

### B. App 内下载（仅流式 ASR 模型）

首次启动点下载按钮，196 MB，走 hf-mirror 失败自动切 huggingface.co。
支持断点续传（`.part` + Range，只有字节数达标才改名成正式文件）。
其余三个包走 adb push 或自建镜像。

## 手机上要做的验证

工程能不能跑，只有插上线才知道。按顺序：

1. **模型能否加载** — 点「开始」。这是最可能崩的一步，
   因为 `OnlineRecognizer(null, cfg)` 走 file-based 分支虽然我从 v2.0.0 的字节码
   里确认了 `ifnull → newFromFile`，但没在真机上跑过。
   崩溃时抓 `adb logcat -s sherpa-onnx:*, OnlineRecognizer:*`。

2. **识别质量** — 对手机说英语和中文，看上半屏的实时partial字幕。
   中英混说是这个模型的卖点，值得专门试。

3. **延迟结构** — 看顶部四个数字：`译文延迟` / `丢弃` / `已听`。
   现在翻译是假的（固定 120ms），所以这个数字只反映**分句**的快慢。
   真正要判断的是：说完一句到出现新条目，等多久。

4. **后台连续性** — 开始识别后按电源键息屏 10 秒再点亮。
   前台服务若没生效，中间那段会缺失。这是 Android 9+ 的硬约束。

## 已知的、需要真机数据才能定的参数

* `AsrEngine` 里三条 endpoint 规则 (`2.4s / 1.2s / 20s`)：
  切太快译文会碎，切太慢延迟高。必须听真人对话调。
* `hopMs = 100`：太小时 JNI 调用开销占比过高，太大则首字延迟变高。
* `numThreads = 2`：需在你的具体芯片上测吞吐。
* `AudioSource`：现在用 `VOICE_RECOGNITION`（跳过 aggressive AGC，
  避免它在句子间隙把底噪抬起来让模型产生幻觉词）。若实际拾音音量偏低，
  改回 `MIC` 对比。

## 剩下的真问题：翻译

已经排除掉的（都不是推测，是查过的）：

* **sherpa-onnx 没有翻译 API**。AAR 里不存在 `OfflineTranslationModelConfig`，
  `OfflineModelConfig` 也没有翻译字段；`OnlineRecognizer` 内部虽然有
  `transducerModelConfig.decoder`，但那是 RNN-T 的 token 解码器，
  不是神经 MT 的 cross-attention 解码器。接不上。
* **sherpa-onnx 的 AAR 不含 llama.cpp**。`jni/arm64-v8a/` 只有 4 个 so
  （onnxruntime / c-api / cxx-api / jni），没有 ggml 符号，所以没有现成
  的 GGUF LLM 推理入口。
* **ONNX Runtime Java API 没有 generate()**，官方也只支持 Whisper 走该 API。
  MaraNMT/NLLB 的 KV-cache 融合算子是 C# GenAI 专属。
  → 意味着 encoder-decoder 方案必须自己写 JNI（约 800–1500 行 C++）。

`Translator` 接口就是为此留的：上游（采集/识别/分句/UI/延迟统计）与选型无关，
换引擎不动一行流水线代码。三个候选，代价不同：

| 方案 | 延迟 | 质量 | 工程量 |
|---|---|---|---|
| llama.cpp + Qwen2.5-1.5B 量化 | 2–4 s | 好（带上下文） | JNI 编译，中 |
| llama.cpp + Qwen2.5-0.5B | 1–1.8 s | 中，长句漏译 | JNI 编译，中 |
| MaraNMT 自己写 JNI 解码 | 0.3–1 s | 中 | C++ 解码器，大 |

**还没定，是因为它取决于你的手机芯片和 RAM。** 装上 App 后我读一次
`/proc/cpuinfo` + 内存上限，再决定。

## 目录结构

```
app/src/main/java/com/qoder/si/
  AsrEngine.kt            sherpa-onnx 流式识别封装
  InterpreterEngine.kt    流水线：采集→识别→分句→翻译
  InterpreterService.kt   前台服务（息屏不断流）
  Translator.kt           翻译接口 + 上下文窗口
  PlaceholderTranslator.kt 占位实现，非真翻译
  ModelStore.kt           模型定位与完整性校验（内部/adb 两个根）
  ModelInstaller.kt       断点续传下载器（唯一联网处）
  Bundles.kt              模型清单
  PipelineConfig.kt       可调参数
  MainActivity.kt         Compose UI
```
