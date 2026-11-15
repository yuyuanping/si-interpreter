import SwiftUI

// Color palette ported from the Android Compose theme (sRGB hex values identical).
enum Theme {
    static let bg = Color(red: 16 / 255, green: 20 / 255, blue: 24 / 255)
    static let fg = Color(red: 230 / 255, green: 234 / 255, blue: 240 / 255)
    static let dim = Color(red: 143 / 255, green: 163 / 255, blue: 192 / 255)
    static let faint = Color(red: 92 / 255, green: 107 / 255, blue: 132 / 255)
    static let cell = Color(red: 22 / 255, green: 28 / 255, blue: 38 / 255)
    static let cell2 = Color(red: 27 / 255, green: 34 / 255, blue: 48 / 255)
    static let accent = Color(red: 44 / 255, green: 107 / 255, blue: 237 / 255)
    static let ok = Color(red: 127 / 255, green: 227 / 255, blue: 155 / 255)
    static let warn = Color(red: 255 / 255, green: 196 / 255, blue: 77 / 255)
    static let bad = Color(red: 255 / 255, green: 154 / 255, blue: 140 / 255)
    static let live = Color(red: 207 / 255, green: 224 / 255, blue: 255 / 255)
}

extension View {
    func sectionStyle() -> some View {
        font(.system(size: 15, weight: .bold))
            .foregroundColor(Theme.fg)
            .padding(.top, 6)
            .padding(.bottom, 8)
    }
}

struct Card<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .cellBackground(Theme.cell, cornerRadius: 12)
    }
}

struct Metric: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 17, weight: .bold))
                .foregroundColor(Theme.ok)
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(Theme.faint)
        }
    }
}

struct LangChip: View {
    let text: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Text(text)
            .font(.system(size: 14))
            .foregroundColor(Theme.fg)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .cellBackground(selected ? Theme.accent : Theme.cell2, cornerRadius: 20)
            .onTapGesture(perform: action)
    }
}

struct ProgressBar: View {
    let done: Int64
    let total: Int64

    var body: some View {
        let f: CGFloat = total > 0 ? CGFloat(done) / CGFloat(total) : 0
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(Theme.cell2)
                Rectangle().fill(Theme.accent).frame(width: geo.size.width * min(max(f, 0), 1))
            }
        }
        .frame(height: 6)
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}

struct UtteranceRow: View {
    let u: Utterance

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(u.sourceText)
                .font(.system(size: 14))
                .foregroundColor(Theme.dim)
            if u.pending {
                Text("翻译中…")
                    .font(.system(size: 16))
                    .foregroundColor(Theme.warn)
            } else {
                Text(u.translated)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundColor(Theme.fg)
                Text("↳ \(Fmt.latency(u.latencyMs))")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.faint)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 5)
        .padding(12)
        .cellBackground(Theme.cell, cornerRadius: 10)
    }
}

extension View {
    /// filled rounded background — named to stay unambiguous against SwiftUI's own
    /// background overloads
    func cellBackground(_ color: Color, cornerRadius: CGFloat) -> some View {
        background(RoundedRectangle(cornerRadius: cornerRadius).fill(color))
    }
}
