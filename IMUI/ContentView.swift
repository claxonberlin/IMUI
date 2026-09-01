//
//  ContentView.swift
//  IMUI
//
//  Created by Claus Bertels on 28/11/2024.
//

import SwiftUI
import AppKit

// MARK: - Root

struct ContentView: View {
    @State private var settings = ConversionSettings()
    @State private var engine = ConversionEngine()
    @State private var items: [ImageItem] = []
    @State private var selection: Set<ImageItem.ID> = []
    @State private var tools = Toolchain.discover()
    @State private var isTargeted = false

    var body: some View {
        Group {
            if let tools {
                NavigationSplitView {
                    Library(items: $items, selection: $selection, onAdd: chooseFiles)
                        .navigationSplitViewColumnWidth(min: 220, ideal: 270, max: 380)
                } detail: {
                    Options(settings: settings, engine: engine, items: items, tools: tools) {
                        engine.run(items, recipe: settings.recipe, tools: tools)
                    }
                }
                .navigationSplitViewStyle(.balanced)
                .dropDestination(for: URL.self) { urls, _ in
                    add(urls)
                    return true
                } isTargeted: {
                    isTargeted = $0
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.accentColor, lineWidth: 4)
                        .opacity(isTargeted ? 1 : 0)
                        .allowsHitTesting(false)
                }
                .animation(.easeOut(duration: 0.15), value: isTargeted)
            } else {
                MissingTools { tools = Toolchain.discover() }
            }
        }
        .frame(minWidth: 700, minHeight: 460)
    }

    private func add(_ urls: [URL]) {
        let known = Set(items.map(\.url))
        let new = urls.filter { isConvertible($0) && !known.contains($0) }.map { ImageItem(url: $0) }
        items.append(contentsOf: new)
        engine.reset()

        for item in new {
            Task {
                guard let image = await makeThumbnail(for: item.url),
                      let index = items.firstIndex(where: { $0.id == item.id }) else { return }
                items[index].thumbnail = image
            }
        }
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image, .pdf]
        panel.message = "Choose images or PDFs to convert."
        if panel.runModal() == .OK { add(panel.urls) }
    }
}

// MARK: - Library

struct Library: View {
    @Binding var items: [ImageItem]
    @Binding var selection: Set<ImageItem.ID>
    let onAdd: () -> Void

