import SwiftUI

// The sidebar's shared pieces, drawn as the web draws them (web home canvas, Final page):
// starters while the list is empty, and the foot (one status pill, the account row, the legal row).

/// One first session a click away. Costs are what a run typically spends at Frog Cloud's
/// per-token prices.
struct SidebarStarter: Identifiable {
    var id: String { title }
    let title: String
    let detail: String
    let prompt: String
}

enum SidebarStarters {
    static let all: [SidebarStarter] = [
        .init(title: "Make a tiny pomodoro timer", detail: "About a minute   about 4¢", prompt: "Make a tiny pomodoro timer"),
        .init(title: "Build a Markdown notes app", detail: "About two minutes   about 9¢", prompt: "Build a Markdown notes app that saves locally"),
        .init(title: "Write a CLI that renames photos", detail: "About a minute   about 5¢", prompt: "Write a CLI that renames photos by date taken"),
    ]
}

struct SidebarStartersView: View {
    let start: (SidebarStarter) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Start with one of these")
                .font(.frog(size: 11.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8).padding(.top, 14).padding(.bottom, 4)
            ForEach(SidebarStarters.all) { s in
                Button { start(s) } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(s.title).font(.frog(size: 13)).lineLimit(1)
                        Text(s.detail).font(.frog(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .contentShape(.rect)
                    .hoverPlate(h: 0, v: 0, radius: 8)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// The foot's one capsule: a dot, one line, a small action. Nothing to say, no pill.
struct SidebarPill: View {
    enum Dot { case go, wait, update }
    let dot: Dot
    let lead: String
    var rest: String? = nil
    let action: String
    let perform: () -> Void

    var body: some View {
        Button(action: perform) {
            HStack(spacing: 8) {
                Circle().fill(color).frame(width: 6, height: 6)
                (Text(lead).fontWeight(.semibold).foregroundStyle(.primary)
                 + Text(rest.map { "  \($0)" } ?? "").foregroundStyle(.secondary))
                    .font(.frog(size: 12)).lineLimit(1)
                Spacer(minLength: 4)
                Text(action).font(.frog(size: 11, weight: .semibold))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Tokens.hover, in: .capsule)
            }
            .padding(.leading, 12).padding(.trailing, 6)
            .frame(height: 36)
            .overlay(Capsule().strokeBorder(Tokens.lineStrong, lineWidth: 1))
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
    }

    private var color: Color {
        switch dot {
        case .go: Color.frog
        case .wait: .orange
        case .update: .primary
        }
    }
}

/// Pricing, Privacy, Terms, and the muni mark: always at the very bottom, above a hairline.
struct SidebarLegalRow: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Tokens.line).frame(height: 1)
            HStack(spacing: 12) {
                link("Pricing", "https://frog.toys/pricing")
                link("Privacy", "https://frog.toys/privacy")
                link("Terms", "https://frog.toys/terms")
                Spacer(minLength: 4)
                Button { openURL(URL(string: "https://muni.works")!) } label: {
                    MuniMark().stroke(style: .init(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                        .frame(width: 34, height: 15)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Municipal Robotics")
            }
            .padding(.horizontal, 8).padding(.top, 9).padding(.bottom, 2)
        }
    }

    private func link(_ title: String, _ url: String) -> some View {
        Button(title) { openURL(URL(string: url)!) }
            .buttonStyle(.plain)
            .font(.frog(size: 11))
            .foregroundStyle(.tertiary)
    }
}

/// The muni wordmark, as the web draws it (`Muni` in the web's Pond.tsx): a stroke path on an
/// 880 × 400 box from (-60, -60), with the i's dot drawn as a short stroke.
struct MuniMark: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 880, sy = rect.height / 400, s = min(sx, sy)
        let ox = rect.minX + (rect.width - 880 * s) / 2 + 60 * s
        let oy = rect.minY + (rect.height - 400 * s) / 2 + 60 * s
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: ox + x * s, y: oy + y * s) }
        var path = Path()
        path.move(to: p(20, 240)); path.addLine(to: p(20, 100))
        path.addCurve(to: p(100, 50), control1: p(20, 50), control2: p(80, 50))
        path.addCurve(to: p(160, 100), control1: p(140, 50), control2: p(160, 70))
        path.move(to: p(160, 240)); path.addLine(to: p(160, 100))
        path.addCurve(to: p(240, 50), control1: p(160, 50), control2: p(220, 50))
        path.addCurve(to: p(300, 100), control1: p(280, 50), control2: p(300, 70))
        path.addLine(to: p(300, 240))
        path.addCurve(to: p(370, 280), control1: p(300, 270), control2: p(330, 280))
        path.addCurve(to: p(440, 240), control1: p(410, 280), control2: p(440, 270))
        path.addLine(to: p(440, 100))
        path.addCurve(to: p(520, 50), control1: p(440, 50), control2: p(500, 50))
        path.addCurve(to: p(600, 100), control1: p(560, 50), control2: p(600, 70))
        path.addLine(to: p(600, 240))
        path.addCurve(to: p(670, 280), control1: p(600, 270), control2: p(630, 280))
        path.addCurve(to: p(740, 240), control1: p(710, 280), control2: p(740, 270))
        path.addLine(to: p(740, 100))
        path.move(to: p(740, 28)); path.addLine(to: p(740, 32))
        return path
    }
}
