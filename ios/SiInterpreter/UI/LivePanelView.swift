import SwiftUI

/// Live interpretation screen. Port of LivePanel() from MainActivity.kt, including the
/// tail-follow fix: the scroll fires on what the tail SHOWS (a turn appended as pending,
/// and its translation filling in later in place), not on history.size.
struct LivePanelView: View {
    @ObservedObject var engine: InterpreterEngine
    let onStop: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            metrics
            if case .error(let msg) = engine.state {
                Card { Text(msg).foregroundColor(Theme.bad) }
                    .padding(.bottom, 10)
            }
            liveBox
                .padding(.top, 10)
            historyList
                .padding(.top, 10)
            controls
                .padding(.top, 8)
        }
        .padding(.horizontal, 16)
    }

    private var metrics: some View {
        VStack(spacing: 6) {
            HStack {
                Metric(label: "译文延迟", value: Fmt.latency(engine.stats.translateMs))
                Spacer()
                Metric(label: "识别句数", value: "\(engine.stats.utterances)")
                Spacer()
                Metric(label: "丢弃", value: "\(engine.stats.dropped)")
                Spacer()
                Metric(label: "已听", value: String(format: "%.0fs", engine.stats.secondsHeard))
            }
            HStack {
                Metric(label: "当前电平", value: Fmt.db(engine.stats.levelDb))
                Spacer()
                Metric(label: "峰值电平", value: Fmt.db(engine.stats.peakDb))
                Spacer()
                Metric(label: "单帧耗时", value: "\(engine.stats.asrMs)ms")
                Spacer()
                Metric(label: "方向", value: "自动")
            }
        }
    }

    private var liveBox: some View {
        Text(liveText)
            .font(.system(size: 17))
            .foregroundColor(engine.live.isEmpty ? Theme.faint : Theme.live)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .cellBackground(Theme.cell2, cornerRadius: 12)
    }

    private var liveText: String {
        if !engine.live.isEmpty { return engine.live }
        if engine.state == .loading { return "模型加载中…" }
        return "聆听中… 说英语或中文"
    }

    private var historyList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(engine.history) { u in
                        UtteranceRow(u: u).id(u.id)
                    }
                }
            }
            .onChange(of: engine.history.last?.id) { _ in scrollToTail(proxy) }
            .onChange(of: engine.history.last?.translated) { _ in scrollToTail(proxy) }
        }
    }

    private func scrollToTail(_ proxy: ScrollViewProxy) {
        guard let last = engine.history.last else { return }
        withAnimation(.easeOut(duration: 0.15)) {
            proxy.scrollTo(last.id, anchor: .bottom)
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Button("切断") { engine.forceCut = true }
                .buttonStyle(.bordered)
            Button("清空") { engine.clear() }
                .buttonStyle(.bordered)
            Button("停止") { onStop() }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
        }
    }
}
