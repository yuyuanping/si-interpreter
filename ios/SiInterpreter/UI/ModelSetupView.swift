import SwiftUI

/// First-run screen: install the voice model (download or Finder sideload).
/// Port of ModelSetup() from MainActivity.kt.
struct ModelSetupView: View {
    @ObservedObject var installer: ModelInstaller
    let store: ModelStore
    let onRescan: () -> Void

    private let bundle = Bundles.asrZipformerBilingual

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("第一步 · 安装语音模型").sectionStyle()
                Card {
                    Text(bundle.label)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(Theme.fg)
                    Text(bundle.note)
                        .font(.system(size: 12))
                        .foregroundColor(Theme.dim)
                    Text("只有这一步需要网络。装完后飞行模式可正常使用。")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.dim)

                    if installer.state.active {
                        Text("\(installer.state.fileIndex)/\(installer.state.fileCount)  \(installer.state.fileName)")
                            .font(.system(size: 12))
                            .foregroundColor(Theme.ok)
                        ProgressBar(done: installer.state.done, total: installer.state.total)
                        Text("\(Fmt.mb(installer.state.done)) / \(Fmt.mb(installer.state.total)) MB    \(Fmt.speed(installer.state.bytesPerSec))")
                            .font(.system(size: 12))
                            .foregroundColor(Theme.dim)
                        Button("取消") { installer.cancel() }
                            .frame(maxWidth: .infinity)
                            .buttonStyle(.bordered)
                            .padding(.top, 8)
                    } else {
                        Button {
                            Task { await installer.install(bundle) }
                        } label: {
                            Text("下载模型 \(bundle.totalMb) MB")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        if !installer.state.message.isEmpty {
                            Text(installer.state.message)
                                .font(.system(size: 12))
                                .foregroundColor(Theme.warn)
                        }
                    }
                }

                Text("完全不走网：用 Finder 拷贝模型").sectionStyle()
                Card {
                    Text("电脑上下载好，通过 Finder / 文件 App 拷进手机，App 直接识别。")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.dim)
                    Text("目标目录（点击复制）")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.faint)
                    let path = store.sideloadTargetFor(bundle.id)
                    Text(path)
                        .font(.system(size: 11))
                        .foregroundColor(Theme.live)
                        .onTapGesture { UIPasteboard.general.string = path }
                    Text("文件名必须改成")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.faint)
                    ForEach(bundle.files, id: \.local) { fs in
                        Text("  \(fs.remote)  →  \(fs.local)")
                            .font(.system(size: 11))
                            .foregroundColor(Theme.dim)
                    }
                    Button("拷完后重新扫描") { onRescan() }
                        .frame(maxWidth: .infinity)
                        .buttonStyle(.bordered)
                        .padding(.top, 8)
                }
            }
            .padding(.horizontal, 16)
        }
    }
}

/// Idle screen: installed list, direction chips, start button.
/// Port of IdlePanel() from MainActivity.kt.
struct IdlePanelView: View {
    @ObservedObject var session: Session
    let installed: [String]

    @State private var src = "en"
    @State private var tgt = "zh"
    @State private var cut: Float = 1.0
    @State private var speak = false
    @State private var pickMt: String? = nil

    /// the SAME resolution rule ModelStore.pathsMt applies: the picked bundle wins only
    /// when installed, otherwise the first installed MT bundle in A/B order
    private var installedMt: [Bundle] {
        Bundles.all.filter { $0.kind == .mt && installed.contains($0.id) }
    }
    private var chosenMt: Bundle? {
        installedMt.first { $0.id == pickMt } ?? installedMt.first
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                installedList
                    .onAppear {
                        cut = session.config.cutSilenceSec
                        speak = session.config.speakTranslation
                        pickMt = session.config.mtBundleId
                    }
                Text("方向").sectionStyle()
                Card {
                    HStack(spacing: 10) {
                        LangChip(text: "英 → 中", selected: src == "en" && tgt == "zh") {
                            src = "en"; tgt = "zh"
                        }
                        LangChip(text: "中 → 英", selected: src == "zh" && tgt == "en") {
                            src = "zh"; tgt = "en"
                        }
                    }
                    Text("每句按实测语言自动定向：说中文译成英文，说英文译成中文。上方选择仅在无法判定时生效。")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.dim)
                        .padding(.top, 8)

                    let mtEngine = chosenMt?.label
                    Text(mtEngine != nil
                         ? "翻译引擎已就绪：\(mtEngine!)，纯本地推理。"
                         : "安装下方翻译模型后即可离线翻译；未安装时译文处显示占位标记。")
                        .font(.system(size: 12))
                        .foregroundColor(mtEngine != nil ? Theme.ok : Theme.warn)
                        .padding(.top, 8)
                }

