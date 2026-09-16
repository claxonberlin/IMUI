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
    @Bindable var model: AppModel
    @State private var isTargeted = false

    var body: some View {
        Group {
            if let tools = model.tools {
                NavigationSplitView(columnVisibility: $model.columns) {
                    Options(model: model, tools: tools)
                        .navigationSplitViewColumnWidth(min: 260, ideal: 290, max: 400)
                } detail: {
                    Library(model: model)
                }
                .navigationSplitViewStyle(.balanced)
                .dropDestination(for: URL.self) { urls, _ in
                    model.add(urls)
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
                MissingTools { model.rediscoverTools() }
            }
        }
        .frame(minWidth: 640, minHeight: 420)
    }
}

// MARK: - Library

struct Library: View {
    @Bindable var model: AppModel

    private var resultsBySource: [URL: ConversionResult] {
        Dictionary(model.engine.results.map { ($0.source, $0) }, uniquingKeysWith: { _, latest in latest })
    }

    var body: some View {
        List(model.items, selection: $model.selection) { item in
            Row(
                item: item,
                result: resultsBySource[item.url],
                progress: model.engine.progress[item.id],
                isWaiting: model.engine.waiting.contains(item.id)
            )
        }
        .listStyle(.inset)
        // Plain Delete works while the list holds focus; the menu adds a global Command-Delete.
        .onDeleteCommand(perform: model.removeSelected)
        .overlay {
            if model.items.isEmpty {
                ContentUnavailableView {
                    Label("No Images", systemImage: "photo.on.rectangle.angled")
                } description: {
                    Text("Drop images or PDFs here.")
                } actions: {
                    Button("Choose Files…", systemImage: "folder") { model.chooseFiles() }
                }
            }
        }
        .bottomBar { statusBar }
        .navigationTitle("")
        .toolbar {
            // Adjacent items in one group share a single glass capsule, the way
            // Safari pairs back and forward.
            ToolbarItemGroup(placement: .navigation) {
                Button("Add Images", systemImage: "plus") { model.chooseFiles() }
                    .help("Add images")

                Button("Remove Selected", systemImage: "minus", action: model.removeSelected)
                    .disabled(model.selection.isEmpty)
                    .help("Remove selected")

                Button("Remove All", systemImage: "xmark", action: model.removeAll)
                    .disabled(model.items.isEmpty || model.engine.isRunning)
                    .help("Remove all images")
            }

            // One slot: Convert becomes Stop while a batch runs.
            ToolbarItem(placement: .primaryAction) {
                if model.engine.isRunning {
                    Button("Stop", systemImage: "stop.fill", action: model.cancel)
                        .labelStyle(.titleAndIcon)
                        .prominentButtonStyle(false)
                        .help("Stop converting")
                } else {
                    Button("Convert", systemImage: "arrow.triangle.2.circlepath", action: model.convert)
                        .labelStyle(.titleAndIcon)
                        // A disabled prominent button keeps a washed-out accent tint;
                        // drop to the plain style so an idle Convert reads as grey.
                        .prominentButtonStyle(model.canConvert)
                        .disabled(!model.canConvert)
                        .help("Convert every image in the list")
                }
            }
        }
    }