    var body: some View {
        List(items, selection: $selection) { item in
            Row(item: item)
        }
        .listStyle(.sidebar)
        .overlay {
            if items.isEmpty {
                ContentUnavailableView {
                    Label("No Images", systemImage: "photo.on.rectangle.angled")
                } description: {
                    Text("Drop images or PDFs here.")
                } actions: {
                    Button("Choose Files…", action: onAdd)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 2) {
                Button(action: onAdd) {
                    Image(systemName: "plus")
                }
                .help("Add images")

                Button {
                    items.removeAll { selection.contains($0.id) }
                    selection.removeAll()
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(selection.isEmpty)
                .help("Remove selected")

                Spacer()

                if !items.isEmpty {
                    Text("^[\(items.count) image](inflect: true)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.accessoryBar)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.bar)
        }
    }
}

struct Row: View {
    let item: ImageItem

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let thumbnail = item.thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: item.isPDF ? "doc.richtext" : "photo")
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.filename)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(item.fileSize)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Options

struct Options: View {
    @Bindable var settings: ConversionSettings
    let engine: ConversionEngine
    let items: [ImageItem]
    let tools: Toolchain
    let onConvert: () -> Void

    /// PDF pages are resolution-independent, so a raster target needs a density.
    private var needsDPI: Bool {
        settings.format.isRaster && items.contains { $0.isPDF }
    }

    var body: some View {
        Form {
            Section {
                Picker("Format", selection: $settings.format) {
                    ForEach(OutputFormat.allCases) { Text($0.rawValue).tag($0) }
                }

                if settings.format.supportsQuality {
                    LabeledContent("Quality") {
                        HStack(spacing: 12) {
                            // No `step:` — it would draw a tick mark per unit.
                            Slider(value: $settings.qualityValue, in: 1...100)
                            TextField("Quality", value: $settings.quality, format: .number)
                                .labelsHidden()
                                .multilineTextAlignment(.trailing)
                                .monospacedDigit()
                                .frame(width: 44)
                        }
                    }
                }

                if needsDPI {
                    Picker("Resolution", selection: $settings.dpi) {
                        ForEach([72, 150, 300, 600], id: \.self) { Text("\($0) dpi").tag($0) }
                    }
                }
            } header: {
                Text("Output")
            } footer: {
                if needsDPI {
                    Text("Pages are rasterised by Ghostscript at this density.")
                }
            }

            Section("Size") {
                Picker("Resize", selection: $settings.resizeMode) {
                    ForEach(ResizeMode.allCases) { Text($0.rawValue).tag($0) }
                }

                switch settings.resizeMode {
                case .none:
                    EmptyView()
                case .fit, .exact:
                    LabeledContent("Dimensions") {
                        HStack(spacing: 6) {
                            TextField("Width", value: $settings.width, format: .number)
                                .labelsHidden()
                                .frame(width: 72)
                            Text("×").foregroundStyle(.secondary)
                            TextField("Height", value: $settings.height, format: .number)
                                .labelsHidden()
                                .frame(width: 72)
                            Text("px").foregroundStyle(.secondary)
                            Spacer()
                        }
                    }
                case .percent:
                    LabeledContent("Scale") {
                        HStack(spacing: 6) {
                            TextField("Percent", value: $settings.percent, format: .number)
                                .labelsHidden()
                                .frame(width: 72)
                            Text("%").foregroundStyle(.secondary)
                            Spacer()
                        }
                    }
                }
            }

            Section("Destination") {
                DestinationPicker(settings: settings)
            }

            if !engine.failures.isEmpty {
                Section("Failed") {
                    ForEach(engine.failures) { result in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(result.source.lastPathComponent).fontWeight(.medium)
                            if let error = result.error {
                                Text(error)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .animation(.easeOut(duration: 0.15), value: settings.resizeMode)
        .safeAreaInset(edge: .bottom) {
            ActionBar(engine: engine, items: items, tools: tools, onConvert: onConvert)
        }
    }
}

// MARK: - Destination

/// Safari's download-location convention: current choice plus an "Other…" escape hatch.
struct DestinationPicker: View {
    @Bindable var settings: ConversionSettings
    @State private var isChoosing = false

    var body: some View {
        Picker("Save To", selection: Binding(get: { settings.destination }, set: choose)) {
            Text("Alongside Originals").tag(Destination.alongsideSource)
            if let folder = settings.outputFolder {
                Text(folder.lastPathComponent).tag(Destination.folder(folder))
            }
            Divider()
            Text("Other…").tag(Destination.folder(Self.sentinel))
        }
    }

    private static let sentinel = URL(filePath: "/")

    private func choose(_ destination: Destination) {
        guard case .folder(Self.sentinel) = destination else {
            settings.destination = destination
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.message = "Choose where converted files are saved."
        if panel.runModal() == .OK, let url = panel.url {
            settings.destination = .folder(url)
        }
    }
}

// MARK: - Action Bar

struct ActionBar: View {
    let engine: ConversionEngine
    let items: [ImageItem]
    let tools: Toolchain
    let onConvert: () -> Void

    private var outputs: [URL] { engine.results.compactMap(\.output) }

    var body: some View {
        HStack(spacing: 12) {
            if engine.isRunning {
                ProgressView(value: engine.progress)
                    .frame(width: 120)
                Text(engine.currentFile)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Cancel", role: .cancel) { engine.cancel() }
            } else {
                status
                Spacer()
                if !outputs.isEmpty {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting(outputs)
                    }
                }
                Button("Convert", action: onConvert)
                    .keyboardShortcut(.defaultAction)
                    .disabled(items.isEmpty)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }

    @ViewBuilder
    private var status: some View {
        if !engine.results.isEmpty {
            Label(
                "\(outputs.count) of \(engine.results.count) converted",
                systemImage: engine.failures.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
            )
            .foregroundStyle(engine.failures.isEmpty ? .green : .orange)
            .font(.callout)
        } else {
            Text(tools.summary)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

extension Toolchain {
    var summary: String {
        let gs = ghostscriptVersion.map { "Ghostscript \($0)" } ?? "Ghostscript not found"
        return "ImageMagick \(magickVersion) · \(gs)"
    }
}

// MARK: - Missing Tools

struct MissingTools: View {
    let onRetry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("ImageMagick Not Found", systemImage: "shippingbox")
        } description: {
            Text("IMUI converts images by calling ImageMagick, and reads PDFs through Ghostscript.")
        } actions: {
            Text("brew install imagemagick ghostscript")
                .font(.body.monospaced())
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.quaternary, in: .rect(cornerRadius: 8))

            Button("Try Again", action: onRetry)
                .buttonStyle(.borderedProminent)
        }
    }
}

#Preview {
    ContentView()
}
