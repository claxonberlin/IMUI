//
//  IMUIApp.swift
//  IMUI
//
//  Created by Claus Bertels on 28/11/2024.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import QuickLookThumbnailing

// MARK: - Toolchain

/// The command-line tools the app shells out to.
struct Toolchain: Sendable {
    let magick: URL
    let ghostscript: URL?
    let magickVersion: String
    let ghostscriptVersion: String?

    /// Where Homebrew, MacPorts and the system keep their binaries.
    static let searchPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/usr/bin"]

    static func discover() -> Toolchain? {
        guard let magick = locate("magick"),
              let version = capture(magick, ["-version"])?
                  .split(separator: "\n").first
                  .flatMap({ $0.split(separator: " ").dropFirst(2).first })
        else { return nil }

        let gs = locate("gs")
        return Toolchain(
            magick: magick,
            ghostscript: gs,
            magickVersion: String(version),
            ghostscriptVersion: gs.flatMap { capture($0, ["--version"]) }
        )
    }

    /// ImageMagick resolves its Ghostscript delegate through `PATH`. An app bundle
    /// launched from Finder inherits a bare one, so hand children somewhere to look —
    /// without this, every PDF fails with `gs: command not found`.
    var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (Self.searchPaths + [env["PATH"]].compactMap { $0 }).joined(separator: ":")
        return env
    }

    private static func locate(_ name: String) -> URL? {
        searchPaths
            .map { URL(filePath: $0).appending(path: name) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private static func capture(_ tool: URL, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Models

struct ImageItem: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    var thumbnail: NSImage?

    /// The thumbnail has to count: SwiftUI compares rows by value, and an identity-only
    /// `==` would let a row keep its placeholder after the thumbnail arrives.
    static func == (lhs: ImageItem, rhs: ImageItem) -> Bool {
        lhs.id == rhs.id && lhs.thumbnail === rhs.thumbnail
    }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    var filename: String { url.lastPathComponent }
    var isPDF: Bool { url.pathExtension.lowercased() == "pdf" }

    var fileSize: String {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return "" }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}

enum OutputFormat: String, CaseIterable, Identifiable, Sendable {
    case jpeg = "JPEG"
    case png  = "PNG"
    case webp = "WebP"
    case heic = "HEIC"
    case tiff = "TIFF"
    case gif  = "GIF"
    case bmp  = "BMP"
    case pdf  = "PDF"

    var id: Self { self }

    var fileExtension: String {
        switch self {
        case .jpeg: "jpg"
        case .png:  "png"
        case .webp: "webp"
        case .heic: "heic"
        case .tiff: "tiff"
        case .gif:  "gif"
        case .bmp:  "bmp"
        case .pdf:  "pdf"
        }
    }

    /// The explicit `FORMAT:path` prefix, so the extension never decides the encoder.
    var magickPrefix: String { rawValue.uppercased() }

    var supportsQuality: Bool {
        switch self {
        case .jpeg, .webp, .heic: true
        default: false
        }
    }

    var isRaster: Bool { self != .pdf }
}

enum ResizeMode: String, CaseIterable, Identifiable, Sendable {
    case none    = "Original Size"
    case fit     = "Fit Within"
    case exact   = "Exact Size"
    case percent = "Scale"

    var id: Self { self }
}

enum Destination: Hashable {
    case alongsideSource
    case folder(URL)
}

struct ConversionResult: Identifiable, Equatable {
    let id = UUID()
    let source: URL
    let output: URL?
    let error: String?

    var succeeded: Bool { output != nil }
}

// MARK: - Settings

/// An immutable snapshot of the settings, safe to hand to a background task.
struct Recipe: Sendable {
    var format: OutputFormat
    var quality: Int
    var resizeMode: ResizeMode
    var width: Int
    var height: Int
    var percent: Int
    var dpi: Int
    var folder: URL?
}

@MainActor @Observable
final class ConversionSettings {
    var format: OutputFormat = .jpeg
    var resizeMode: ResizeMode = .none
    /// Rasterisation density for PDF input.
    var dpi = 150
    var destination: Destination = .alongsideSource

    // Typed fields are clamped in their setters rather than in `didSet`: under
    // @Observable a stored property is already a computed one, so assigning to
    // itself from `didSet` re-enters the setter and recurses until the stack blows.
    private var storedQuality = 85
    private var storedWidth = 1920
    private var storedHeight = 1080
    private var storedPercent = 50

    var quality: Int {
        get { storedQuality }
        set { storedQuality = newValue.clamped(to: 1...100) }
    }

    var width: Int {
        get { storedWidth }
        set { storedWidth = max(1, newValue) }
    }

    var height: Int {
        get { storedHeight }
        set { storedHeight = max(1, newValue) }
    }

    var percent: Int {
        get { storedPercent }
        set { storedPercent = newValue.clamped(to: 1...1000) }
    }

    /// Bridges the integer quality to `Slider`, which needs a floating-point binding.
    var qualityValue: Double {
        get { Double(quality) }
        set { quality = Int(newValue.rounded()) }
    }

    var outputFolder: URL? {
        if case .folder(let url) = destination { return url }
        return nil
    }

    var recipe: Recipe {
        Recipe(
            format: format,
            quality: quality,
            resizeMode: resizeMode,
            width: width,
            height: height,
            percent: percent,
            dpi: dpi,
            folder: outputFolder
        )
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

// MARK: - Conversion Engine

@MainActor @Observable
final class ConversionEngine {
    private(set) var progress = 0.0
    private(set) var currentFile = ""
    private(set) var isRunning = false
    private(set) var results: [ConversionResult] = []

    private var task: Task<Void, Never>?

    var failures: [ConversionResult] { results.filter { !$0.succeeded } }

    func run(_ items: [ImageItem], recipe: Recipe, tools: Toolchain) {
        progress = 0
        currentFile = ""
        results = []
        isRunning = true

        task = Task {
            var collected: [ConversionResult] = []
            for (index, item) in items.enumerated() {
                if Task.isCancelled { break }
                currentFile = item.filename
                let output = Self.outputURL(for: item.url, recipe: recipe)
                let arguments = magickArguments(input: item.url, output: output, recipe: recipe)
                collected.append(
                    await Self.execute(tools: tools, arguments: arguments, source: item.url, output: output)
                )
                progress = Double(index + 1) / Double(items.count)
            }
            results = collected
            isRunning = false
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        isRunning = false
    }

    func reset() {
        results = []
        progress = 0
    }

    private static func outputURL(for source: URL, recipe: Recipe) -> URL {
        let directory = recipe.folder ?? source.deletingLastPathComponent()
        let base = source.deletingPathExtension().lastPathComponent
        let candidate = directory.appending(path: "\(base).\(recipe.format.fileExtension)")
        return candidate.standardizedFileURL == source.standardizedFileURL
            ? directory.appending(path: "\(base)-converted.\(recipe.format.fileExtension)")
            : candidate
    }

    private nonisolated static func execute(
        tools: Toolchain,
        arguments: [String],
        source: URL,
        output: URL
    ) async -> ConversionResult {
        await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = tools.magick
            process.arguments = arguments
            process.environment = tools.environment
            let errors = Pipe()
            process.standardError = errors
            process.standardOutput = FileHandle.nullDevice

            do {
                try process.run()
                // Drain before waiting: a full pipe buffer would deadlock the child.
                let data = try errors.fileHandleForReading.readToEnd() ?? Data()
                process.waitUntilExit()
                guard process.terminationStatus != 0 else {
                    return ConversionResult(source: source, output: output, error: nil)
                }
                let message = String(decoding: data, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return ConversionResult(
                    source: source,
                    output: nil,
                    error: message.isEmpty ? "magick exited with code \(process.terminationStatus)." : message
                )
            } catch {
                return ConversionResult(source: source, output: nil, error: error.localizedDescription)
            }
        }.value
    }
}

// MARK: - ImageMagick Command

/// Builds an ImageMagick 7 command line: `magick [read settings] input [operators] output`.
/// Settings that affect *decoding* — notably `-density` for PDF — must precede the input.
func magickArguments(input: URL, output: URL, recipe: Recipe) -> [String] {
    var arguments: [String] = []
    let isVector = input.pathExtension.lowercased() == "pdf"

    if isVector {
        arguments += ["-density", "\(recipe.dpi)"]
    }
    arguments.append(isVector ? "\(input.path)[0]" : input.path)

    if isVector && recipe.format.isRaster {
        // Page backgrounds are transparent; flatten onto white so JPEG doesn't go black.
        arguments += ["-background", "white", "-alpha", "remove", "-alpha", "off"]
    }

    switch recipe.resizeMode {
    case .none:    break
    case .fit:     arguments += ["-resize", "\(recipe.width)x\(recipe.height)"]
    case .exact:   arguments += ["-resize", "\(recipe.width)x\(recipe.height)!"]
    case .percent: arguments += ["-resize", "\(recipe.percent)%"]
    }

    if recipe.format.supportsQuality {
        arguments += ["-quality", "\(recipe.quality)"]
    }

    switch recipe.format {
    case .tiff: arguments += ["-compress", "LZW"]
    case .bmp:  arguments += ["-type", "TrueColor"]
    case .pdf:  arguments += ["-flatten"]
    default:    break
    }

    arguments.append("\(recipe.format.magickPrefix):\(output.path)")
    return arguments
}

// MARK: - Files

func isConvertible(_ url: URL) -> Bool {
    guard url.isFileURL, let type = UTType(filenameExtension: url.pathExtension) else { return false }
    return type.conforms(to: .image) || type.conforms(to: .pdf)
}

func makeThumbnail(for url: URL, size: CGFloat = 44) async -> NSImage? {
    let request = QLThumbnailGenerator.Request(
        fileAt: url,
        size: CGSize(width: size, height: size),
        scale: 2,
        representationTypes: .thumbnail
    )
    let thumbnail = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
    return thumbnail?.nsImage
}

// MARK: - App Model

/// One owner for everything the window and the menu bar both act on.
@MainActor @Observable
final class AppModel {
    let settings = ConversionSettings()
    let engine = ConversionEngine()
    var items: [ImageItem] = []
    var selection: Set<ImageItem.ID> = []
    var tools: Toolchain?
    var columns: NavigationSplitViewVisibility = .all

    init() {
        tools = Toolchain.discover()
    }

    var outputs: [URL] { engine.results.compactMap(\.output) }
    var hasPDFInput: Bool { items.contains { $0.isPDF } }
    var canConvert: Bool { !items.isEmpty && !engine.isRunning && tools != nil }

    func add(_ urls: [URL]) {
        let known = Set(items.map(\.url))
        let new = urls.filter { isConvertible($0) && !known.contains($0) }.map { ImageItem(url: $0) }
        guard !new.isEmpty else { return }
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

    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image, .pdf]
        panel.message = "Choose images or PDFs to convert."
        if panel.runModal() == .OK { add(panel.urls) }
    }

    func removeSelected() {
        items.removeAll { selection.contains($0.id) }
        selection.removeAll()
    }

    func convert() {
        guard canConvert, let tools else { return }
        engine.run(items, recipe: settings.recipe, tools: tools)
    }

    func cancel() {
        engine.cancel()
    }

    func revealOutputs() {
        guard !outputs.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(outputs)
    }

    func rediscoverTools() {
        tools = Toolchain.discover()
    }

    func toggleSidebar() {
        columns = columns == .detailOnly ? .all : .detailOnly
    }
}

// MARK: - Menus

struct AppCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Add Images…") { model.chooseFiles() }
                .keyboardShortcut("o")
        }

        CommandGroup(after: .newItem) {
            Divider()
            Button("Show Converted Files in Finder") { model.revealOutputs() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(model.outputs.isEmpty)
        }

        // Select All is left to the focused list, so it keeps working in text fields.
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Remove Selected") { model.removeSelected() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(model.selection.isEmpty)
        }

        CommandGroup(after: .sidebar) {
            Button(model.columns == .detailOnly ? "Show Sidebar" : "Hide Sidebar") {
                model.toggleSidebar()
            }
            .keyboardShortcut("s", modifiers: [.control, .command])
        }

        CommandMenu("Convert") {
            Button("Convert Images") { model.convert() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!model.canConvert)

            Button("Stop") { model.cancel() }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(!model.engine.isRunning)

            Divider()

            Picker("Format", selection: Bindable(model.settings).format) {
                ForEach(OutputFormat.allCases) { Text($0.rawValue).tag($0) }
            }

            Picker("Resize", selection: Bindable(model.settings).resizeMode) {
                ForEach(ResizeMode.allCases) { Text($0.rawValue).tag($0) }
            }
        }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // One window, so tabs and the Window menu's tab commands are noise.
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct IMUIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        // `Window` rather than `WindowGroup`: a single window, and no New Window command.
        Window("IMUI", id: "converter") {
            ContentView(model: model)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 750, height: 500)
        .commands { AppCommands(model: model) }
    }
}
