# SiInterpreter iOS 版

Android 同声传译 App 的原生 iOS 移植。同一套模型文件、同一个 vendored llama.cpp
（`app/src/main/cpp/llama.cpp`，与安卓共用一份源码）、同一条管线逻辑：
麦克风 → Silero VAD 门控 → 流式 Zipformer 识别 → VAD/端点切句 → SenseVoice 精识别
→ llama.cpp 离线翻译。

## 诚实的验证状态（先读这段）

这份代码是在 **Windows 机器上写出来的**——这台机器没有 macOS/Xcode，所以：

- ✅ sherpa-onnx C API 的每一个符号、函数签名、结构体字段都对照 **v2.0.1 官方
  iOS 框架内嵌的头文件逐个核对过**（xcframework 已实际下载解剖确认）；
- ✅ si_mt_ios.cpp 与已在安卓真机上跑通的 si-mt.cpp 逐行对应；
- ❌ Swift/SwiftUI 层没有编译过，**首次编译大概率有少量小错需要修**
  （C 互操作和 AVAudioConverter 是最可能出问题的两处）；
- ❌ 没有在真机上验证过音频管线行为。

第一次构建遇到报错把日志发回来即可，通常是几分钟能修完的小问题。

## 前置条件

- 一台 Mac + Xcode 16+
- `brew install xcodegen cmake`

## 构建步骤

```sh
# 1. 编译 llama.cpp 静态库（产物进 ios/llama-libs/）
cd ios && ./scripts/build-llama.sh

# 2. 下载 sherpa-onnx iOS 框架（与安卓 AAR 同版本系）
mkdir -p Frameworks && cd Frameworks
curl -LO https://github.com/k2-fsa/sherpa-onnx/releases/download/xcframework/sherpa-onnx-v2.0.1-ios-shared-onnxruntime-static.xcframework.zip
unzip sherpa-onnx-v2.0.1-ios-shared-onnxruntime-static.xcframework.zip
cd ..

# 3. 生成 Xcode 工程并打开
xcodegen generate
open SiInterpreter.xcodeproj
```

在 Xcode 里：Signing & Capabilities 选你的开发者 Team（真机必须有；
免费个人 Team 可以真机调试），然后 Cmd+R。

## 模型安装（两种方式）

1. **App 内下载**：首次启动的界面里点"下载模型"（走 hf-mirror 镜像，支持断点续传）。
2. **完全离线（Finder 拷贝）**：App 已开启文件共享，Mac 上打开 Finder →
   选 iPhone → 文件 → 同声传译 → `models/`，把 bundle 文件夹拖进去：

   ```
   models/
     asr-zipformer-bilingual-int8/   encoder.onnx decoder.onnx joiner.onnx tokens.txt
     vad-silero-v5/                  silero_vad.onnx
     asr-sensevoice-zh-en-int8/      model.int8.onnx tokens.txt
     mt-hymt2-1.8b-q4km/             model.gguf      (或 mt-gemma4-e2b-q4km/)
   ```

   拷完在 App 里点"重新扫描"。装了 Gemma 4 时优先用 Gemma，删掉它的目录即回退
   Hy-MT2——和安卓一致的 A/B 逻辑。

## 与安卓版的差异

| 项 | 安卓 | iOS |
|---|---|---|
| 后台保活 | 前台服务 + 常驻通知 | `audio` 后台模式 + 活跃的 AVAudioSession（锁屏不断） |
| 推模型 | adb push 到 /sdcard | Finder/文件 App 拖进 Documents（已开 UIFileSharingEnabled） |
| 识别线程模型 | 协程 + AudioRecord 阻塞读 | DispatchSourceTimer 100ms 节拍 + AVAudioEngine tap |
| Metal 加速 | 无（CPU+Accelerate） | v1 同样 CPU+Accelerate；后续可开 GGML_METAL（需编译 default.metallib 打包） |
| 滚动跟随 | LazyColumn + 手势感知暂停跟随 | ScrollViewReader 跟随末尾（v1 简化版：始终跟随，没有"上划暂停"） |

音频会话用 `.record` + `.measurement` 模式——对应安卓选 `VOICE_RECOGNITION`
音源的原因：跳过激进的增益处理，减少句间底噪泵入。

## 已知取舍

- 电平/时延 HUD 每 100ms 刷新一次（与安卓相同节拍）。
- `history` 上限 80 条、KV cache 每句清空、newest-wins 丢弃策略——全部与安卓一致。
- v1 没有做 iOS 的"上划暂停跟随"（需要 UIScrollView 内省），译文到达会自动滚到
  末尾；如果翻历史时被打断再来加。
