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

struct ConversionResult: Identifiable {
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

// MARK: - App

@main
struct IMUIApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 880, height: 600)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
