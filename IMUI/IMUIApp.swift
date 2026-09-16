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

    /// How many progress-reporting steps ImageMagick's encoder for this format runs
    /// after loading, measured with `magick -monitor`.
    var encoderStages: Int {
        switch self {
        case .jpeg, .png, .heic, .bmp: 1
        case .webp: 2
        case .tiff: 0
        case .gif:  3
        case .pdf:  5
        }
    }

    /// Formats whose encoders keep an alpha channel.
    var supportsAlpha: Bool {
        switch self {
        case .png, .webp, .tiff: true
        default: false
        }
    }
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
    var transparentBackground: Bool
    var folder: URL?
}

@MainActor @Observable
final class ConversionSettings {
    var format: OutputFormat = .jpeg
    var resizeMode: ResizeMode = .none
    /// Rasterisation density for PDF input.
    var dpi = 150
    /// Keep PDF page backgrounds transparent instead of flattening onto white.
    var transparentBackground = false
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
            transparentBackground: transparentBackground,
            folder: outputFolder
        )
    }
}

extension Recipe {
    /// Load, the optional resize, then the encoder's own steps.
    var monitorStages: Int {
        1 + (resizeMode == .none ? 0 : 1) + format.encoderStages
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
    private(set) var isRunning = false
    private(set) var results: [ConversionResult] = []
    /// Fraction done for each item currently being converted.
    private(set) var progress: [ImageItem.ID: Double] = [:]
    /// Items in the running batch that haven't started yet.
    private(set) var waiting: Set<ImageItem.ID> = []

    private var task: Task<Void, Never>?

    var failures: [ConversionResult] { results.filter { !$0.succeeded } }

    /// ImageMagick already threads each command, and Ghostscript doesn't; half the
    /// cores as separate processes keeps PDF batches fast without oversubscribing.
    static let maxConcurrency = max(2, ProcessInfo.processInfo.activeProcessorCount / 2)

    func run(_ items: [ImageItem], recipe: Recipe, tools: Toolchain) {
        results = []
        progress = [:]
        waiting = Set(items.map(\.id))
        isRunning = true

        let width = min(Self.maxConcurrency, items.count)
        // Share the cores out, so a single big image still gets all of them.
        let threads = max(1, ProcessInfo.processInfo.activeProcessorCount / max(1, width))

        task = Task {
            await withTaskGroup(of: (ImageItem.ID, ConversionResult?).self) { group in
                var running = 0
                for item in items {
                    if running == width, let (id, result) = await group.next() {
                        finish(id, result)
                        running -= 1
                    }
                    if Task.isCancelled { break }

                    let id = item.id
                    let output = Self.outputURL(for: item.url, recipe: recipe)
                    let arguments = magickArguments(input: item.url, output: output, recipe: recipe)
                    let stages = recipe.monitorStages
                    waiting.remove(id)
                    progress[id] = 0
                    running += 1

                    group.addTask {
                        let result = await Self.execute(
                            tools: tools,
                            arguments: arguments,
                            threads: threads,
                            stages: stages,
                            source: item.url,
                            output: output
                        ) { fraction in
                            Task { @MainActor in self.advance(id, to: fraction) }
                        }
                        return (id, result)
                    }
                }
                for await (id, result) in group {
                    finish(id, result)
                }
            }
            waiting = []
            progress = [:]
            isRunning = false
        }
    }

    func cancel() {
        task?.cancel()
        waiting = []
    }

    func reset() {
        results = []
        progress = [:]
    }

    private func advance(_ id: ImageItem.ID, to fraction: Double) {
        // Updates hop over in separate tasks and can land out of order.
        guard let current = progress[id], fraction > current else { return }
        progress[id] = fraction
    }

    private func finish(_ id: ImageItem.ID, _ result: ConversionResult?) {
        progress[id] = nil
        if let result { results.append(result) }
    }

    private static func outputURL(for source: URL, recipe: Recipe) -> URL {
        let directory = recipe.folder ?? source.deletingLastPathComponent()
        let base = source.deletingPathExtension().lastPathComponent
        let candidate = directory.appending(path: "\(base).\(recipe.format.fileExtension)")
        return candidate.standardizedFileURL == source.standardizedFileURL
            ? directory.appending(path: "\(base)-converted.\(recipe.format.fileExtension)")
            : candidate
    }

    /// Runs one `magick` command, reporting progress as it goes. Returns `nil` when
    /// the task was cancelled, after stopping the process.
    private nonisolated static func execute(
        tools: Toolchain,
        arguments: [String],
        threads: Int,
        stages: Int,
        source: URL,
        output: URL,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async -> ConversionResult? {
        let process = Process()
        process.executableURL = tools.magick
        process.arguments = ["-monitor"] + arguments
        var environment = tools.environment
        environment["MAGICK_THREAD_LIMIT"] = "\(threads)"
        process.environment = environment
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice

        let exit = AsyncStream<Int32> { continuation in
            process.terminationHandler = {
                continuation.yield($0.terminationStatus)
                continuation.finish()
            }
        }

        do {
            try process.run()
        } catch {
            return ConversionResult(source: source, output: nil, error: error.localizedDescription)
        }

        let handle = ProcessHandle(process)
        return await withTaskCancellationHandler {
            var monitor = MonitorProgress(expectedStages: stages)
            var messages: [String] = []
            var reported = 0

            // Drain stderr as it arrives: a full pipe buffer would stall the child.
            do {
                for try await line in errors.fileHandleForReading.bytes.lines {
                    guard monitor.consume(line) else {
                        messages.append(line)
                        continue
                    }
                    let percent = Int(monitor.fraction * 100)
                    if percent > reported {
                        reported = percent
                        onProgress(monitor.fraction)
                    }
                }
            } catch {
                messages.append(error.localizedDescription)
            }

            var status: Int32 = -1
            for await code in exit { status = code }

            if Task.isCancelled {
                // Whatever magick managed to write is a truncated file.
                try? FileManager.default.removeItem(at: output)
                return nil
            }
            guard status != 0 else {
                return ConversionResult(source: source, output: output, error: nil)
            }
            let message = messages.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return ConversionResult(
                source: source,
                output: nil,
                error: message.isEmpty ? "magick exited with code \(status)." : message
            )
        } onCancel: {
            handle.terminate()
        }
    }
}

/// Lets the cancellation handler, which may run on any thread, stop the process.
/// `Process.terminate()` is safe to call from anywhere.
private struct ProcessHandle: @unchecked Sendable {
    let process: Process
    init(_ process: Process) { self.process = process }
    func terminate() { if process.isRunning { process.terminate() } }
}

/// Folds `magick -monitor` output into one fraction for the whole command.
///
/// Each step (load, resize, encode…) reports its own `N of M` count, so the overall
/// figure is the step index plus that step's share, over how many steps the recipe
/// is expected to take. It only ever moves forward.
struct MonitorProgress {
    let expectedStages: Int
    private(set) var fraction = 0.0
    private var stage = -1
    private var label = ""
    private var lastCount = 0

    init(expectedStages: Int) {
        self.expectedStages = max(1, expectedStages)
    }

    /// Returns `false` for lines that aren't progress, such as warnings and errors.
    mutating func consume(_ line: String) -> Bool {
        guard let match = line.wholeMatch(of: /(.+): (\d+) of (\d+), \d+% complete/),
              let count = Int(match.2), let total = Int(match.3), total > 0
        else { return false }

        let name = String(match.1)
        if name != label || count < lastCount {
            stage += 1
            label = name
        }
        lastCount = count

        let within = Double(count + 1) / Double(total)
        let overall = (Double(stage) + min(within, 1)) / Double(max(expectedStages, stage + 1))
        fraction = max(fraction, min(overall, 1))
        return true
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
        if recipe.transparentBackground && recipe.format.supportsAlpha {
            // Ghostscript renders with alpha, so an unpainted page stays see-through.
            arguments += ["-background", "none"]
        } else {
            // Page backgrounds are transparent; flatten onto white so JPEG doesn't go black.
            arguments += ["-background", "white", "-alpha", "remove", "-alpha", "off"]
        }
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

    func removeAll() {
        items.removeAll()
        selection.removeAll()
        engine.reset()
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
            Button("Add Images…", systemImage: "plus") { model.chooseFiles() }
                .keyboardShortcut("o")
        }

        CommandGroup(after: .newItem) {
            Divider()
            Button("Show Converted Files in Finder", systemImage: "folder") { model.revealOutputs() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(model.outputs.isEmpty)
        }

        // Select All is left to the focused list, so it keeps working in text fields.
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Remove Selected", systemImage: "minus") { model.removeSelected() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(model.selection.isEmpty)

            Button("Remove All", systemImage: "xmark") { model.removeAll() }
                .keyboardShortcut(.delete, modifiers: [.command, .shift])
                .disabled(model.items.isEmpty || model.engine.isRunning)
        }

        CommandGroup(after: .sidebar) {
            Button(model.columns == .detailOnly ? "Show Sidebar" : "Hide Sidebar", systemImage: "sidebar.left") {
                model.toggleSidebar()
            }
            .keyboardShortcut("s", modifiers: [.control, .command])
        }

        CommandMenu("Convert") {
            Button("Convert Images", systemImage: "arrow.triangle.2.circlepath") { model.convert() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!model.canConvert)

            Button("Stop", systemImage: "stop.fill") { model.cancel() }
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
