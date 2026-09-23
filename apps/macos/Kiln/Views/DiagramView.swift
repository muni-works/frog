import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Canvas

/// Draws a laid-out diagram at its natural size (in points). Nodes are live views (hover for
/// the detail, click a file-linked node to open it); edges draw on as it appears, layer by layer.
struct DiagramCanvas: View {
    let diagram: Diagram
    /// Called for a click on a node; file-linked nodes open in the editor by default.
    var onNode: ((Diagram.Node) -> Void)?
    /// Skip the entrance animation (exports, thumbnails).
    var animated = true
    @Environment(\.projectFolder) private var folder
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.diagramStatic) private var isStatic
    @State private var shown = false
    @State private var hovered: String?

    var body: some View {
        if let layout = diagram.layout {
            ZStack(alignment: .topLeading) {
                ForEach(layout.groups ?? [], id: \.id) { g in groupFrame(g) }
                if diagram.isSequence, let end = layout.lifelineEnd {
                    ForEach(layout.nodes, id: \.id) { b in
                        Path { p in
                            p.move(to: CGPoint(x: b.x + b.w / 2, y: b.y + b.h))
                            p.addLine(to: CGPoint(x: b.x + b.w / 2, y: end))
                        }
                        .stroke(.secondary.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    }
                }
                ForEach(Array(layout.edges.enumerated()), id: \.offset) { _, path in edge(path, layout) }
                ForEach(layout.nodes, id: \.id) { b in
                    if let node = diagram.node(b.id) { nodeView(node, b) }
                }
                ForEach(Array(layout.edges.enumerated()), id: \.offset) { _, path in edgeLabel(path) }
            }
            .frame(width: layout.width, height: layout.height, alignment: .topLeading)
            .onAppear {
                if !animated || reduceMotion || isStatic { shown = true; return }
                withAnimation(.easeOut(duration: 0.6)) { shown = true }
            }
        }
    }

    /// Fully drawn: after the entrance, or from the start when static.
    private var on: Bool { shown || isStatic || !animated }

    private var dense: Bool { diagram.edges.count > diagram.nodes.count * 3 / 2 && diagram.edges.count > 16 }

    private var maxRank: Int { diagram.layout?.nodes.map(\.rank).max() ?? 0 }

    /// Stagger by layer: earlier layers land first.
    private func delay(_ rank: Int) -> Double { animated && !reduceMotion && !isStatic ? Double(rank) * 0.07 : 0 }

    // Groups

    private func groupFrame(_ g: Diagram.Layout.GroupBox) -> some View {
        let label = diagram.groups?.first { $0.id == g.id }?.label ?? g.id
        return RoundedRectangle(cornerRadius: 14)
            .fill(.primary.opacity(0.03))
            .strokeBorder(.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            .overlay(alignment: .topLeading) {
                Text(label.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 12)
                    .padding(.top, 8)
            }
            .frame(width: g.w, height: g.h)
            .offset(x: g.x, y: g.y)
            .opacity(on ? 1 : 0)
    }

    // Edges

    private func style(_ i: Int) -> Diagram.EdgeStyle { diagram.edges[safe: i]?.style ?? .solid }

    private func isHot(_ i: Int) -> Bool {
        guard let h = hovered, let e = diagram.edges[safe: i] else { return false }
        return e.from == h || e.to == h
    }

    private func edge(_ path: Diagram.Layout.EdgePath, _ layout: Diagram.Layout) -> some View {
        let pts = path.cgPoints
        let s = style(path.edge)
        let hot = isHot(path.edge)
        // Dense diagrams (code maps) draw edges faintly; hovering a node brings its own forward.
        let faint = dense && !hot
        let color: Color = hot ? .accentColor : faint ? .secondary.opacity(0.28) : (s == .thick ? .primary.opacity(0.75) : .secondary)
        let width: CGFloat = s == .thick ? 2.4 : (hot ? 1.8 : 1.3)
        let from = diagram.edges[safe: path.edge].flatMap { e in layout.nodes.first { $0.id == e.from } }
        return ZStack {
            EdgeShape(points: pts)
                .trim(from: 0, to: on ? 1 : 0)
                .stroke(color, style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round, dash: s == .dashed ? [5, 4] : []))
            if let end = pts.last, let prev = pts.dropLast().last {
                Arrowhead(tip: end, from: prev)
                    .fill(color)
                    .opacity(on ? 1 : 0)
            }
        }
        .frame(width: layout.width, height: layout.height, alignment: .topLeading)
        .animation(.easeOut(duration: 0.5).delay(delay(from?.rank ?? 0) + 0.12), value: shown)
        .animation(.easeOut(duration: 0.15), value: hot)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func edgeLabel(_ path: Diagram.Layout.EdgePath) -> some View {
        if let at = path.labelAt, let text = diagram.edges[safe: path.edge]?.label {
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(isHot(path.edge) ? .primary : .secondary)
                .lineLimit(1)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color(nsColor: .windowBackgroundColor).opacity(0.92), in: .capsule)
                .fixedSize()
                .position(x: at[0], y: at[1])
                .opacity(on ? 1 : 0)
                .animation(.easeOut(duration: 0.3).delay(delay(maxRank) + 0.2), value: shown)
                .allowsHitTesting(false)
        }
    }

    // Nodes

    private func nodeView(_ node: Diagram.Node, _ b: Diagram.Layout.NodeBox) -> some View {
        let hot = hovered == node.id
        let shape = node.shape ?? .box
        let heat = node.heat ?? 0
        return NodeBody(node: node, hot: hot)
            .frame(width: b.w, height: b.h)
            .background { NodeShape(shape: shape).fill(fill(shape, hot)) }
            // Activity: a warm wash and edge, stronger for hotter nodes.
            .background { if heat > 0 { NodeShape(shape: shape).fill(.orange.opacity(0.06 + 0.22 * heat)) } }
            .overlay { if heat > 0.5 { NodeShape(shape: shape).stroke(.orange.opacity(0.35 + 0.4 * heat), lineWidth: 1.2) } }
            .overlay {
                NodeShape(shape: shape)
                    .stroke(hot ? Color.accentColor : .primary.opacity(0.22),
                            style: StrokeStyle(lineWidth: hot ? 1.6 : 1, dash: shape == .external ? [4, 3] : []))
            }
            .contentShape(NodeShape(shape: shape))
            .scaleEffect(on ? 1 : 0.92)
            .opacity(on ? (dense && hovered != nil && !related(node.id) ? 0.35 : 1) : 0)
            .animation(.spring(duration: 0.45, bounce: 0.25).delay(delay(b.rank)), value: shown)
            .position(x: b.x + b.w / 2, y: b.y + b.h / 2)
            .onHover { inside in
                withAnimation(.easeOut(duration: 0.12)) { hovered = inside ? node.id : (hovered == node.id ? nil : hovered) }
            }
            .onTapGesture { tap(node) }
            .help(node.detail ?? node.file.map { "Open \($0)" } ?? node.label)
            .pointerStyle(node.file != nil || onNode != nil ? .link : nil)
    }

    /// The hovered node and its direct neighbors.
    private func related(_ id: String) -> Bool {
        guard let h = hovered else { return true }
        return id == h || diagram.edges.contains { ($0.from == h && $0.to == id) || ($0.to == h && $0.from == id) }
    }

    private func fill(_ shape: Diagram.Shape, _ hot: Bool) -> Color {
        let base: Color = switch shape {
        case .store: .blue.opacity(0.10)
        case .actor: .orange.opacity(0.10)
        case .decision: .purple.opacity(0.10)
        case .external: .primary.opacity(0.03)
        default: .primary.opacity(0.06)
        }
        return hot ? base.opacity(2) : base
    }

    private func tap(_ node: Diagram.Node) {
        if let onNode { return onNode(node) }
        guard let file = node.file else { return }
        let url = file.hasPrefix("/") ? URL(fileURLWithPath: file)
            : (folder ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).appending(path: file)
        Editor.open([url])
    }
}

