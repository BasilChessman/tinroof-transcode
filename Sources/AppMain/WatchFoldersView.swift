import SwiftUI
import AppKit
import MediaCore

/// Window › Watch Folders: folders whose new files are encoded automatically.
struct WatchFoldersView: View {
    @ObservedObject var manager: WatchFolderManager
    @ObservedObject var queue: BatchQueue
    let presets: PresetStore
    @State private var selection: UUID?

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                folderList.frame(minWidth: 220, idealWidth: 260, maxWidth: 340)
                detail.frame(minWidth: 380)
            }
            Divider()
            footer
        }
        .onAppear { if selection == nil { selection = manager.folders.first?.id } }
    }

    // MARK: Folder list

    private var folderList: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach($manager.folders) { $folder in
                    HStack(spacing: 8) {
                        Toggle("", isOn: $folder.enabled).labelsHidden().toggleStyle(.checkbox)
                            .help("Watch this folder")
                        Image(systemName: "folder.fill").foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(folder.name).lineLimit(1)
                            Text(folder.outputs.isEmpty ? "No outputs" : folder.outputs.map(\.name).joined(separator: ", "))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .tag(folder.id)
                    .contextMenu {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder.url]) }
                        Button("Remove") { remove(folder.id) }
                    }
                }
            }
            .overlay {
                if manager.folders.isEmpty {
                    Text("Click + or drop a folder here to watch it.")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary).padding(24)
                }
            }
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                for p in providers {
                    _ = p.loadObject(ofClass: URL.self) { url, _ in
                        guard let url, (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { return }
                        DispatchQueue.main.async { add(url) }
                    }
                }
                return true
            }
            Divider()
            HStack(spacing: 0) {
                Button { chooseFolders() } label: { Image(systemName: "plus").frame(width: 22, height: 18) }
                    .help("Add a watch folder")
                Button { if let id = selection { remove(id) } } label: { Image(systemName: "minus").frame(width: 22, height: 18) }
                    .disabled(selection == nil).help("Stop watching the selected folder")
                Spacer()
            }
            .buttonStyle(.borderless).padding(6)
        }
    }

    private func chooseFolders() {
        let p = NSOpenPanel()
        p.canChooseFiles = false; p.canChooseDirectories = true; p.canCreateDirectories = true; p.allowsMultipleSelection = true
        p.message = "Choose folders to watch. Files dropped into them are encoded automatically."
        p.prompt = "Watch"
        guard p.runModal() == .OK else { return }
        p.urls.forEach(add)
    }

    private func add(_ url: URL) {
        manager.addFolder(url)
        selection = manager.folders.first { $0.path == url.path }?.id
    }

    private func remove(_ id: UUID) {
        manager.removeFolder(id)
        if selection == id { selection = manager.folders.first?.id }
    }

    // MARK: Detail

    @ViewBuilder private var detail: some View {
        if let index = manager.folders.firstIndex(where: { $0.id == selection }) {
            FolderDetail(folder: $manager.folders[index], presets: presets)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "folder.badge.gearshape").font(.system(size: 40)).foregroundStyle(.secondary)
                Text("Add a folder, then choose what it makes.").foregroundStyle(.secondary)
                Button("Add Folder…") { chooseFolders() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle("Auto-encode watch folders", isOn: $manager.autoEncode)
                    .help("When on, new files in enabled folders are added to the Batch List and encoded straight away.")
                if manager.inFlightCount > 0 {
                    Text("\(manager.inFlightCount) file\(manager.inFlightCount == 1 ? "" : "s") in progress").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Batch List") { AppDelegate.shared.showBatch(nil) }
            }
            if let last = manager.activity.first {
                Text(last).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    .help(manager.activity.prefix(10).joined(separator: "\n"))
            }
        }
        .padding(10)
    }
}

/// Outputs and destination of one watch folder.
private struct FolderDetail: View {
    @Binding var folder: WatchFolder
    let presets: PresetStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(folder.name).font(.title3.weight(.semibold))
                    Text(folder.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        .textSelection(.enabled)
                }
                Spacer()
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder.url]) }
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 0) {
                    if folder.outputs.isEmpty {
                        Text("Add at least one output. With several, every file is encoded once per output.")
                            .font(.callout).foregroundStyle(.secondary).padding(8)
                    }
                    ForEach(folder.outputs) { output in
                        HStack {
                            Image(systemName: icon(for: output)).frame(width: 18).foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(output.name)
                                Text(summary(output)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Button { folder.outputs.removeAll { $0.id == output.id } } label: { Image(systemName: "minus.circle.fill") }
                                .buttonStyle(.borderless).foregroundStyle(.secondary).help("Remove this output")
                        }
                        .padding(.vertical, 5).padding(.horizontal, 6)
                        if output.id != folder.outputs.last?.id { Divider() }
                    }
                    addOutputMenu.padding(.top, 8).padding(.horizontal, 4)
                }
            } label: { Text("Outputs").font(.headline) }

            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(folder.outputPath == nil ? "“\(WatchFolderManager.outputFolderName)” folder inside the watch folder" : folder.outputURL.path)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Choose…") { chooseOutput() }
                        if folder.outputPath != nil { Button("Default") { folder.outputPath = nil } }
                    }
                    Text("When every output of a file succeeds, the original moves to “\(WatchFolderManager.sourceFolderName)”; if one fails it moves to “\(WatchFolderManager.failedFolderName)”. Either way it is not encoded twice.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(4)
            } label: { Text("Destination").font(.headline) }
            Spacer(minLength: 0)
        }
        .padding(14)
    }

    private var addOutputMenu: some View {
        Menu {
            Section("Built-in") {
                ForEach(WatchOutput.builtIn) { o in Button(o.name) { append(o) } }
            }
            let saved = presets.presets.filter { $0.settings.kind != .frame }
            if !saved.isEmpty {
                Section("Saved presets") {
                    ForEach(saved) { p in Button("\(p.name) (\(p.settings.kind.rawValue))") { append(WatchOutput(name: p.name, kind: .export(p.settings))) } }
                }
            }
        } label: { Label("Add Output", systemImage: "plus") }
        .fixedSize()
    }

    private func append(_ o: WatchOutput) {
        var copy = o
        copy.id = UUID()
        folder.outputs.append(copy)
    }

    private func chooseOutput() {
        let p = NSOpenPanel()
        p.canChooseFiles = false; p.canChooseDirectories = true; p.canCreateDirectories = true
        p.message = "Choose where encoded files from “\(folder.name)” are saved."
        if p.runModal() == .OK, let u = p.url { folder.outputPath = u.path }
    }

    private func icon(for o: WatchOutput) -> String {
        switch o.kind {
        case .export(let s): return s.kind == .audio ? "waveform" : "film"
        default: return "doc.on.doc"
        }
    }

    private func summary(_ o: WatchOutput) -> String {
        switch o.kind {
        case .export(let s):
            if s.kind == .audio { return "Audio · \(s.audioFormat.rawValue)" }
            var parts = [s.kind.rawValue, s.videoCodec.rawValue]
            if let f = s.frameSize { parts.append("\(f.width)×\(f.height)") }
            parts.append(s.audioFormat.rawValue)
            return parts.joined(separator: " · ")
        case .convert(let t): return t.title + " · no re-encoding"
        case .saveAs(let f): return f.rawValue
        default: return ""
        }
    }
}