                Text("断句停顿").sectionStyle()
                Card {
                    HStack(spacing: 10) {
                        ForEach([Float(0.5), 1.0, 1.5, 2.5], id: \.self) { v in
                            LangChip(text: String(format: "%.1fs", v), selected: cut == v) {
                                cut = v
                                session.config.cutSilenceSec = v
                            }
                        }
                    }
                    Text("说话停顿超过该时长就按句尾切句并翻译。句子被切得太碎就调大，译文会相应出得稍慢。")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.dim)
                        .padding(.top, 8)
                }

                Text("语音播报").sectionStyle()
                Card {
                    HStack(spacing: 10) {
                        LangChip(text: "开", selected: speak) {
                            speak = true; session.config.speakTranslation = true
                        }
                        LangChip(text: "关", selected: !speak) {
                            speak = false; session.config.speakTranslation = false
                        }
                    }
                    Text("译文完成后用系统语音朗读，零下载。播报期间暂停聆听，避免把喇叭里的声音识别进来；点任意一条译文可重听。")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.dim)
                        .padding(.top, 8)
                }

                Text("翻译模型").sectionStyle()
                Card {
                    if installedMt.isEmpty {
                        Text("未安装翻译模型。装好后可在此选择用哪个模型翻译。")
                            .font(.system(size: 12))
                            .foregroundColor(Theme.warn)
                    } else {
                        HStack(spacing: 10) {
                            LangChip(text: "自动", selected: pickMt == nil) {
                                pickMt = nil; session.config.mtBundleId = nil
                            }
                            ForEach(installedMt, id: \.id) { b in
                                LangChip(text: b.id == Bundles.mtGemma4E2B.id ? "Gemma" : "混元",
                                         selected: pickMt == b.id) {
                                    pickMt = b.id; session.config.mtBundleId = b.id
                                }
                            }
                        }
                        Text("自动 = 优先谷歌 Gemma 4，未装则用混元 Hy-MT2。切换在下次开始时生效。")
                            .font(.system(size: 12))
                            .foregroundColor(Theme.dim)
                            .padding(.top, 8)
                    }
                }

                Button {
                    session.config.sourceLang = src
                    session.config.targetLang = tgt
                    session.start()
                } label: {
                    Text("开始")
                        .font(.system(size: 18))
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                }
                .buttonStyle(.borderedProminent)
                .disabled(src == tgt || installed.isEmpty)
            }
            .padding(.horizontal, 16)
        }
    }

    private var installedList: some View {
        ModelManagerView(installer: session.installer,
                         store: session.store,
                         installed: installed,
                         onRescan: { session.rescan() })
    }
}

/// Every bundle in the catalogue with its state and one action each: installed -> 删除
/// (re-downloadable, so no confirm), missing -> 下载 through the in-app installer, and a
/// live progress row while that bundle's files are fetching. This is what makes the
/// 翻译模型 switch real: the alternative GGUF is installable without a computer.
private struct ModelManagerView: View {
    @ObservedObject var installer: ModelInstaller
    let store: ModelStore
    let installed: [String]
    let onRescan: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("模型").sectionStyle()
            Card {
                ForEach(Bundles.all, id: \.id) { b in
                    row(b)
                }
                if !installer.state.active && !installer.state.message.isEmpty {
                    Text(installer.state.message)
                        .font(.system(size: 12))
                        .foregroundColor(installer.state.message.contains("失败")
                                         ? Theme.warn : Theme.ok)
                        .padding(.top, 4)
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ b: Bundle) -> some View {
        let here = installed.contains(b.id)
        let busy = installer.state.active && installer.state.label == b.label
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(here ? "✓  \(b.label)" : "＋  \(b.label)")
                    .font(.system(size: 13))
                    .foregroundColor(here ? Theme.ok : Theme.dim)
                if !here {
                    Text(b.note).font(.system(size: 11)).foregroundColor(Theme.faint)
                }
                if busy {
                    ProgressBar(done: installer.state.done, total: installer.state.total)
                    Text("\(Fmt.mb(installer.state.done)) / \(Fmt.mb(installer.state.total)) MB  \(Fmt.speed(installer.state.bytesPerSec))")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.faint)
                }
            }
            Spacer()
            if busy {
                Button("取消") { installer.cancel() }.buttonStyle(.bordered)
            } else if here {
                Button("删除") {
                    installer.delete(b)
                    onRescan()
                }
                .buttonStyle(.bordered)
            } else {
                Button("下载") {
                    Task {
                        await installer.install(b)
                        onRescan()
                    }
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Port of LoadingPanel().
struct LoadingPanelView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("启动中").sectionStyle()
            Card {
                Text("正在加载模型…").font(.system(size: 15)).foregroundColor(Theme.fg)
                Text("首次加载需几秒，之后常驻内存。")
                    .font(.system(size: 12)).foregroundColor(Theme.dim)
            }
        }
        .padding(.horizontal, 16)
    }
}