private struct NodeBody: View {
    let node: Diagram.Node
    let hot: Bool

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 5) {
                if node.shape == .actor {
                    Image(systemName: "person.fill").font(.system(size: 11)).foregroundStyle(.orange)
                }
                if node.shape == .external {
                    Image(systemName: "arrow.up.forward.square").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Text(node.label)
                    .font(.system(size: 13, weight: .medium))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .minimumScaleFactor(0.85)
            }
            // The file, unless the label already says it (code maps label nodes by file).
            if let file = node.file, !node.label.hasSuffix((file as NSString).lastPathComponent) || node.line != nil {
                Text((file as NSString).lastPathComponent + (node.line.map { ":\($0)" } ?? ""))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(hot ? Color.accentColor : .secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, node.shape == .store ? 8 : 0)
    }
}

/// Node outlines by shape.
struct NodeShape: Shape {
    let shape: Diagram.Shape

    func path(in r: CGRect) -> Path {
        switch shape {
        case .rounded, .actor:
            // A true capsule when short: continuous corners at half the height overshoot.
            return r.height <= 36 ? Capsule(style: .circular).path(in: r) : Path(roundedRect: r, cornerRadius: 18, style: .continuous)
        case .decision:
            var p = Path()
            p.move(to: CGPoint(x: r.midX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.midY))
            p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX, y: r.midY))
            p.closeSubpath()
            return p
        case .store:
            // A cylinder: body plus the top ellipse's front rim.
            let e: CGFloat = 7
            var p = Path()
            p.move(to: CGPoint(x: r.minX, y: r.minY + e))
            p.addLine(to: CGPoint(x: r.minX, y: r.maxY - e))
            p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.maxY - e), control: CGPoint(x: r.midX, y: r.maxY + e))
            p.addLine(to: CGPoint(x: r.maxX, y: r.minY + e))
            p.addQuadCurve(to: CGPoint(x: r.minX, y: r.minY + e), control: CGPoint(x: r.midX, y: r.minY - e))
            p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY + e), control: CGPoint(x: r.midX, y: r.minY + 3 * e))
            return p
        default:
            return Path(roundedRect: r, cornerRadius: 8)
        }
    }
}