    @ViewBuilder
    private var statusBar: some View {
        HStack(spacing: 12) {
            if !model.items.isEmpty {
                Text("^[\(model.items.count) image](inflect: true)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if !model.engine.isRunning && !model.outputs.isEmpty {
                Button("Show in Finder", systemImage: "folder", action: model.revealOutputs)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

struct Row: View {
    let item: ImageItem
    let result: ConversionResult?
    /// Set while this item is converting.
    let progress: Double?
    let isWaiting: Bool

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
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.filename)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let progress {
                    ProgressView(value: progress)
                        .controlSize(.small)
                        .padding(.top, 3)
                        .accessibilityLabel("Converting")
                } else if isWaiting {
                    Text("Waiting…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let error = result?.error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                        .textSelection(.enabled)
                } else {
                    Text(item.fileSize)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if let result {
                Image(systemName: result.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(result.succeeded ? .green : .orange)
                    .accessibilityLabel(result.succeeded ? "Converted" : "Failed")
            }
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Options

struct Options: View {
    @Bindable var model: AppModel
    let tools: Toolchain

    /// PDF pages are resolution-independent, so a raster target needs a density.
    private var needsDPI: Bool {
        model.settings.format.isRaster && model.hasPDFInput
    }

    private var needsTransparencyOption: Bool {
        needsDPI && model.settings.format.supportsAlpha
    }

    private var dpiFooter: String {
        guard needsTransparencyOption, model.settings.transparentBackground else {
            return "Pages are rasterised by Ghostscript at this density."
        }
        return "Pages are rasterised by Ghostscript at this density. Only PDFs that don't paint their own page background come out transparent."
    }

    var body: some View {
        @Bindable var settings = model.settings

        Form {
            Section {
                Picker("Format", selection: $settings.format) {
                    ForEach(OutputFormat.allCases) { Text($0.rawValue).tag($0) }
                }

                if settings.format.supportsQuality {
                    LabeledContent("Quality") {
                        HStack(spacing: 10) {
                            // No `step:` — it would draw a tick mark per unit.
                            Slider(value: $settings.qualityValue, in: 1...100)
                                .accessibilityLabel("Quality")
                            TextField("Quality", value: $settings.quality, format: .number)
                                .labelsHidden()
                                .multilineTextAlignment(.trailing)
                                .monospacedDigit()
                                .frame(width: 40)
                        }
                    }
                }

                if needsDPI {
                    Picker("Resolution", selection: $settings.dpi) {
                        ForEach([72, 144, 150, 300, 600], id: \.self) { Text("\($0) dpi").tag($0) }
                    }
                }

                if needsTransparencyOption {
                    Toggle("Transparent Background", isOn: $settings.transparentBackground)
                }
            } header: {
                Text("Output")
            } footer: {
                if needsDPI {
                    Text(dpiFooter)
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
                                .frame(width: 62)
                            Text("×").foregroundStyle(.secondary)
                            TextField("Height", value: $settings.height, format: .number)
                                .labelsHidden()
                                .frame(width: 62)
                            Text("px").foregroundStyle(.secondary)
                        }
                    }
                case .percent:
                    LabeledContent("Scale") {
                        HStack(spacing: 6) {
                            TextField("Percent", value: $settings.percent, format: .number)
                                .labelsHidden()
                                .frame(width: 62)
                            Text("%").foregroundStyle(.secondary)
                            Spacer()
                        }
                    }
                }
            }

            Section("Destination") {
                DestinationPicker(settings: settings)
            }
        }
        .formStyle(.grouped)
        .animation(.easeOut(duration: 0.15), value: settings.resizeMode)
        .animation(.easeOut(duration: 0.15), value: needsTransparencyOption)
        .bottomBar {
            Text(tools.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
        }
    }
}

// MARK: - Destination

/// Safari's download-location convention: current choice plus an "Other…" escape hatch.
struct DestinationPicker: View {
    @Bindable var settings: ConversionSettings

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

extension Toolchain {
    var summary: String {
        let gs = ghostscriptVersion.map { "Ghostscript \($0)" } ?? "Ghostscript not found"
        return "ImageMagick \(magickVersion) · \(gs)"
    }
}

// MARK: - Platform Styling

extension View {
    /// A bar pinned to the bottom edge. On macOS 26 and later the system's scroll edge
    /// effect blends it with the content under it; earlier releases get the frosted `.bar`.
    @ViewBuilder
    func bottomBar(@ViewBuilder content: () -> some View) -> some View {
        if #available(macOS 26.0, *) {
            safeAreaBar(edge: .bottom, content: content)
        } else {
            safeAreaInset(edge: .bottom) { content().background(.bar) }
        }
    }

    /// The window's primary action: glass on macOS 26 and later, a filled bezel before.
    /// Pass `false` to show the same control without the accent, e.g. while it's unavailable.
    @ViewBuilder
    func prominentButtonStyle(_ isProminent: Bool = true) -> some View {
        if #available(macOS 26.0, *) {
            if isProminent { buttonStyle(.glassProminent) } else { buttonStyle(.glass) }
        } else {
            if isProminent { buttonStyle(.borderedProminent) } else { buttonStyle(.bordered) }
        }
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

            Button("Try Again", systemImage: "arrow.clockwise", action: onRetry)
                .prominentButtonStyle()
        }
    }
}

#Preview {
    ContentView(model: AppModel())
}
