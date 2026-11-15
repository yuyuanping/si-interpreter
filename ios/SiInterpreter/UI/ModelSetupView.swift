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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                installedList
                Text("方向").sectionStyle()
                Card {
                    HStack(spacing: 10) {
                        LangChip("英 → 中", selected: src == "en" && tgt == "zh") {
                            src = "en"; tgt = "zh"
                        }
                        LangChip("中 → 英", selected: src == "zh" && tgt == "en") {
                            src = "zh"; tgt = "en"
                        }
                    }
                    Text("每句按实测语言自动定向：说中文译成英文，说英文译成中文。上方选择仅在无法判定时生效。")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.dim)
                        .padding(.top, 8)

                    let mtEngine: String? = installed.contains(Bundles.mtGemma4E2B.id)
                        ? "谷歌 Gemma 4 E2B"
                        : (installed.contains(Bundles.mtHymt2.id) ? "腾讯混元 Hy-MT2" : nil)
                    Text(mtEngine != nil
                         ? "翻译引擎已就绪：\(mtEngine!)，纯本地推理。"
                         : "安装下方翻译模型后即可离线翻译；未安装时译文处显示占位标记。")
                        .font(.system(size: 12))
                        .foregroundColor(mtEngine != nil ? Theme.ok : Theme.warn)
                        .padding(.top, 8)
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

    @ViewBuilder
    private var installedList: some View {
        Text("已安装").sectionStyle()
        Card {
            if installed.isEmpty {
                Text("（无）").font(.system(size: 13)).foregroundColor(Theme.faint)
            } else {
                ForEach(installed, id: \.self) { id in
                    let label = Bundles.byId(id)?.label ?? id
                    Text("✓  \(label)")
                        .font(.system(size: 13))
                        .foregroundColor(Theme.ok)
                }
            }
        }
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