/// A polyline with softened bends: each corner becomes a quadratic curve.
struct EdgeShape: Shape {
    let points: [CGPoint]

    func path(in _: CGRect) -> Path {
        var p = Path()
        guard let first = points.first else { return p }
        p.move(to: first)
        guard points.count > 2 else {
            if let last = points.last { p.addLine(to: last) }
            return p
        }
        for i in 1..<points.count - 1 {
            let (a, b, c) = (points[i - 1], points[i], points[i + 1])
            let r = min(18, hypot(b.x - a.x, b.y - a.y) / 2, hypot(c.x - b.x, c.y - b.y) / 2)
            let inPt = along(b, a, r), outPt = along(b, c, r)
            p.addLine(to: inPt)
            p.addQuadCurve(to: outPt, control: b)
        }
        p.addLine(to: points[points.count - 1])
        return p
    }

    private func along(_ from: CGPoint, _ to: CGPoint, _ d: CGFloat) -> CGPoint {
        let len = max(hypot(to.x - from.x, to.y - from.y), 0.001)
        return CGPoint(x: from.x + (to.x - from.x) * d / len, y: from.y + (to.y - from.y) * d / len)
    }
}

struct Arrowhead: Shape {
    let tip: CGPoint
    let from: CGPoint

    func path(in _: CGRect) -> Path {
        let angle = atan2(tip.y - from.y, tip.x - from.x)
        let len: CGFloat = 9, spread: CGFloat = 0.42
        var p = Path()
        p.move(to: tip)
        p.addLine(to: CGPoint(x: tip.x - len * cos(angle - spread), y: tip.y - len * sin(angle - spread)))
        p.addLine(to: CGPoint(x: tip.x - len * cos(angle + spread), y: tip.y - len * sin(angle + spread)))
        p.closeSubpath()
        return p
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

extension EnvironmentValues {
    /// Draw diagrams in their final state with no entrance animation (exports, snapshots).
    @Entry var diagramStatic = false
}

// MARK: - Card

/// A diagram in the transcript: title bar with actions, the canvas scaled to fit the column.
struct DiagramCard: View {
    let diagram: Diagram
    var source: String?
    @Environment(\.openWindow) private var openWindow
    @Environment(\.projectFolder) private var folder
    @State private var showSource = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.5)
            if showSource, let src = source ?? diagram.mermaid {
                ScrollView(.horizontal) {
                    Text(src)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(12)
                        .fixedSize()
                }
            } else {
                FittedDiagram(diagram: diagram, maxHeight: 520)
                    .padding(8)
                if diagram.hasHeat { HeatLegend().padding([.horizontal, .bottom], 12) }
            }
        }
        .background(.quaternary.opacity(0.25), in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.quaternary, lineWidth: 0.5))
        .contextMenu { DiagramExportMenu(diagram: diagram) }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: diagram.isSequence ? "arrow.left.arrow.right" : "point.3.connected.trianglepath.dotted")
                .foregroundStyle(.secondary)
            Text(diagram.displayTitle).font(.callout.weight(.semibold))
            Spacer()
            if source != nil || diagram.mermaid != nil {
                Button(showSource ? "Diagram" : "Source") { withAnimation(.snappy) { showSource.toggle() } }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
            Menu {
                DiagramExportMenu(diagram: diagram)
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Export")
            Button {
                openWindow(value: DiagramDocument(diagram: diagram, folder: folder))
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(.borderless)
            .help("Open in its own window")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// Scales the canvas down to the available width (never up), scrolling if still too tall.
struct FittedDiagram: View {
    let diagram: Diagram
    var maxHeight: CGFloat = .infinity
    var onNode: ((Diagram.Node) -> Void)?
    @State private var width: CGFloat = 600

    var body: some View {
        let w = diagram.layout?.width ?? 1
        let h = diagram.layout?.height ?? 1
        let scale = min(1, width / w)
        DiagramCanvas(diagram: diagram, onNode: onNode)
            .scaleEffect(scale, anchor: .topLeading)
            .frame(width: w * scale, height: h * scale, alignment: .topLeading)
            .frame(maxWidth: .infinity)
            .frame(maxHeight: min(h * scale, maxHeight))
            .clipped()
            .onGeometryChange(for: CGFloat.self, of: \.size.width) { width = $0 }
    }
}

/// Explains the warm tint on code maps.
struct HeatLegend: View {
    var body: some View {
        HStack(spacing: 6) {
            LinearGradient(colors: [.orange.opacity(0.08), .orange.opacity(0.6)], startPoint: .leading, endPoint: .trailing)
                .frame(width: 40, height: 8)
                .clipShape(.capsule)
            Text("warmer = more commits in the last 90 days")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Export

struct DiagramExportMenu: View {
    let diagram: Diagram

    var body: some View {
        Button("Copy Image", systemImage: "photo") {
            guard let image = DiagramExport.image(diagram) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([image])
        }
        if let mermaid = diagram.mermaid {
            Button("Copy Mermaid", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(mermaid, forType: .string)
            }
        }
        Divider()
        Button("Save as PNG…") { DiagramExport.save(diagram, as: .png) }
        Button("Save as SVG…") { DiagramExport.save(diagram, as: .svg) }
        if diagram.mermaid != nil {
            Button("Save as Mermaid…") { DiagramExport.save(diagram, as: .mermaid) }
        }
    }
}

@MainActor
enum DiagramExport {
    enum Format { case png, svg, mermaid }

    static func image(_ d: Diagram, scale: CGFloat = 2) -> NSImage? {
        let view = DiagramCanvas(diagram: d, animated: false)
            .padding(8)
            .background(Color(nsColor: .windowBackgroundColor))
        let r = ImageRenderer(content: view)
        r.scale = scale
        return r.nsImage
    }

    static func save(_ d: Diagram, as format: Format) {
        let panel = NSSavePanel()
        let base = d.displayTitle.replacingOccurrences(of: "/", with: "-")
        switch format {
        case .png:
            panel.allowedContentTypes = [.png]
            panel.nameFieldStringValue = base + ".png"
        case .svg:
            panel.allowedContentTypes = [.svg]
            panel.nameFieldStringValue = base + ".svg"
        case .mermaid:
            panel.nameFieldStringValue = base + ".mmd"
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        switch format {
        case .png:
            guard let tiff = image(d)?.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
            try? png.write(to: url)
        case .svg:
            try? svg(d).write(to: url, atomically: true, encoding: .utf8)
        case .mermaid:
            try? (d.mermaid ?? "").write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// A standalone SVG of the laid-out diagram (light theme, system font).
    static func svg(_ d: Diagram) -> String {
        guard let l = d.layout else { return "" }
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        func f(_ v: Double) -> String { String(format: "%.1f", v) }
        var out = """
        <svg xmlns="http://www.w3.org/2000/svg" width="\(f(l.width))" height="\(f(l.height))" viewBox="0 0 \(f(l.width)) \(f(l.height))" font-family="-apple-system, Helvetica, sans-serif">
        <defs><marker id="a" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="8" markerHeight="8" orient="auto-start-reverse"><path d="M0,0 L10,5 L0,10 z" fill="#666"/></marker></defs>
        <rect width="100%" height="100%" fill="#ffffff"/>

        """
        for g in l.groups ?? [] {
            let label = d.groups?.first { $0.id == g.id }?.label ?? g.id
            out += "<rect x=\"\(f(g.x))\" y=\"\(f(g.y))\" width=\"\(f(g.w))\" height=\"\(f(g.h))\" rx=\"14\" fill=\"#f6f6f8\" stroke=\"#aaa\" stroke-dasharray=\"5 4\"/>\n"
            out += "<text x=\"\(f(g.x + 12))\" y=\"\(f(g.y + 18))\" font-size=\"10\" font-weight=\"600\" fill=\"#888\">\(esc(label.uppercased()))</text>\n"
        }
        if d.isSequence, let end = l.lifelineEnd {
            for b in l.nodes {
                out += "<line x1=\"\(f(b.x + b.w / 2))\" y1=\"\(f(b.y + b.h))\" x2=\"\(f(b.x + b.w / 2))\" y2=\"\(f(end))\" stroke=\"#bbb\" stroke-dasharray=\"4 4\"/>\n"
            }
        }
        for p in l.edges {
            let e = d.edges[safe: p.edge]
            let pts = p.points.map { "\(f($0[0])),\(f($0[1]))" }.joined(separator: " ")
            let dash = e?.style == .dashed ? " stroke-dasharray=\"5 4\"" : ""
            let w = e?.style == .thick ? "2.4" : "1.3"
            out += "<polyline points=\"\(pts)\" fill=\"none\" stroke=\"#666\" stroke-width=\"\(w)\"\(dash) marker-end=\"url(#a)\"/>\n"
            if let at = p.labelAt, let label = e?.label {
                out += "<text x=\"\(f(at[0]))\" y=\"\(f(at[1] + 4))\" font-size=\"11\" text-anchor=\"middle\" fill=\"#555\" paint-order=\"stroke\" stroke=\"#fff\" stroke-width=\"4\">\(esc(label))</text>\n"
            }
        }
        for b in l.nodes {
            guard let n = d.node(b.id) else { continue }
            let rx = (n.shape == .rounded || n.shape == .actor) ? min(b.h / 2, 18) : 8
            let dash = n.shape == .external ? " stroke-dasharray=\"4 3\"" : ""
            if n.shape == .decision {
                let pts = "\(f(b.x + b.w / 2)),\(f(b.y)) \(f(b.x + b.w)),\(f(b.y + b.h / 2)) \(f(b.x + b.w / 2)),\(f(b.y + b.h)) \(f(b.x)),\(f(b.y + b.h / 2))"
                out += "<polygon points=\"\(pts)\" fill=\"#f3eefb\" stroke=\"#999\"/>\n"
            } else {
                let fill = n.shape == .store ? "#eaf1fb" : (n.shape == .actor ? "#fdf1e6" : "#f4f4f6")
                out += "<rect x=\"\(f(b.x))\" y=\"\(f(b.y))\" width=\"\(f(b.w))\" height=\"\(f(b.h))\" rx=\"\(f(rx))\" fill=\"\(fill)\" stroke=\"#999\"\(dash)/>\n"
            }
            let lines = n.label.split(separator: " ").reduce(into: [String]()) { acc, word in
                if let last = acc.last, last.count + word.count + 1 <= 24 { acc[acc.count - 1] = last + " " + word } else { acc.append(String(word)) }
            }.prefix(3)
            let top = b.y + b.h / 2 - Double(lines.count - 1) * 8 - (n.file != nil ? 6 : 0) + 4
            for (i, line) in lines.enumerated() {
                out += "<text x=\"\(f(b.x + b.w / 2))\" y=\"\(f(top + Double(i) * 16))\" font-size=\"13\" font-weight=\"500\" text-anchor=\"middle\" fill=\"#222\">\(esc(line))</text>\n"
            }
            if let file = n.file {
                out += "<text x=\"\(f(b.x + b.w / 2))\" y=\"\(f(top + Double(lines.count) * 16))\" font-size=\"10\" font-family=\"Menlo, monospace\" text-anchor=\"middle\" fill=\"#888\">\(esc((file as NSString).lastPathComponent))</text>\n"
            }
        }
        out += "</svg>\n"
        return out
    }
}

// MARK: - Window

/// A diagram in its own window (pop-out from a card), with zoom.
struct DiagramDocument: Codable, Hashable {
    var diagram: Diagram
    var folder: URL?
}

struct DiagramWindow: View {
    let document: DiagramDocument
    @State private var zoom: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1

    var body: some View {
        let d = document.diagram
        ScrollView([.horizontal, .vertical]) {
            let z = zoom * pinch
            DiagramCanvas(diagram: d)
                .scaleEffect(z, anchor: .topLeading)
                .frame(width: (d.layout?.width ?? 0) * z, height: (d.layout?.height ?? 0) * z, alignment: .topLeading)
                .padding(24)
        }
        .gesture(MagnifyGesture().updating($pinch) { v, s, _ in s = v.magnification }.onEnded { zoom = min(4, max(0.25, zoom * $0.magnification)) })
        .overlay(alignment: .bottomLeading) {
            if d.hasHeat { HeatLegend().padding(10).glassEffect(.regular, in: .capsule).padding(14) }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.projectFolder, document.folder)
        .navigationTitle(d.displayTitle)
        .toolbar {
            ToolbarItemGroup {
                Button("Zoom Out", systemImage: "minus.magnifyingglass") { zoom = max(0.25, zoom / 1.25) }
                    .keyboardShortcut("-")
                Button("Actual Size", systemImage: "1.magnifyingglass") { zoom = 1 }
                    .keyboardShortcut("0")
                Button("Zoom In", systemImage: "plus.magnifyingglass") { zoom = min(4, zoom * 1.25) }
                    .keyboardShortcut("=")
                Menu("Export", systemImage: "square.and.arrow.up") { DiagramExportMenu(diagram: d) }
            }
        }
        .frame(minWidth: 480, minHeight: 360)
    }
}

// MARK: - Mermaid in answers

/// A ```mermaid block, drawn natively (laid out by the engine); falls back to the code.
struct MermaidBlock: View {
    let code: String
    @Environment(\.projectFolder) private var folder
    @State private var diagram: Diagram?
    @State private var failed = false

    var body: some View {
        Group {
            if let diagram {
                DiagramCard(diagram: diagram, source: code)
            } else if failed {
                CodeBlock(language: "mermaid", code: code)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Drawing diagram…").font(.callout).foregroundStyle(.secondary)
                }
                .padding(12)
            }
        }
        .task(id: code) {
            let d = await Diagram.fromMermaid(code, cwd: folder ?? FileManager.default.homeDirectoryForCurrentUser)
            diagram = d
            failed = d == nil
        }
    }
}
