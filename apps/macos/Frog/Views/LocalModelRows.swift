import SwiftUI

/// A machine's models on its page: Frog's picks for it, everything already on it, and the rest
/// of what fits behind "More models" (`LocalModelList`). Every row says what the model is for,
/// how big it is against this machine, where it comes from, where it stands and what its button
/// does.
struct MachineModelsSections: View {
    let device: Device
    var devices: Devices
    /// Open "More models" (snapshots).
    var showMore = false
    /// A fixed clock and downloads (snapshots and tests).
    var fixedNow: Date? = nil
    var fixedDownloads: [String: LocalDownload]? = nil
    @State private var moreOpen = false
    @State private var downloads = ModelDownloads.shared
    /// Deadlines pass without a poll changing anything: the clock moves every few seconds.
    /// (Not a TimelineView: wrapping the sections would fold them into one Form group.)
    @State private var now = Date()

    var body: some View {
        let list = LocalModelList.build(device, pending: devices.pending, problems: devices.rowProblem,
                                        waitingSwap: Set(devices.waitingSwap.keys),
                                        downloads: fixedDownloads ?? macDownloads, now: fixedNow ?? now)
        content(list)
    }

    /// The clock, on the first section only (a modifier on the whole group runs once per section).
    private func ticking(_ v: some View) -> some View {
        v.onAppear { moreOpen = showMore }
            .task {
                guard fixedNow == nil else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(5))
                    now = Date()
                }
            }
    }

    @ViewBuilder private func content(_ list: LocalModelList) -> some View {
        let named = device.role == .thisMac ? "this Mac" : device.name
        ticking(Section {
            if !device.online {
                Text("Not answering.").foregroundStyle(Tokens.textTertiary)
            } else if list.recommended.isEmpty {
                Text("None of Frog's models fit in \(named)'s memory.").foregroundStyle(Tokens.textTertiary)
            }
            ForEach(list.recommended) { LocalModelRowView(row: $0, device: device, devices: devices) }
        } header: {
            Text("Recommended for \(named)")
        } footer: {
            if let note = list.cloudNote {
                Text(note).font(.frog(size: 11)).foregroundStyle(Tokens.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        })
        if !list.onMachine.isEmpty {
            Section("Also on \(named)") {
                ForEach(list.onMachine) { LocalModelRowView(row: $0, device: device, devices: devices) }
            }
        }
        if !list.more.isEmpty, device.online {
            Section {
                DisclosureGroup(isExpanded: $moreOpen) {
                    ForEach(list.more) { LocalModelRowView(row: $0, device: device, devices: devices) }
                } label: {
                    Text("More models").foregroundStyle(Tokens.textSecondary)
                    + Text("  \(list.more.count)").foregroundStyle(Tokens.textTertiary)
                }
            }
        }
    }

    /// This Mac's own downloads, by repo.
    private var macDownloads: [String: LocalDownload] {
        guard device.role == .thisMac else { return [:] }
        var out: [String: LocalDownload] = [:]
        for (repo, state) in downloads.states {
            switch state {
            case .downloading:
                let p = downloads.progress[repo]
                out[repo] = LocalDownload(done: UInt64(max(0, p?.done ?? 0)), total: UInt64(max(0, p?.total ?? 0)), rate: p?.rate)
            case .failed(let why):
                out[repo] = LocalDownload(done: 0, total: 0, failed: why)
            case .done:
                break
            }
        }
        return out
    }
}

/// One model: name and what it's for, size against the machine and where it's from, and the
/// one control its state calls for.
struct LocalModelRowView: View {
    let row: LocalModelRow
    let device: Device
    var devices: Devices
    @State private var info = false
    @State private var confirmDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(row.name).font(.frog(size: 13, weight: .medium))
                        Button { info = true } label: {
                            Image(systemName: "info.circle").foregroundStyle(Tokens.textTertiary)
                        }
                        .buttonStyle(.plain)
                        .help("Where it comes from, its format and what it needs")
                        .popover(isPresented: $info, arrowEdge: .trailing) { LocalModelInfo(row: row) }
                    }
                    Text(row.uses ?? "Not in Frog's catalog").font(.frog(size: 11)).foregroundStyle(Tokens.textTertiary)
                    Text([row.size, row.fit].compactMap { $0 }.joined(separator: " · "))
                        .font(.frog(size: 11))
                        .foregroundStyle(row.fits ? Tokens.textTertiary : Tokens.signal)
                }
                Spacer(minLength: 8)
                controls
            }
            if case .downloading(let done, let total, _) = row.state, total > 0 {
                ProgressView(value: Double(done), total: Double(total)).controlSize(.small)
            }
            if let note = row.note {
                Text(note).font(.frog(size: 11)).foregroundStyle(Tokens.signal)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .monospacedDigit()
        .padding(.vertical, 2)
        .confirmationDialog("Delete \(row.name) from \(device.role == .thisMac ? "this Mac" : device.name)?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { delete() }
        } message: {
            Text("This frees \(row.size?.replacingOccurrences(of: " on disk", with: "") ?? "its space"). You can get it again later.")
        }
    }

    @ViewBuilder private var controls: some View {
        switch row.state {
        case .notDownloaded:
            gated(row.get) { Button(row.getLabel) { get() } }
        case .downloading:
            HStack(spacing: 8) {
                Text(row.progressLine ?? "Downloading").font(.frog(size: 11)).foregroundStyle(Tokens.textTertiary)
                if row.cancelDownload { Button("Cancel") { ModelDownloads.shared.cancel(row.id) } }
            }
        case .onDisk:
            HStack(spacing: 6) {
                gated(row.load) { Button("Load") { load() } }
                gated(row.delete) { Button("Delete") { confirmDelete = true } }
            }
        case .loading(let s, let afterTurn):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(afterTurn ? "Loads after this turn" : (s > 0 ? "Loading · \(s) s" : "Loading"))
                    .font(.frog(size: 11)).foregroundStyle(Tokens.textTertiary)
            }
        case .loaded(let decode):
            HStack(spacing: 8) {
                Text(["Loaded", decode.map(ModelStats.speedText)].compactMap { $0 }.joined(separator: " · "))
                    .font(.frog(size: 11)).foregroundStyle(Tokens.placeLocal)
                Button("Stop") { stop() }
            }
        }
    }

    /// A control that's off says why, on hover.
    @ViewBuilder private func gated(_ c: LocalModelRow.Control, @ViewBuilder _ button: () -> some View) -> some View {
        button().disabled(!c.enabled).help(c.why ?? "")
    }

    private func get() {
        guard device.role == .thisMac else { return }
        ModelDownloads.shared.download(row.id)
    }

    private func load() {
        guard let spec = row.spec else { return }
        devices.clearProblem(device.id, row.id)
        Task {
            do { try await devices.switchTo(spec, on: device.id) } catch {
                devices.noteProblem(device.id, row.id, "Couldn't load: " + error.localizedDescription)
            }
        }
    }

    private func stop() {
        Task {
            do { try await devices.stopModel(on: device.id) } catch {
                devices.noteProblem(device.id, row.id, "Couldn't stop: " + error.localizedDescription)
            }
        }
    }

    private func delete() {
        if device.role == .thisMac {
            ModelDownloads.shared.remove(row.id)
            Task { await devices.poll() }
        } else {
            Task { await devices.deleteModel(row.id, on: device.id) }
        }
    }
}

/// The detail behind a row's ⓘ: where it comes from, its format and what it needs.
struct LocalModelInfo: View {
    let row: LocalModelRow

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            Text(row.name).font(.frog(size: 13, weight: .semibold)).gridCellColumns(2)
            if let source = row.source {
                GridRow {
                    label("From")
                    if let url = row.sourceURL { Link(source, destination: url) } else { Text(source) }
                }
            }
            if let f = row.format { GridRow { label("Format"); Text(f) } }
            if let s = row.size { GridRow { label("Size"); Text(s) } }
            if let f = row.fit { GridRow { label("Memory"); Text(f) } }
            GridRow { label("Good for"); Text(row.uses ?? "Frog doesn't know this model; it runs if the machine can load it.") }
        }
        .font(.frog(size: 12))
        .padding(14)
        .frame(width: 340, alignment: .leading)
    }

    private func label(_ s: String) -> some View {
        Text(s).foregroundStyle(Tokens.textTertiary).gridColumnAlignment(.trailing)
    }
}
