// PlotExporter.swift
// Qcicada
//
// Exports full-session waveform as a high-resolution PNG.
// Uses Core Graphics for rendering — no matplotlib dependency.
// Width scales with data count, no upper limit.

import AppKit
import Foundation
import zlib
import ImageIO

nonisolated final class PlotExporter {
    enum ExportError: LocalizedError {
        case renderingFailed
        case bitmapCreationFailed
        case pngEncodingFailed
        case inconsistentBackingScale

        var errorDescription: String? {
            switch self {
            case .renderingFailed:
                return "Could not create the plot graphics context."
            case .bitmapCreationFailed:
                return "Could not create the plot bitmap."
            case .pngEncodingFailed:
                return "Could not encode the plot as PNG."
            case .inconsistentBackingScale:
                return "The display backing scale changed while the plot was being exported. Please retry."
            }
        }
    }
    
    typealias Stats = (
        sampleCount: Int,
        totalBits: Int,
        totalOnes: Int,
        peakInstHi: Double,
        peakInstLo: Double,
        peakCumHi: Double,
        peakCumLo: Double,
        izMean: Double,
        izVariance: Double
    )
    
    static func saveFullPlot(
        iz: [Double],
        cz: [Double],
        vr: [Double],
        stats: Stats,
        to directory: String,
        sessionID: String? = nil
    ) throws -> String? {
        guard !iz.isEmpty else { return nil }
        
        let width = max(3600, Double(iz.count) * 3)
        let height = 900.0
        let directoryURL = URL(fileURLWithPath: directory, isDirectory: true)
        let filename = "rng_session_\(sessionID ?? dateString()).png"
        let destination = directoryURL.appendingPathComponent(filename)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: destination.path])
        }
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CocoaError(.fileWriteInvalidFileName, userInfo: [NSFilePathErrorKey: directory])
        }
        // Keep the existing NSImage backing scale and color conversion. A small probe
        // avoids allocating the full image merely to discover its representation.
        let format = try autoreleasepool { () throws -> (scale: Double, colorSpace: NSColorSpace) in
            let probe = NSImage(size: NSSize(width: 1, height: 1))
            probe.lockFocus()
            guard let context = NSGraphicsContext.current?.cgContext else {
                probe.unlockFocus()
                throw ExportError.renderingFailed
            }
            let scale = Double(context.ctm.a)
            probe.unlockFocus()
            guard let tiff = probe.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else {
                throw ExportError.bitmapCreationFailed
            }
            return (scale, bitmap.colorSpace)
        }
        let scale = format.scale
        let pixelWidthValue = width * scale
        let pixelHeightValue = height * scale
        guard scale > 0, scale.isFinite,
              pixelWidthValue <= Double(Int32.max), pixelHeightValue <= Double(Int32.max),
              pixelWidthValue.rounded() == pixelWidthValue,
              pixelHeightValue.rounded() == pixelHeightValue else {
            throw StreamingPNGWriter.EncodingError.invalidImage
        }
        let pixelWidth = Int(pixelWidthValue), pixelHeight = Int(pixelHeightValue)
        let rasterBytes = UInt64(pixelWidth) * UInt64(pixelHeight) * 4
        let inputBytes = rasterBytes + UInt64(pixelHeight) // One filter byte per row.
        let encodedBound = UInt64(compressBound(uLong(inputBytes)))
        // Each independently compressed piece also ends with a few flush bytes.
        let segmentOverhead = (inputBytes / UInt64(segmentBytes) + inputBytes / UInt64(bandBytes) + 2) * 32
        let chunkOverhead = (encodedBound / 65_536 + 1) * 12 + 65_536
        let requiredSpace = rasterBytes + encodedBound + segmentOverhead + chunkOverhead
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: directory)
        if let available = attributes[.systemFreeSize] as? NSNumber,
           available.uint64Value < requiredSpace {
            throw CocoaError(.fileWriteOutOfSpace, userInfo: [NSFilePathErrorKey: directory])
        }

        let rasterURL = directoryURL.appendingPathComponent(".qcicada-raster-\(UUID().uuidString)")
        let pngURL = directoryURL.appendingPathComponent(".qcicada-png-\(UUID().uuidString)")
        let raster = try createTemporaryFile(at: rasterURL)
        defer {
            try? raster.close()
            try? FileManager.default.removeItem(at: rasterURL)
        }
        let png = try createTemporaryFile(at: pngURL)
        defer {
            try? png.close()
            try? FileManager.default.removeItem(at: pngURL)
        }
        let ranges = chartRanges(iz: iz, cz: cz, vr: vr)
        // This is a working-buffer size, not an image width or sample-count limit.
        // A guard band preserves continuous strokes across strip boundaries.
        let tileWidth = 1024
        // Align the overlap with AppKit's 32-pixel color-conversion dither pattern
        // at the standard 1x/2x backing scales, preserving its global phase.
        let guardBand = 32
        // Every strip's place in the raster store is known before rendering, so the
        // tiles are independent and can be rendered and stored on several threads.
        var tiles: [(origin: Int, left: Int, right: Int)] = []
        var strips: [RasterStrip] = []
        var stripOffset: UInt64 = 0
        for origin in stride(from: 0, to: Int(width), by: tileWidth) {
            let end = min(Int(width), origin + tileWidth)
            tiles.append((origin, max(0, origin - guardBand), min(Int(width), end + guardBand)))
            let strip = RasterStrip(offset: stripOffset, rowBytes: Int(Double(end - origin) * scale) * 4)
            strips.append(strip)
            stripOffset += UInt64(strip.rowBytes) * UInt64(pixelHeight)
        }
        guard stripOffset == rasterBytes else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: rasterURL.path])
        }
        let profile = ColorProfileBox()
        try forEachConcurrently(count: tiles.count, workers: workerCount) { index in
            try autoreleasepool {
                let (origin, left, right) = tiles[index]
                let tile = NSImage(size: NSSize(width: right - left, height: Int(height)))
                tile.lockFocus()
                guard let context = NSGraphicsContext.current?.cgContext else {
                    tile.unlockFocus()
                    throw ExportError.renderingFailed
                }
                context.translateBy(x: -CGFloat(left), y: 0)
                drawScene(ctx: context, iz: iz, cz: cz, vr: vr, stats: stats,
                          width: width, height: height, ranges: ranges)
                tile.unlockFocus()
                // Preserve the old extended/HDR-to-PNG color conversion. Retag the
                // direct backing image with the TIFF probe's color space: decoding
                // a new TIFF per strip makes ImageIO retain large decoded-image caches.
                guard let cgImage = tile.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                    throw ExportError.bitmapCreationFailed
                }
                guard let source = NSBitmapImageRep(cgImage: cgImage).retagging(with: format.colorSpace),
                      let bitmap = convertedBitmap(source),
                      let pixels = bitmap.bitmapData else { throw ExportError.bitmapCreationFailed }
                guard bitmap.pixelsWide == Int(Double(right - left) * scale), bitmap.pixelsHigh == pixelHeight else {
                    throw ExportError.inconsistentBackingScale
                }
                guard bitmap.bitsPerSample == 8, bitmap.samplesPerPixel == 4,
                      !bitmap.isPlanar, !bitmap.bitmapFormat.contains(.alphaFirst),
                      bitmap.bitmapFormat.contains(.alphaNonpremultiplied) else {
                    throw StreamingPNGWriter.EncodingError.invalidImage
                }
                if index == 0 { profile.set(bitmap.colorSpace.iccProfileData) }
                let inset = Int(Double(origin - left) * scale) * 4
                try writeRasterStrip(strips[index], to: raster, pixels: pixels + inset,
                                     sourceBytesPerRow: bitmap.bytesPerRow, height: pixelHeight)
            }
        }
        let encoder = try StreamingPNGWriter(file: png, width: pixelWidth, height: pixelHeight,
                                             pixelsPerPoint: scale, colorProfile: profile.value)
        // Compression works on small pieces of one shared band, so it can use every core.
        try encodeRaster(from: raster, strips: strips, height: pixelHeight, into: encoder,
                         workers: ProcessInfo.processInfo.activeProcessorCount)
        try encoder.finish()
        try png.synchronize()
        try png.close()
        // Same-volume, exclusive rename publishes only a complete image, and cannot
        // overwrite a file another window created while this export was running.
        guard renamex_np(pngURL.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            let number = errno
            if number == EEXIST {
                throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: destination.path])
            }
            throw POSIXError(POSIXErrorCode(rawValue: number) ?? .EIO)
        }
        return destination.path
    }

    struct RasterStrip {
        let offset: UInt64
        let rowBytes: Int
    }

    /// Strips rendered and converted at once. Each one in progress holds several
    /// full-depth copies of its bitmap inside ImageIO (about 140 MB at 2x), so the
    /// count is bounded instead of following the core count: the export's working
    /// memory stays the same on every machine and for every session length.
    static var workerCount: Int { max(1, min(ProcessInfo.processInfo.activeProcessorCount, 4)) }

    /// Scanline bytes gathered before compression. Reading this much of every strip
    /// at a time turns the strip store's row-order readback into large sequential
    /// reads; a single scanline wider than this is still read whole.
    static let bandBytes = 64 << 20
    /// Size of the independently compressed pieces of a band.
    static let segmentBytes = 1 << 20

    /// Runs `body` once for every index on at most `workers` threads. The first
    /// failure stops further work and is rethrown after running work has ended.
    static func forEachConcurrently(count: Int, workers: Int, _ body: (Int) throws -> Void) throws {
        guard count > 0 else { return }
        let progress = WorkProgress(count: count)
        DispatchQueue.concurrentPerform(iterations: max(1, min(workers, count))) { _ in
            while let index = progress.next() {
                do { try body(index) } catch { progress.fail(error) }
            }
        }
        if let error = progress.failure { throw error }
    }

    private final class WorkProgress: @unchecked Sendable {
        private let lock = NSLock()
        private let count: Int
        private var index = 0
        private var error: (any Error)?

        init(count: Int) { self.count = count }
        var failure: (any Error)? { lock.withLock { error } }
        func fail(_ failure: any Error) { lock.withLock { if error == nil { error = failure } } }
        func next() -> Int? {
            lock.withLock {
                guard error == nil, index < count else { return nil }
                defer { index += 1 }
                return index
            }
        }
    }

    private final class ColorProfileBox: @unchecked Sendable {
        private let lock = NSLock()
        private var data: Data?
        var value: Data? { lock.withLock { data } }
        func set(_ profile: Data?) { lock.withLock { data = profile } }
    }

    private final class SegmentBox: @unchecked Sendable {
        private let lock = NSLock()
        private var segments: [StreamingPNGWriter.Segment?]
        init(count: Int) { segments = Array(repeating: nil, count: count) }
        func set(_ segment: StreamingPNGWriter.Segment, at index: Int) { lock.withLock { segments[index] = segment } }
        func take() -> [StreamingPNGWriter.Segment?] { lock.withLock { segments } }
    }

    /// Store one strip contiguously at its own place in the raster store, without
    /// the guard bands and bitmap padding. Strips may be written in any order and
    /// from several threads; the rows go straight from the bitmap to the file.
    static func writeRasterStrip(_ strip: RasterStrip, to file: FileHandle, pixels: UnsafePointer<UInt8>,
                                 sourceBytesPerRow: Int, height: Int) throws {
        guard strip.rowBytes > 0, height > 0, sourceBytesPerRow >= strip.rowBytes else {
            throw StreamingPNGWriter.EncodingError.invalidImage
        }
        let descriptor = file.fileDescriptor
        var row = 0
        var vectors: [iovec] = []
        vectors.reserveCapacity(min(height, Int(IOV_MAX)))
        while row < height {
            let rows = min(height - row, Int(IOV_MAX))
            vectors.removeAll(keepingCapacity: true)
            for index in row..<(row + rows) {
                vectors.append(iovec(iov_base: UnsafeMutableRawPointer(mutating: pixels + index * sourceBytesPerRow),
                                     iov_len: strip.rowBytes))
            }
            let position = strip.offset + UInt64(row) * UInt64(strip.rowBytes)
            let expected = rows * strip.rowBytes
            var written = pwritev(descriptor, vectors, Int32(rows), off_t(position))
            while written < 0 && errno == EINTR {
                written = pwritev(descriptor, vectors, Int32(rows), off_t(position))
            }
            guard written >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            // Finish a partially accepted batch one contiguous piece at a time.
            var done = written
            while done < expected {
                let column = done % strip.rowBytes
                let source = pixels + (row + done / strip.rowBytes) * sourceBytesPerRow + column
                let count = pwrite(descriptor, source, strip.rowBytes - column, off_t(position) + off_t(done))
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw POSIXError(POSIXErrorCode(rawValue: count < 0 ? errno : EIO) ?? .EIO) }
                done += count
            }
            row += rows
        }
    }

    /// Read consecutive rows of one strip, which are contiguous in the raster store,
    /// placing row `rows.lowerBound + n` at `destination + n * stride`. A store that
    /// ends before the requested rows is reported as corrupt.
    static func readRasterRows(from file: FileHandle, strip: RasterStrip, rows: Range<Int>,
                               into destination: UnsafeMutableRawPointer, stride: Int) throws {
        guard strip.rowBytes > 0, rows.lowerBound >= 0, stride >= strip.rowBytes || rows.count <= 1 else {
            throw StreamingPNGWriter.EncodingError.invalidImage
        }
        let descriptor = file.fileDescriptor
        var row = rows.lowerBound
        var vectors: [iovec] = []
        vectors.reserveCapacity(min(rows.count, Int(IOV_MAX)))
        while row < rows.upperBound {
            let count = min(rows.upperBound - row, Int(IOV_MAX))
            let target = destination + (row - rows.lowerBound) * stride
            vectors.removeAll(keepingCapacity: true)
            for index in 0..<count {
                vectors.append(iovec(iov_base: target + index * stride, iov_len: strip.rowBytes))
            }
            let position = strip.offset + UInt64(row) * UInt64(strip.rowBytes)
            let expected = count * strip.rowBytes
            var received = preadv(descriptor, vectors, Int32(count), off_t(position))
            while received < 0 && errno == EINTR {
                received = preadv(descriptor, vectors, Int32(count), off_t(position))
            }
            guard received >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            // Finish a short read one contiguous piece at a time; end of file is corruption.
            var done = received
            while done < expected {
                let column = done % strip.rowBytes
                let piece = target + (done / strip.rowBytes) * stride + column
                let length = pread(descriptor, piece, strip.rowBytes - column, off_t(position) + off_t(done))
                if length < 0 && errno == EINTR { continue }
                guard length >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                guard length > 0 else { throw CocoaError(.fileReadCorruptFile) }
                done += length
            }
            row += count
        }
    }

    /// Turn the strip store into PNG scanlines (filter None) and compress them.
    /// A band of scanlines is gathered with one sequential read per strip, then its
    /// pieces are compressed on several threads and appended in image order.
    static func encodeRaster(from file: FileHandle, strips: [RasterStrip], height: Int,
                             into encoder: StreamingPNGWriter, workers: Int) throws {
        let scanline = strips.reduce(1) { $0 + $1.rowBytes } // One filter byte per row.
        guard !strips.isEmpty, height > 0, scanline > 1 else {
            throw StreamingPNGWriter.EncodingError.invalidImage
        }
        var columns: [Int] = []
        var column = 1
        for strip in strips {
            columns.append(column)
            column += strip.rowBytes
        }
        let rowsPerBand = max(1, min(height, bandBytes / scanline))
        let band = UnsafeMutableRawBufferPointer.allocate(byteCount: rowsPerBand * scanline, alignment: 16)
        defer { band.deallocate() }
        var row = 0
        while row < height {
            let rows = min(rowsPerBand, height - row)
            for index in 0..<rows { band[index * scanline] = 0 } // PNG filter None.
            try forEachConcurrently(count: strips.count, workers: workers) { index in
                try readRasterRows(from: file, strip: strips[index], rows: row..<(row + rows),
                                   into: band.baseAddress! + columns[index], stride: scanline)
            }
            let length = rows * scanline
            let count = (length + segmentBytes - 1) / segmentBytes
            let segments = SegmentBox(count: count)
            try forEachConcurrently(count: count, workers: workers) { index in
                let start = index * segmentBytes
                let piece = UnsafeRawBufferPointer(rebasing: band[start..<min(length, start + segmentBytes)])
                segments.set(try StreamingPNGWriter.compress(piece), at: index)
            }
            for segment in segments.take() {
                guard let segment else { throw StreamingPNGWriter.EncodingError.invalidImage }
                try encoder.append(segment)
            }
            row += rows
        }
    }

    static func convertedBitmap(_ source: NSBitmapImageRep) -> NSBitmapImageRep? {
        // ImageIO retains the existing HDR-to-8-bit conversion and ICC profile.
        // This PNG is only an intermediate: skip predictor selection while keeping
        // its compression lossless, then decode without retaining an image cache.
        guard let image = source.cgImage else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
            return nil
        }
        let properties = [kCGImagePropertyPNGDictionary: [
            kCGImagePropertyPNGCompressionFilter: Int(IMAGEIO_PNG_FILTER_NONE)
        ]] as CFDictionary
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return uncachedBitmap(data as Data)
    }

    private static func uncachedBitmap(_ data: Data) -> NSBitmapImageRep? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options),
              let image = CGImageSourceCreateImageAtIndex(source, 0, options) else { return nil }
        return NSBitmapImageRep(cgImage: image)
    }

    private static func createTemporaryFile(at url: URL) throws -> FileHandle {
        let descriptor = Darwin.open(url.path, O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    struct ChartRanges {
        let iz: ClosedRange<Double>
        let cz: ClosedRange<Double>
        let vr: ClosedRange<Double>
    }

    static func chartRanges(iz: [Double], cz: [Double], vr: [Double]) -> ChartRanges {
        func bounds(_ values: [Double]) -> ClosedRange<Double> { (values.min() ?? 0)...(values.max() ?? 0) }
        return ChartRanges(iz: bounds(iz), cz: bounds(cz), vr: bounds(vr))
    }

    /// Shared drawing commands retain the original layout, style, and full path order.
    static func drawScene(ctx: CGContext, iz: [Double], cz: [Double], vr: [Double], stats: Stats,
                          width: Double, height: Double, ranges: ChartRanges) {
        // Chart areas: iz gets 45%, cz gets 35%, var gets 20%
        let izHeight = height * 0.42
        let czHeight = height * 0.33
        let vrHeight = height * 0.15
        let headerHeight = height * 0.10
        
        let margin: CGFloat = 60
        let chartWidth = width - margin * 2
        
        let size = NSSize(width: width, height: height)
        
        // Background
        ctx.setFillColor(NSColor(white: 0.06, alpha: 1.0).cgColor)
        ctx.fill(CGRect(origin: .zero, size: size))
        
        // Header text
        let headerAttrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white,
            .font: NSFont.systemFont(ofSize: 14, weight: .medium)
        ]
        let cumZ = cz.last ?? 0
        let headerText = "随机数测试 Full Session — QCicada QRNG  |  "
            + "samples=\(stats.sampleCount)  bits=\(stats.totalBits)  "
            + "iZ hi=\(String(format: "%+.2f", stats.peakInstHi)) lo=\(String(format: "%+.2f", stats.peakInstLo))  "
            + "cZ=\(String(format: "%+.4f", cumZ))  "
            + "mean=\(String(format: "%+.4f", stats.izMean))  var=\(String(format: "%.4f", stats.izVariance))"
        
        (headerText as NSString).draw(
            at: NSPoint(x: margin, y: height - headerHeight + 10),
            withAttributes: headerAttrs
        )
        
        // Draw charts
        let izOriginY = height - headerHeight - izHeight
        let czOriginY = izOriginY - czHeight - 10
        let vrOriginY = czOriginY - vrHeight - 10
        
        drawChart(ctx: ctx, data: iz, bounds: ranges.iz, rect: CGRect(x: margin, y: izOriginY, width: chartWidth, height: izHeight),
                  color: NSColor(red: 0.0, green: 1.0, blue: 0.67, alpha: 1.0), // green
                  label: "Instant Z", thresholds: [1.96, 2.58], refLine: 0)
        
        drawChart(ctx: ctx, data: cz, bounds: ranges.cz, rect: CGRect(x: margin, y: czOriginY, width: chartWidth, height: czHeight),
                  color: NSColor(red: 1.0, green: 0.67, blue: 0.0, alpha: 1.0), // orange
                  label: "Cumulative Z", thresholds: [1.96], refLine: 0)
        
        drawChart(ctx: ctx, data: vr, bounds: ranges.vr, rect: CGRect(x: margin, y: vrOriginY, width: chartWidth, height: vrHeight),
                  color: NSColor(red: 1.0, green: 0.4, blue: 0.6, alpha: 1.0), // pink
                  label: "Variance", thresholds: [], refLine: 1.0)
        
    }

    // MARK: - Draw single chart
    
    private static func drawChart(
        ctx: CGContext,
        data: [Double],
        bounds: ClosedRange<Double>,
        rect: CGRect,
        color: NSColor,
        label: String,
        thresholds: [Double],
        refLine: Double?
    ) {
        guard !data.isEmpty else { return }
        
        let n = data.count
        let mn = bounds.lowerBound
        let mx = bounds.upperBound
        let pad = max(0.5, (mx - mn) * 0.15)
        let yMin: Double
        let yMax: Double
        
        if let ref = refLine, ref > 0 {
            yMin = max(0, mn - pad)
            yMax = mx + pad
        } else {
            yMin = min(mn - pad, -2)
            yMax = max(mx + pad, 2)
        }
        
        let yRange = yMax - yMin
        guard yRange > 0 else { return }
        
        func xPos(_ i: Int) -> CGFloat {
            return rect.minX + CGFloat(i) / CGFloat(max(1, n - 1)) * rect.width
        }
        
        func yPos(_ v: Double) -> CGFloat {
            return rect.minY + CGFloat((v - yMin) / yRange) * rect.height
        }
        
        // Background
        ctx.setFillColor(NSColor(white: 0.04, alpha: 1.0).cgColor)
        ctx.fill(rect)
        
        // Reference line
        if let ref = refLine {
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.15).cgColor)
            ctx.setLineWidth(0.8)
            ctx.move(to: CGPoint(x: rect.minX, y: yPos(ref)))
            ctx.addLine(to: CGPoint(x: rect.maxX, y: yPos(ref)))
            ctx.strokePath()
        }
        
        // Threshold lines
        ctx.setStrokeColor(NSColor.yellow.withAlphaComponent(0.3).cgColor)
        ctx.setLineWidth(0.5)
        ctx.setLineDash(phase: 0, lengths: [6, 4])
        for t in thresholds {
            ctx.move(to: CGPoint(x: rect.minX, y: yPos(t)))
            ctx.addLine(to: CGPoint(x: rect.maxX, y: yPos(t)))
            ctx.move(to: CGPoint(x: rect.minX, y: yPos(-t)))
            ctx.addLine(to: CGPoint(x: rect.maxX, y: yPos(-t)))
        }
        ctx.strokePath()
        ctx.setLineDash(phase: 0, lengths: [])
        
        // Data line, drawn in the same pieces Core Graphics uses for the whole series.
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(0.8)
        for piece in strokePieces(count: n, rect: rect, clip: ctx.boundingBoxOfClipPath) {
            ctx.move(to: CGPoint(x: xPos(piece.lowerBound), y: yPos(data[piece.lowerBound])))
            for i in piece.dropFirst() {
                ctx.addLine(to: CGPoint(x: xPos(i), y: yPos(data[i])))
            }
            ctx.strokePath()
        }
        
        // Label
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: color,
            .font: NSFont.systemFont(ofSize: 11, weight: .medium)
        ]
        (label as NSString).draw(
            at: NSPoint(x: rect.minX + 4, y: rect.maxY - 16),
            withAttributes: labelAttrs
        )
        
        // Y-axis labels
        let axisAttrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.gray,
            .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .regular)
        ]
        let steps = 5
        for i in 0...steps {
            let v = yMin + yRange * Double(i) / Double(steps)
            let text = String(format: "%.1f", v)
            (text as NSString).draw(
                at: NSPoint(x: rect.minX - 36, y: yPos(v) - 5),
                withAttributes: axisAttrs
            )
        }
    }
    
    /// The sample ranges to stroke for a series of `count` points when only `clip`
    /// will be visible. Core Graphics strokes a line of up to 256 points in one piece
    /// and a longer one in consecutive batches of 127 segments, each drawn on its own
    /// with no join to the next. Stroking just the batches that can reach the clip
    /// therefore produces the same pixels as stroking the whole series, and makes a
    /// strip cost the same however long the session was.
    static func strokePieces(count: Int, rect: CGRect, clip: CGRect) -> [ClosedRange<Int>] {
        guard count > 0 else { return [] }
        let last = count - 1
        guard count > 256 else { return [0...last] }
        let batch = 127
        let finalBatch = (last - 1) / batch
        var visible = 0...finalBatch
        if rect.width > 0, !clip.isNull, !clip.isInfinite, clip.minX.isFinite, clip.maxX.isFinite {
            let step = rect.width / CGFloat(last)
            // Beyond the reach of a 0.8-point line's miter joins (limit 10) and antialiasing.
            let margin: CGFloat = 16
            let lower = ((clip.minX - margin - rect.minX) / step).rounded(.down) - 2
            let upper = ((clip.maxX + margin - rect.minX) / step).rounded(.up) + 2
            if lower.isFinite, upper.isFinite {
                let first = min(finalBatch, Int(min(CGFloat(last), max(0, lower))) / batch)
                visible = first...max(first, min(finalBatch, Int(min(CGFloat(last), max(0, upper))) / batch))
            }
        }
        return visible.map { ($0 * batch)...min(last, ($0 + 1) * batch) }
    }

    private static func dateString() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        return f.string(from: Date())
    }
}
