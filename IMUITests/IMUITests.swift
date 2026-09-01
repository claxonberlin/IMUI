//
//  IMUITests.swift
//  IMUITests
//
//  Created by Claus Bertels on 28/11/2024.
//

import Foundation
import Testing
@testable import IMUI

private func recipe(
    format: OutputFormat = .jpeg,
    quality: Int = 85,
    resizeMode: ResizeMode = .none,
    dpi: Int = 150
) -> Recipe {
    Recipe(
        format: format,
        quality: quality,
        resizeMode: resizeMode,
        width: 1920,
        height: 1080,
        percent: 50,
        dpi: dpi,
        folder: nil
    )
}

struct MagickArgumentTests {

    @Test func densityPrecedesPDFInput() {
        let args = magickArguments(
            input: URL(filePath: "/tmp/a.pdf"),
            output: URL(filePath: "/tmp/a.png"),
            recipe: recipe(format: .png, dpi: 300)
        )
        let density = try! #require(args.firstIndex(of: "-density"))
        let input = try! #require(args.firstIndex(of: "/tmp/a.pdf[0]"))
        // `-density` is a read setting: after the input it would not affect rasterisation.
        #expect(density < input)
        #expect(args[density + 1] == "300")
    }

    @Test func rasterInputCarriesNoDensity() {
        let args = magickArguments(
            input: URL(filePath: "/tmp/a.png"),
            output: URL(filePath: "/tmp/a.jpg"),
            recipe: recipe()
        )
        #expect(!args.contains("-density"))
        #expect(args.first == "/tmp/a.png")
    }

    @Test func noLegacyConvertSubcommand() {
        let args = magickArguments(
            input: URL(filePath: "/tmp/a.png"),
            output: URL(filePath: "/tmp/a.jpg"),
            recipe: recipe()
        )
        #expect(args.first != "convert")
    }

    @Test func pdfToRasterFlattensOntoWhite() {
        let args = magickArguments(
            input: URL(filePath: "/tmp/a.pdf"),
            output: URL(filePath: "/tmp/a.jpg"),
            recipe: recipe()
        )
        #expect(args.contains("-background"))
        #expect(args.contains("-alpha"))
    }

    @Test func outputIsFormatQualified() {
        let args = magickArguments(
            input: URL(filePath: "/tmp/a.png"),
            output: URL(filePath: "/tmp/a.webp"),
            recipe: recipe(format: .webp)
        )
        #expect(args.last == "WEBP:/tmp/a.webp")
    }

    @Test func qualityOnlyForLossyFormats() {
        #expect(magickArguments(
            input: URL(filePath: "/tmp/a.png"),
            output: URL(filePath: "/tmp/a.jpg"),
            recipe: recipe(quality: 42)
        ).contains("42"))

        #expect(!magickArguments(
            input: URL(filePath: "/tmp/a.jpg"),
            output: URL(filePath: "/tmp/a.png"),
            recipe: recipe(format: .png, quality: 42)
        ).contains("-quality"))
    }

    @Test func resizeModesMapToGeometry() {
        func geometry(_ mode: ResizeMode) -> String? {
            let args = magickArguments(
                input: URL(filePath: "/tmp/a.png"),
                output: URL(filePath: "/tmp/a.jpg"),
                recipe: recipe(resizeMode: mode)
            )
            return args.firstIndex(of: "-resize").map { args[$0 + 1] }
        }
        #expect(geometry(.none) == nil)
        #expect(geometry(.fit) == "1920x1080")
        #expect(geometry(.exact) == "1920x1080!")
        #expect(geometry(.percent) == "50%")
    }
}

/// Exercises the real binaries, so it only runs where they are installed.
struct ToolchainTests {

    @Test func discoversImageMagick7AndGhostscript() throws {
        let tools = try #require(Toolchain.discover(), "ImageMagick is not installed")
        #expect(tools.magickVersion.hasPrefix("7."), "expected ImageMagick 7, got \(tools.magickVersion)")
        #expect(tools.ghostscript != nil, "Ghostscript is not installed")
        #expect(tools.environment["PATH"]?.contains("/opt/homebrew/bin") == true)
    }

    /// The regression this guards: an app bundle launched from Finder inherits a bare
    /// `PATH`, ImageMagick cannot find `gs`, and every PDF fails to open.
    @Test func rasterisesPDFAtRequestedDensityWithoutInheritedPath() async throws {
        let tools = try #require(Toolchain.discover(), "ImageMagick is not installed")
        let dir = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let pdf = dir.appending(path: "page.pdf")
        try run(tools.magick, ["-size", "720x720", "canvas:white", "PDF:\(pdf.path)"], path: nil)

        for (dpi, expected) in [(72, 720), (144, 1440)] {
            let output = dir.appending(path: "page-\(dpi).png")
            let args = magickArguments(input: pdf, output: output, recipe: recipe(format: .png, dpi: dpi))
            // Deliberately withhold the ambient PATH; only Toolchain.environment should save us.
            try run(tools.magick, args, path: tools.environment["PATH"])

            let identify = try run(tools.magick, ["identify", "-format", "%w", output.path], path: nil)
            #expect(identify == "\(expected)", "at \(dpi) dpi expected \(expected)px wide, got \(identify)")
        }
    }

    @discardableResult
    private func run(_ tool: URL, _ arguments: [String], path: String?) throws -> String {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        process.environment = ["PATH": path ?? "/usr/bin:/bin"]
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let stdout = try out.fileHandleForReading.readToEnd() ?? Data()
        let stderr = try err.fileHandleForReading.readToEnd() ?? Data()
        process.waitUntilExit()
        try #require(
            process.terminationStatus == 0,
            "magick failed: \(String(decoding: stderr, as: UTF8.self))"
        )
        return String(decoding: stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@MainActor
struct SettingsTests {

    /// Clamping used to live in `didSet`, which under @Observable re-enters the
    /// synthesized setter — dragging the quality slider once crashed the app with
    /// a stack overflow.
    @Test func clampingDoesNotRecurse() {
        let settings = ConversionSettings()
        settings.quality = 500
        #expect(settings.quality == 100)
        settings.quality = -20
        #expect(settings.quality == 1)
        settings.width = 0
        #expect(settings.width == 1)
        settings.height = -5
        #expect(settings.height == 1)
        settings.percent = 0
        #expect(settings.percent == 1)
    }

    @Test func sliderBindingRoundsToWholePercent() {
        let settings = ConversionSettings()
        settings.qualityValue = 72.6
        #expect(settings.quality == 73)
        #expect(settings.qualityValue == 73)
    }

    @Test func recipeCarriesTheChosenFolder() {
        let settings = ConversionSettings()
        #expect(settings.recipe.folder == nil)
        settings.destination = .folder(URL(filePath: "/tmp/out"))
        #expect(settings.recipe.folder == URL(filePath: "/tmp/out"))
    }
}
