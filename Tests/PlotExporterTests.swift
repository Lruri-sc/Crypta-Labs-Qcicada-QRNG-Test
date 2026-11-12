// Run independently from the repository root:
// swiftc -swift-version 5 -default-isolation MainActor \
//   Qcicada/Models/StreamingPNGWriter.swift Qcicada/Models/PlotExporter.swift Tests/PlotExporterTests.swift \
//   -o /tmp/qcicada-plot-tests
// /tmp/qcicada-plot-tests

import AppKit
import Foundation
import ImageIO
import zlib

@main
struct PlotExporterTests {
    static func main() async throws {
        try await Task.detached {
            if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--raster-only" {
                try runRasterChecks()
            } else if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--conversion-only" {
                testConvertedBitmap()
            } else if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--benchmark",
               let count = Int(CommandLine.arguments[2]), count > 0 {
                try benchmark(samples: count)
            } else {
                try runChecks()
            }
        }.value
    }

    nonisolated private static func runChecks() throws {
        precondition(!Thread.isMainThread, "Export checks must exercise background rendering")
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("QcicadaPlotExporterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        try testRasterLayout(in: folder)
        testConvertedBitmap()
        testStrokePieces()

        let iz = [0.5, 0.5, 0.5, 0.5]
        let cz = [0.5, 1.0, 1.5, 2.0]
        let vr = [1.0, 0.8, 0.9, 1.0]
        let stats: PlotExporter.Stats = (4, 64, 40, 0.5, 0.5, 2.0, 0.5, 0.5, 1.0)

        let empty = try PlotExporter.saveFullPlot(
            iz: [], cz: [], vr: [], stats: stats, to: folder.path, sessionID: "empty"
        )
        precondition(empty == nil)
        let emptyDirectoryContents = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        precondition(emptyDirectoryContents.isEmpty)

        let first = try PlotExporter.saveFullPlot(
            iz: iz, cz: cz, vr: vr, stats: stats, to: folder.path, sessionID: "first"
        )!
        precondition(first == folder.appendingPathComponent("rng_session_first.png").path)
        let originalData = try Data(contentsOf: URL(fileURLWithPath: first))
        precondition(Array(originalData.prefix(8)) == [137, 80, 78, 71, 13, 10, 26, 10])
        guard let originalImage = NSBitmapImageRep(data: originalData) else {
            preconditionFailure("Saved PNG could not be decoded")
        }
        precondition(originalImage.pixelsWide > 0 && originalImage.pixelsHigh > 0)
        precondition(originalImage.pixelsWide == originalImage.pixelsHigh * 4)

        // Mirrored ones counts can have the same directed Z values (MORE 0s versus MORE 1s).
        // The complete exported image must depend on those directed values, not rederive cZ.
        var mirroredStats = stats
        mirroredStats.totalOnes = 24
        let second = try PlotExporter.saveFullPlot(
            iz: iz, cz: cz, vr: vr, stats: mirroredStats, to: folder.path, sessionID: "second"
        )!
        guard let secondImage = NSBitmapImageRep(data: try Data(contentsOf: URL(fileURLWithPath: second))) else {
            preconditionFailure("Second PNG could not be decoded")
        }
        precondition(originalImage.pixelsWide == secondImage.pixelsWide)
        precondition(originalImage.pixelsHigh == secondImage.pixelsHigh)
        precondition(originalImage.bytesPerRow == secondImage.bytesPerRow)
        let pixelCount = originalImage.bytesPerRow * originalImage.pixelsHigh
        guard let firstPixels = originalImage.bitmapData, let secondPixels = secondImage.bitmapData else {
            preconditionFailure("PNG pixel data was unavailable")
        }
        precondition(Data(bytes: firstPixels, count: pixelCount) == Data(bytes: secondPixels, count: pixelCount))

        do {
            _ = try PlotExporter.saveFullPlot(
                iz: [-4, 4], cz: [-1, 1], vr: [1, 2], stats: stats,
                to: folder.path, sessionID: "first"
            )
            preconditionFailure("Existing plot was overwritten")
        } catch {
            precondition((error as NSError).domain == NSCocoaErrorDomain)
            precondition((error as NSError).code == NSFileWriteFileExistsError)
        }
        let preservedData = try Data(contentsOf: URL(fileURLWithPath: first))
        precondition(preservedData == originalData)

        do {
            _ = try PlotExporter.saveFullPlot(
                iz: iz, cz: cz, vr: vr, stats: stats,
                to: folder.appendingPathComponent("missing", isDirectory: true).path,
                sessionID: "missing-folder"
            )
            preconditionFailure("Missing output directory did not fail")
        } catch {
            precondition((error as NSError).domain == NSCocoaErrorDomain)
        }

        try compareFullCanvas(in: folder)
        try testDestinationRace(in: folder)
        let residue = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        precondition(!residue.contains { $0.hasPrefix(".qcicada-") }, "Temporary export files survived")
        print("PASS: background rendering, empty session, PNG decoding, stable dimensions and directed-Z pixels, collision preserves bytes, missing directory throws")
    }


    nonisolated private static func runRasterChecks() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("QcicadaRasterLayoutTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try testRasterLayout(in: folder)
    }

    /// Exercise the disk transpose independently of graphics rendering or compression.
    /// Source rows include left insets and right padding that must never reach the PNG.
    nonisolated private static func testRasterLayout(in folder: URL) throws {
        let cases: [(rowBytes: [Int], height: Int)] = [
            ([4], 1),
            ([65_532], 1),
            ([65_536], 1),
            ([65_540], 1),
            ([4096, 4096, 4], 17),
            ([65_540, 4], 3),
            ([4, 65_540], 3),
            ([8, 12, 4], 1100), // More rows than one vectored read or write accepts.
        ]
        func pixelByte(row: Int, column: Int) -> UInt8 {
            UInt8(truncatingIfNeeded: row * 131 + column * 17 + (column >> 8) * 29 + (column >> 16) * 7)
        }
        for (caseIndex, fixture) in cases.enumerated() {
            let url = folder.appendingPathComponent("raster-layout-\(caseIndex).bin")
            precondition(FileManager.default.createFile(atPath: url.path, contents: nil))
            let file = try FileHandle(forUpdating: url)
            defer {
                try? file.close()
                try? FileManager.default.removeItem(at: url)
            }
            let totalRowBytes = fixture.rowBytes.reduce(0, +)
            let totalBytes = totalRowBytes * fixture.height
            var expected = Data(capacity: totalBytes)
            for row in 0..<fixture.height {
                for column in 0..<totalRowBytes { expected.append(pixelByte(row: row, column: column)) }
            }

            // Lay every strip out first, as the exporter does before rendering.
            var strips: [PlotExporter.RasterStrip] = []
            var sources: [(pixels: [UInt8], inset: Int, stride: Int)] = []
            var globalColumn = 0
            var offset: UInt64 = 0
            for (stripIndex, rowBytes) in fixture.rowBytes.enumerated() {
                let inset = (stripIndex % 3 + 1) * 4
                let sourceStride = inset + rowBytes + 7 + stripIndex * 3
                var source = [UInt8](repeating: 0xD3, count: sourceStride * fixture.height)
                for row in 0..<fixture.height {
                    for column in 0..<rowBytes {
                        source[row * sourceStride + inset + column] = pixelByte(row: row, column: globalColumn + column)
                    }
                }
                strips.append(PlotExporter.RasterStrip(offset: offset, rowBytes: rowBytes))
                sources.append((source, inset, sourceStride))
                offset += UInt64(rowBytes * fixture.height)
                globalColumn += rowBytes
            }
            // Strips are stored by several threads, so their order must not matter:
            // store the last one first. Each strip goes to its own place, which makes
            // the file reach its final size with the very first one.
            for index in strips.indices.reversed() {
                try sources[index].pixels.withUnsafeBufferPointer { pixels in
                    try PlotExporter.writeRasterStrip(strips[index], to: file,
                                                      pixels: pixels.baseAddress! + sources[index].inset,
                                                      sourceBytesPerRow: sources[index].stride, height: fixture.height)
                }
                let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! NSNumber
                precondition(size.uint64Value == UInt64(totalBytes),
                             "A strip was not stored at its own offset, or padding or a guard band reached the raster file")
            }

            // Rebuild the image the way the encoder gathers a band of scanlines: one
            // row at a time, a few rows, and the whole image at once.
            for bandRows in Set([1, 5, fixture.height]) {
                var reconstructed = [UInt8](repeating: 0xEE, count: totalBytes)
                var row = 0
                while row < fixture.height {
                    let rows = min(bandRows, fixture.height - row)
                    var column = 0
                    for strip in strips {
                        try reconstructed.withUnsafeMutableBytes { buffer in
                            try PlotExporter.readRasterRows(from: file, strip: strip, rows: row..<(row + rows),
                                                            into: buffer.baseAddress! + row * totalRowBytes + column,
                                                            stride: totalRowBytes)
                        }
                        column += strip.rowBytes
                    }
                    row += rows
                }
                precondition(Data(reconstructed) == expected, "Strip storage changed row order, columns, or RGBA bytes")
            }

            // Exercise both a short final read and a missing final row.
            let last = strips.last!
            var scratch = [UInt8](repeating: 0, count: last.rowBytes)
            for truncatedSize in [UInt64(totalBytes - 1), last.offset + UInt64((fixture.height - 1) * last.rowBytes)] {
                try file.truncate(atOffset: truncatedSize)
                do {
                    try scratch.withUnsafeMutableBytes { buffer in
                        try PlotExporter.readRasterRows(from: file, strip: last,
                                                        rows: (fixture.height - 1)..<fixture.height,
                                                        into: buffer.baseAddress!, stride: last.rowBytes)
                    }
                    preconditionFailure("Truncated raster was accepted as a complete row")
                } catch {
                    precondition((error as NSError).domain == NSCocoaErrorDomain)
                    precondition((error as NSError).code == NSFileReadCorruptFileError)
                }
            }
        }
        print("PASS: raster strip layout, out-of-order strip storage, inset/padding exclusion, narrow final strip, 64 KiB boundaries, banded readback past the vectored-I/O limit, exact row bytes, size, and truncated-read errors")
    }

    /// Core Graphics draws a long line in batches. The exporter strokes only the
    /// batches a strip can show, so every list of pieces must cover the series and
    /// render exactly what one stroke of the whole series renders in that strip.
    nonisolated private static func testStrokePieces() {
        var state: UInt64 = 0x9E3779B97F4A7C15
        func sample() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(UInt64.max >> 11) * 6 - 3
        }
        let formats: [(depth: Int, bytesPerPixel: Int, space: CFString, info: UInt32)] = [
            (8, 4, CGColorSpace.sRGB, CGImageAlphaInfo.premultipliedLast.rawValue),
            (16, 8, CGColorSpace.extendedSRGB, CGImageAlphaInfo.premultipliedLast.rawValue
                | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
        ]
        var comparisons = 0
        for count in [1, 2, 3, 128, 129, 256, 257, 258, 381, 382, 1000, 2400] {
            let values = (0..<count).map { _ in sample() }
            let width = max(3600, Double(count) * 3)
            let rect = CGRect(x: 60, y: 100, width: width - 120, height: 380)
            func point(_ index: Int) -> CGPoint {
                CGPoint(x: rect.minX + CGFloat(index) / CGFloat(max(1, count - 1)) * rect.width,
                        y: rect.minY + CGFloat((values[index] + 3) / 6) * rect.height)
            }
            let everything = PlotExporter.strokePieces(count: count, rect: rect, clip: .infinite)
            precondition(everything.first?.lowerBound == 0 && everything.last?.upperBound == count - 1,
                         "The pieces do not cover the series")
            for (piece, next) in zip(everything, everything.dropFirst()) {
                precondition(piece.upperBound == next.lowerBound, "Consecutive pieces must share their boundary sample")
            }
            for left in Set([0, 992, 2016, max(0, Int(width) - 1088)]) {
                let clip = CGRect(x: left, y: 0, width: min(1088, Int(width) - left), height: 600)
                for format in formats {
                    func render(_ pieces: [ClosedRange<Int>]) -> Data {
                        let pixelsWide = Int(clip.width) * 2, pixelsHigh = Int(clip.height) * 2
                        let context = CGContext(data: nil, width: pixelsWide, height: pixelsHigh,
                                                bitsPerComponent: format.depth,
                                                bytesPerRow: pixelsWide * format.bytesPerPixel,
                                                space: CGColorSpace(name: format.space)!, bitmapInfo: format.info)!
                        context.scaleBy(x: 2, y: 2)
                        context.translateBy(x: -clip.minX, y: 0)
                        context.setFillColor(NSColor(white: 0.04, alpha: 1).cgColor)
                        context.fill(clip)
                        context.setStrokeColor(NSColor(red: 0, green: 1, blue: 0.67, alpha: 1).cgColor)
                        context.setLineWidth(0.8)
                        for piece in pieces {
                            context.move(to: point(piece.lowerBound))
                            for index in piece.dropFirst() { context.addLine(to: point(index)) }
                            context.strokePath()
                        }
                        return Data(bytes: context.data!, count: pixelsWide * format.bytesPerPixel * pixelsHigh)
                    }
                    let whole = render([0...(count - 1)])
                    let visible = render(PlotExporter.strokePieces(count: count, rect: rect,
                                                                   clip: clip))
                    precondition(whole == visible,
                                 "Stroking the visible batches changed pixels: \(count) samples, strip at \(left), \(format.depth)-bit")
                    comparisons += 1
                }
            }
        }
        print("PASS: stroke pieces cover each series and match one whole-series stroke exactly in \(comparisons) strip renderings, 8-bit and 16-bit float, across the Core Graphics batching boundaries")
    }

    /// The faster intermediate PNG conversion must preserve the old conversion's
    /// exact pixels and color metadata, including AppKit's extended-color input.
    nonisolated private static func testConvertedBitmap() {
        precondition(!Thread.isMainThread, "Color conversion checks must exercise background rendering")
        let format = autoreleasepool { () -> (CGColorSpace, CGBitmapInfo, Int, Int, NSColorSpace) in
            let probe = NSImage(size: NSSize(width: 1, height: 1))
            probe.lockFocus()
            let context = NSGraphicsContext.current!.cgContext
            let color = context.colorSpace!
            let info = context.bitmapInfo
            let depth = context.bitsPerComponent
            let bytesPerPixel = context.bitsPerPixel / 8
            probe.unlockFocus()
            let tag = NSBitmapImageRep(data: probe.tiffRepresentation!)!.colorSpace
            return (color, info, depth, bytesPerPixel, tag)
        }
        func decode(_ data: Data) -> NSBitmapImageRep {
            let options = [kCGImageSourceShouldCache: false] as CFDictionary
            let source = CGImageSourceCreateWithData(data as CFData, options)!
            return NSBitmapImageRep(cgImage: CGImageSourceCreateImageAtIndex(source, 0, options)!)
        }
        let count = 2400
        var state: UInt64 = 0x123456789ABCDEF
        let random = (0..<count).map { _ -> Double in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(UInt64.max >> 11) * 8 - 4
        }
        var spikes = [Double](repeating: 0, count: count)
        for index in stride(from: 50, to: count - 1, by: 43) {
            spikes[index] = 8
            spikes[index + 1] = -8
        }
        let fixtures = [[Double](repeating: 0.5, count: count), spikes, random]
        let canvasWidth = count * 3
        for scale in [1, 2] {
            for values in fixtures {
                let variance = values.map { abs($0) + 0.5 }
                let ranges = PlotExporter.chartRanges(iz: values, cz: values, vr: variance)
                // First, interior, and narrow final strip retain the production overlap.
                for origin in [0, 3072, 7168] {
                    autoreleasepool {
                        let left = max(0, origin - 32)
                        let right = min(canvasWidth, min(canvasWidth, origin + 1024) + 32)
                        let width = (right - left) * scale, height = 900 * scale
                        let context = CGContext(data: nil, width: width, height: height,
                                                bitsPerComponent: format.2,
                                                bytesPerRow: width * format.3,
                                                space: format.0, bitmapInfo: format.1.rawValue)!
                        context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
                        context.translateBy(x: -CGFloat(left), y: 0)
                        NSGraphicsContext.saveGraphicsState()
                        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
                        PlotExporter.drawScene(ctx: context, iz: values, cz: values, vr: variance,
                                               stats: (count, count * 65536, count * 32768, 8, -8, 8, -8, 0, 1),
                                               width: Double(canvasWidth), height: 900, ranges: ranges)
                        NSGraphicsContext.restoreGraphicsState()
                        let source = NSBitmapImageRep(cgImage: context.makeImage()!).retagging(with: format.4)!
                        let previousPNG = source.representation(using: .png, properties: [.compressionFactor: 0.9])!
                        let before = decode(previousPNG)
                        let after = PlotExporter.convertedBitmap(source)!
                        precondition(before.pixelsWide == after.pixelsWide && before.pixelsHigh == after.pixelsHigh)
                        precondition(before.pixelsWide == width && before.pixelsHigh == height)
                        precondition(before.bitsPerSample == after.bitsPerSample && after.bitsPerSample == 8)
                        precondition(before.samplesPerPixel == after.samplesPerPixel && after.samplesPerPixel == 4)
                        precondition(before.bitmapFormat == after.bitmapFormat && before.isPlanar == after.isPlanar)
                        precondition(before.colorSpace.iccProfileData == after.colorSpace.iccProfileData,
                                     "Intermediate PNG conversion changed the ICC profile")
                        precondition(before.bytesPerRow == after.bytesPerRow)
                        precondition(memcmp(before.bitmapData!, after.bitmapData!, before.bytesPerRow * height) == 0,
                                     "Intermediate PNG conversion changed RGBA bytes")
                    }
                }
            }
        }
        print("PASS: exact legacy/new color conversion at 1x/2x, flat/spike/random data, first/interior/final strips, identical RGBA/ICC/bit depth")
    }

    nonisolated private static func compareFullCanvas(in folder: URL) throws {
        let count = 2400
        let iz = (0..<count).map { sin(Double($0) * 0.031) * 3 }
        let cz = (0..<count).map { cos(Double($0) * 0.002) * 1.5 }
        let vr = (0..<count).map { 1 + sin(Double($0) * 0.003) * 0.1 }
        let stats: PlotExporter.Stats = (count, count * 65536, count * 32768, 3, -3, 1.5, -1.5, 0, 1)
        let width = Double(count * 3), height = 900.0
        // This small reference uses the original full-canvas NSImage/TIFF path.
        // The production path never allocates this full-size bitmap.
        let reference = NSImage(size: NSSize(width: width, height: height))
        reference.lockFocus()
        PlotExporter.drawScene(ctx: NSGraphicsContext.current!.cgContext,
                               iz: iz, cz: cz, vr: vr, stats: stats, width: width, height: height,
                               ranges: PlotExporter.chartRanges(iz: iz, cz: cz, vr: vr))
        reference.unlockFocus()
        let bitmap = NSBitmapImageRep(data: reference.tiffRepresentation!)!
        let referencePNG = bitmap.representation(using: .png, properties: [.compressionFactor: 0.9])!
        let before = NSBitmapImageRep(data: referencePNG)!
        let path = try PlotExporter.saveFullPlot(iz: iz, cz: cz, vr: vr, stats: stats,
                                                 to: folder.path, sessionID: "full-canvas-comparison")!
        let after = NSBitmapImageRep(data: try Data(contentsOf: URL(fileURLWithPath: path)))!
        precondition(before.pixelsWide == after.pixelsWide && before.pixelsHigh == after.pixelsHigh)
        precondition(before.colorSpace.iccProfileData == after.colorSpace.iccProfileData)
        var changedPixels = 0
        var maximumDifference = 0
        for row in 0..<before.pixelsHigh {
            for column in 0..<before.pixelsWide {
                var changed = false
                for channel in 0..<4 {
                    let original = Int(before.bitmapData![row * before.bytesPerRow + column * 4 + channel])
                    let tiled = Int(after.bitmapData![row * after.bytesPerRow + column * 4 + channel])
                    if original != tiled { changed = true }
                    maximumDifference = max(maximumDifference, abs(original - tiled))
                }
                if changed { changedPixels += 1 }
            }
        }
        // Translating a Core Graphics rasterization can move a rounding boundary by
        // up to two 8-bit levels; require that it is rare and never changes geometry.
        precondition(maximumDifference <= 2)
        precondition(Double(changedPixels) / Double(before.pixelsWide * before.pixelsHigh) < 0.0001)
        try inspectPNG(URL(fileURLWithPath: path), width: after.pixelsWide, height: after.pixelsHigh)
        print("PASS: full-canvas comparison \(before.pixelsWide)x\(before.pixelsHigh), \(changedPixels) differing pixels, max \(maximumDifference)/255, identical ICC profile")
    }

    nonisolated private static func testDestinationRace(in folder: URL) throws {
        let target = folder.appendingPathComponent("rng_session_race.png")
        let sentinel = Data("preserve a concurrent writer".utf8)
        let created = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            let deadline = ProcessInfo.processInfo.systemUptime + 10
            while ProcessInfo.processInfo.systemUptime < deadline {
                let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
                if files.contains(where: { $0.hasPrefix(".qcicada-raster-") }) {
                    try! sentinel.write(to: target, options: .withoutOverwriting)
                    created.signal()
                    return
                }
                Thread.sleep(forTimeInterval: 0.001)
            }
            created.signal()
        }
        do {
            _ = try PlotExporter.saveFullPlot(iz: [0, 1, 2], cz: [0, 0.5, 1], vr: [1, 1, 1],
                                              stats: (3, 96, 48, 2, 0, 1, 0, 1, 1),
                                              to: folder.path, sessionID: "race")
            preconditionFailure("A destination created during export was overwritten")
        } catch {
            precondition((error as NSError).code == NSFileWriteFileExistsError)
        }
        precondition(created.wait(timeout: .now() + 10) == .success)
        let preserved = try Data(contentsOf: target)
        precondition(preserved == sentinel)
        let residue = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        precondition(!residue.contains { $0.hasPrefix(".qcicada-") })
        print("PASS: concurrent destination protected, staging files removed after late failure")
    }

    nonisolated private static func benchmark(samples: Int) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("QcicadaPlotMemory-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let iz = (0..<samples).map { sin(Double($0) * 0.031) * 3 }
        let cz = (0..<samples).map { cos(Double($0) * 0.002) * 1.5 }
        let vr = (0..<samples).map { 1 + sin(Double($0) * 0.003) * 0.1 }
        let began = ProcessInfo.processInfo.systemUptime
        let path = try PlotExporter.saveFullPlot(iz: iz, cz: cz, vr: vr,
                                                 stats: (samples, samples * 65536, samples * 32768, 3, -3, 1.5, -1.5, 0, 1),
                                                 to: folder.path, sessionID: "long")!
        let elapsed = ProcessInfo.processInfo.systemUptime - began
        let url = URL(fileURLWithPath: path)
        // Read IHDR directly. Even ImageIO's metadata-only PNG path may reserve
        // the complete raster and would contaminate the export memory measurement.
        let headerFile = try FileHandle(forReadingFrom: url)
        let header = try headerFile.read(upToCount: 24)!
        try headerFile.close()
        let width = Int(header[16..<20].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
        let height = Int(header[20..<24].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
        try inspectPNG(url, width: width, height: height)
        let contents = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        precondition(contents == [url.lastPathComponent], "Temporary files survived a successful export")
        print(String(format: "PASS: %d samples, %dx%d PNG, %.3f seconds export, %llu bytes for one full RGBA raster; streaming decode/CRC and temporary cleanup passed", samples, width, height, elapsed, UInt64(width) * UInt64(height) * 4))
    }

    /// Validate all chunk CRCs and decompress the entire image with a 64 KiB buffer.
    /// This verifies very wide images without undoing the memory fix in the test.
    nonisolated private static func inspectPNG(_ url: URL, width: Int, height: Int) throws {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        func read(_ count: Int) throws -> Data {
            let data = try file.read(upToCount: count) ?? Data()
            precondition(data.count == count, "Truncated PNG")
            return data
        }
        func number(_ data: Data) -> UInt32 {
            data.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        }
        let signature = try read(8)
        precondition(signature == Data([137, 80, 78, 71, 13, 10, 26, 10]))
        var stream = z_stream()
        precondition(inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK)
        defer { inflateEnd(&stream) }
        var output = [UInt8](repeating: 0, count: 65_536)
        var decompressed: UInt64 = 0
        var ended = false
        while true {
            let length = Int(number(try read(4)))
            let kind = try read(4)
            let payload = try read(length)
            let expectedCRC = number(try read(4))
            var crc = kind.withUnsafeBytes { crc32(0, $0.bindMemory(to: Bytef.self).baseAddress!, 4) }
            if !payload.isEmpty {
                crc = payload.withUnsafeBytes { crc32(crc, $0.bindMemory(to: Bytef.self).baseAddress!, uInt(payload.count)) }
            }
            precondition(UInt32(crc) == expectedCRC, "PNG chunk CRC mismatch")
            if kind == Data("IHDR".utf8) {
                precondition(number(payload.prefix(4)) == width && number(payload.dropFirst(4).prefix(4)) == height)
                precondition(payload[8] == 8 && payload[9] == 6)
            } else if kind == Data("IDAT".utf8) {
                payload.withUnsafeBytes { input in
                    stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress!)
                    stream.avail_in = uInt(payload.count)
                    defer { stream.next_in = nil }
                    repeat {
                        let code = output.withUnsafeMutableBufferPointer { buffer in
                            stream.next_out = buffer.baseAddress!
                            stream.avail_out = uInt(buffer.count)
                            return inflate(&stream, Z_NO_FLUSH)
                        }
                        precondition(code == Z_OK || code == Z_STREAM_END || (code == Z_BUF_ERROR && stream.avail_in == 0))
                        decompressed += UInt64(output.count) - UInt64(stream.avail_out)
                        if code == Z_STREAM_END { ended = true }
                    } while stream.avail_in > 0 || stream.avail_out == 0
                }
            } else if kind == Data("IEND".utf8) { break }
        }
        precondition(ended && decompressed == (UInt64(width) * 4 + 1) * UInt64(height))
        let trailing = try file.read(upToCount: 1) ?? Data()
        precondition(trailing.isEmpty)
    }
}
