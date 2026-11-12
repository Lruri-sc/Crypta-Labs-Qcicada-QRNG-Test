import Foundation
import zlib

/// A PNG encoder that never holds the image. Scanline bytes are compressed in
/// independent pieces, which may be prepared on several threads, and are appended
/// in image order. It deliberately uses the system zlib default compression.
nonisolated final class StreamingPNGWriter {
    enum EncodingError: LocalizedError {
        case invalidImage
        case compressionFailed(Int32)

        var errorDescription: String? {
            switch self {
            case .invalidImage: return "The plot dimensions or pixel format cannot be encoded as PNG."
            case .compressionFailed(let code): return "Could not compress the plot PNG (zlib \(code))."
            }
        }
    }

    /// One compressed piece of the scanline stream, with what is needed to join it
    /// to its neighbours: the Adler-32 and length of the bytes it was made from.
    struct Segment {
        let deflated: Data
        let checksum: uLong
        let length: Int
    }

    private static let chunkCapacity = 65_536
    private let file: FileHandle
    private var pending = Data()
    private var checksum = adler32(0, nil, 0)
    private var finished = false

    init(file: FileHandle, width: Int, height: Int, pixelsPerPoint: Double, colorProfile: Data?) throws {
        guard width > 0, height > 0, width <= Int(Int32.max), height <= Int(Int32.max) else {
            throw EncodingError.invalidImage
        }
        self.file = file
        try file.write(contentsOf: Data([137, 80, 78, 71, 13, 10, 26, 10]))
        var header = Data()
        header.appendBigEndian(UInt32(width))
        header.appendBigEndian(UInt32(height))
        header.append(contentsOf: [8, 6, 0, 0, 0]) // 8-bit RGBA, no interlacing.
        try chunk("IHDR", payload: header)

        if let colorProfile, !colorProfile.isEmpty {
            var compressed = Data(count: Int(compressBound(uLong(colorProfile.count))))
            var length = uLongf(compressed.count)
            let result = compressed.withUnsafeMutableBytes { destination in
                colorProfile.withUnsafeBytes { source in
                    compress2(destination.bindMemory(to: Bytef.self).baseAddress!, &length,
                              source.bindMemory(to: Bytef.self).baseAddress!, uLong(colorProfile.count),
                              Z_DEFAULT_COMPRESSION)
                }
            }
            guard result == Z_OK else { throw EncodingError.compressionFailed(result) }
            compressed.count = Int(length)
            var profile = Data("ICC Profile".utf8)
            profile.append(contentsOf: [0, 0]) // NUL name terminator, zlib compression method.
            profile.append(compressed)
            try chunk("iCCP", payload: profile)
        }
        let pixelsPerMeter = UInt32((72 * pixelsPerPoint / 0.0254).rounded())
        var resolution = Data()
        resolution.appendBigEndian(pixelsPerMeter)
        resolution.appendBigEndian(pixelsPerMeter)
        resolution.append(1)
        try chunk("pHYs", payload: resolution)

        pending.reserveCapacity(Self.chunkCapacity)
        pending.append(contentsOf: [0x78, 0x9C]) // zlib header: deflate, 32 KiB window, default level.
    }

    /// Compresses one piece of the scanline stream. Safe to call from any thread.
    /// Every piece is a complete run of deflate blocks ending on a byte boundary
    /// (Z_SYNC_FLUSH), so consecutive pieces concatenate into one valid stream
    /// without sharing compressor state.
    static func compress(_ input: UnsafeRawBufferPointer) throws -> Segment {
        guard input.count <= Int(UInt32.max) else { throw EncodingError.invalidImage }
        var stream = z_stream()
        let status = deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, -MAX_WBITS, 8,
                                   Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else { throw EncodingError.compressionFailed(status) }
        defer { deflateEnd(&stream) }
        let bytes = input.bindMemory(to: Bytef.self)
        stream.next_in = UnsafeMutablePointer(mutating: bytes.baseAddress)
        stream.avail_in = uInt(bytes.count)
        var deflated = Data()
        var output = [UInt8](repeating: 0, count: chunkCapacity)
        // zlib requires repeating the flush until it leaves output space unused.
        var flushed = false
        while !flushed {
            let (result, produced) = output.withUnsafeMutableBufferPointer { buffer -> (Int32, Int) in
                stream.next_out = buffer.baseAddress
                stream.avail_out = uInt(buffer.count)
                let result = zlib.deflate(&stream, Z_SYNC_FLUSH)
                return (result, buffer.count - Int(stream.avail_out))
            }
            stream.next_out = nil
            // Z_BUF_ERROR only reports that an earlier call had already completed the flush.
            guard result == Z_OK || (result == Z_BUF_ERROR && produced == 0 && stream.avail_in == 0) else {
                throw EncodingError.compressionFailed(result)
            }
            deflated.append(contentsOf: output[0..<produced])
            flushed = produced < output.count
        }
        guard stream.avail_in == 0 else { throw EncodingError.compressionFailed(Z_BUF_ERROR) }
        let checksum = adler32(adler32(0, nil, 0), bytes.baseAddress, uInt(bytes.count))
        return Segment(deflated: deflated, checksum: checksum, length: input.count)
    }

    /// Appends the next piece of the image. Pieces must arrive in scanline order.
    func append(_ segment: Segment) throws {
        guard !finished else { return }
        checksum = adler32_combine(checksum, segment.checksum, numericCast(segment.length))
        try emit(segment.deflated)
    }

    func finish() throws {
        guard !finished else { return }
        // An empty final stored block ends the deflate stream; then the zlib trailer.
        var trailer = Data([0x01, 0x00, 0x00, 0xFF, 0xFF])
        trailer.appendBigEndian(UInt32(truncatingIfNeeded: checksum))
        try emit(trailer)
        if !pending.isEmpty {
            try chunk("IDAT", payload: pending)
            pending.removeAll(keepingCapacity: false)
        }
        try chunk("IEND", payload: Data())
        finished = true
    }

    /// Collects compressed bytes into IDAT chunks of at most 64 KiB.
    private func emit(_ bytes: Data) throws {
        var remaining = bytes[...]
        while !remaining.isEmpty {
            let piece = remaining.prefix(Self.chunkCapacity - pending.count)
            pending.append(piece)
            remaining = remaining.dropFirst(piece.count)
            if pending.count == Self.chunkCapacity {
                try chunk("IDAT", payload: pending)
                pending.removeAll(keepingCapacity: true)
            }
        }
    }

    private func chunk(_ kind: String, payload: Data) throws {
        let type = Data(kind.utf8)
        var checksum = type.withUnsafeBytes { bytes in
            crc32(0, bytes.bindMemory(to: Bytef.self).baseAddress, uInt(bytes.count))
        }
        if !payload.isEmpty {
            checksum = payload.withUnsafeBytes { bytes in
                crc32(checksum, bytes.bindMemory(to: Bytef.self).baseAddress, uInt(bytes.count))
            }
        }
        var prefix = Data()
        prefix.appendBigEndian(UInt32(payload.count))
        prefix.append(type)
        try file.write(contentsOf: prefix)
        if !payload.isEmpty { try file.write(contentsOf: payload) }
        var suffix = Data()
        suffix.appendBigEndian(UInt32(checksum))
        try file.write(contentsOf: suffix)
    }
}

private extension Data {
    nonisolated mutating func appendBigEndian(_ value: UInt32) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { append(contentsOf: $0) }
    }
}
