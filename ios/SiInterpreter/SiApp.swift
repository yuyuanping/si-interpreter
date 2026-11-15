import SwiftUI
import AVFAudio

/// Owns the engine so the pipeline survives the screen locking. iOS has no foreground
/// service; the `audio` background mode + the active AVAudioSession keep the capture
/// running while the screen is off — the equivalent continuity for a long talk.
@MainActor
final class Session: ObservableObject {
    @Published var engine: InterpreterEngine?
    @Published var running = false
    @Published var micGranted =
        AVAudioSession.sharedInstance().recordPermission == .granted

    let store = ModelStore()
    let installer = ModelInstaller()
    let config = PipelineConfig()

    /// bumped by the rescan button; a filesystem rescan is not observable by SwiftUI,
    /// so installed() is re-derived when this changes
    @Published var rescanKey = 0

    var installed: [String] { store.installed() }

    func requestMic() {
        let session = AVAudioSession.sharedInstance()
        if #available(iOS 17, *) {
            AVAudioApplication.requestRecordPermission { [weak self] granted in
                DispatchQueue.main.async {
                    self?.micGranted = granted
                    if granted { self?.start() }
                }
            }
        } else {
            session.requestRecordPermission { [weak self] granted in
                DispatchQueue.main.async {
                    self?.micGranted = granted
                    if granted { self?.start() }
                }
            }
        }
    }

    func start() {
        guard engine == nil else { return }
        guard micGranted else { requestMic(); return }
        guard let asrPaths = store.pathsAsr() else { return }

        // real on-device MT when a GGUF is present; the placeholder only marks turns
        // otherwise — it is never a silent fallback that pretends to translate
        let translator: Translator
        if let mt = store.pathsMt(preferred: config.mtBundleId) {
            translator = LlamaTranslator(paths: mt)
        } else {
            translator = PlaceholderTranslator()
        }

        let e = InterpreterEngine(
            config: config,
            asrPaths: asrPaths,
            vadPath: store.vadPath(),
            senseVoicePath: store.pathsSenseVoice(),
            translator: translator)
        engine = e
        running = true
        e.start()
    }

    func stop() {
        engine?.stop()
        engine = nil
        running = false
    }

    func rescan() { rescanKey += 1 }
}

@main
struct SiInterpreterApp: App {
    @StateObject private var session = Session()

    var body: some Scene {
        WindowGroup {
            RootView(session: session)
                .preferredColorScheme(.dark)
        }
    }
}

struct RootView: View {
    @ObservedObject var session: Session

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                Theme.bg.ignoresSafeArea()
                VStack(alignment: .leading, spacing: 0) {
                    if !session.micGranted {
                        Button("授予麦克风权限") { session.requestMic() }
                            .frame(maxWidth: .infinity)
                            .buttonStyle(.bordered)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 12)
                    }

                    if let engine = session.engine {
                        LivePanelView(engine: engine, onStop: { session.stop() })
                    } else if session.running {
                        LoadingPanelView()
                    } else if session.installed.isEmpty {
                        ModelSetupView(installer: session.installer,
                                       store: session.store,
                                       onRescan: { session.rescan() })
                    } else {
                        // rescanKey re-derives the filesystem check the UI cannot observe
                        IdlePanelView(session: session, installed: session.installed)
                            .id(session.rescanKey)
                    }
                    Spacer(minLength: 16)
                }
                .padding(.top, 8)
            }
            .navigationTitle("同声传译 · 全离线")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
