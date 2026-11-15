import SwiftUI
import XCTest
@testable import Frog

/// Parity shots for the model picker and Settings › Models (docs/design/parity/models-*.png),
/// from the same fixture the web's parity page draws (docs/design/parity/models-fixture.json):
/// This Mac idle with Qwen3-8B on disk, mew running Qwen3-4B with Qwen3-8B on disk too.
/// Writes to $FROG_PARITY_OUT when set, else a temp folder.
@MainActor
final class ModelsParityTests: XCTestCase {
    static func fixture() -> [Device] {
        var mac = Device(id: "this-mac", role: .thisMac, name: "studio")
        mac.symbol = "desktopcomputer"; mac.chip = "M4 Max"; mac.kind = "metal"; mac.unified = true
        mac.totalBytes = 64 << 30; mac.freeBytes = 40 << 30; mac.online = true
        mac.models = [.init(name: "Qwen3-8B-4bit", weightsHash: "aaaaaaaaaaaa11", quant: "mlx-4bit", loaded: false)]
        var mew = Device(id: "n1", role: .node, name: "mew")
        mew.chip = "RTX 3090"; mew.kind = "cuda"; mew.unified = false
        mew.totalBytes = 24 << 30; mew.freeBytes = 6 << 30; mew.online = true; mew.paired = true; mew.keyed = true
        mew.model = "Qwen3-4B"; mew.decode = 58.4
        mew.models = [.init(name: "Qwen3-4B", weightsHash: "bbbbbbbbbbbb22", quant: "bf16", loaded: true),
                      .init(name: "Qwen3-8B-4bit", weightsHash: "aaaaaaaaaaaa11", quant: "mlx-4bit", loaded: false)]
        return [mac, mew]
    }

    func testParityShots() throws {
        let devices = Devices()
        devices.seed(Self.fixture())
        let rows = devices.machineModels()
        XCTAssertEqual(rows.map(\.places), ["mew", "This Mac, mew"])
        XCTAssertEqual(rows.map(\.tag), [nil, "loads"])

        let cloud: [MachineMenuRow.Content] = [
            .init(name: "DeepSeek V4.1 Flash", detail: "$0.40/M out", tag: nil, cloud: true, spinning: false),
            .init(name: "GLM-5.3 Flash", detail: "$0.80/M out", tag: nil, cloud: true, spinning: false),
            .init(name: "Qwen3 Coder Next", detail: "$1.20/M out", tag: nil, cloud: true, spinning: false),
        ]
        let machine = rows.map { MachineMenuRow.Content(name: $0.name, detail: $0.places, tag: $0.tag, cloud: false, spinning: false) }
        try render("models-picker", width: 320, height: 300) {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    header("Your machines")
                    ForEach(machine, id: \.name) { MachineMenuRow(content: $0, current: $0.name == "Qwen3-4B").padding(.horizontal, 8).padding(.vertical, 6) }
                    header("Frog Cloud")
                    ForEach(cloud, id: \.name) { MachineMenuRow(content: $0).padding(.horizontal, 8).padding(.vertical, 6) }
                }
                .padding(6)
                Divider()
                Text("Manage…").frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8).padding(.vertical, 6).padding(6)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        try render("models-settings", width: 620, height: 560) { MachinesSettings(devices: devices, fixtureAccount: ("Cam · cam@example.com", "$12.34")) }
        try render("models-machine", width: 620, height: 560) { MachinesSettings(devices: devices, path: ["n1"], fixtureAccount: ("Cam · cam@example.com", "$12.34")) }
    }

    private func header(_ title: String) -> some View {
        Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            .padding(.horizontal, 8).padding(.top, 10).padding(.bottom, 4)
    }

    private func render<V: View>(_ name: String, width: CGFloat, height: CGFloat, @ViewBuilder _ view: () -> V) throws {
        let dir = ProcessInfo.processInfo.environment["FROG_PARITY_OUT"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appending(path: "frog-snapshots")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (suffix, look) in [("mac-dark", NSAppearance.Name.darkAqua), ("mac-light", .aqua)] {
            let host = NSHostingView(rootView: view().frame(width: width, height: height).background(FrogCanvas.color))
            host.frame = CGRect(x: 0, y: 0, width: width, height: height)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: look)
            window.contentView = host
            window.orderFront(nil)
            defer { window.close() }
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return XCTFail("no bitmap") }
            host.cacheDisplay(in: host.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: dir.appending(path: "\(name)-\(suffix).png"))
        }
    }
}
