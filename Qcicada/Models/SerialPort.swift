// SerialPort.swift
// Qcicada
//
// Pure Swift serial port using POSIX APIs.
// No IOKit USB layer needed — macOS kernel already exposes
// FTDI devices as /dev/tty.usbserial-* BSD nodes.

import Foundation

/// Transport access is serialized by the acquisition worker.
nonisolated protocol SerialTransport: AnyObject, Sendable {
    var lastError: (any Error)? { get }
    func write(_ data: Data) throws
    func read(count: Int, timeout: Double) -> Data
    @discardableResult func setTimeout(seconds: Double) -> Bool
    func flush()
    func flushInput()
    func close()
}

extension SerialTransport {
    nonisolated var lastError: (any Error)? { nil }
}

nonisolated final class SerialPort: SerialTransport, @unchecked Sendable {
    
    private var fd: Int32 = -1
    private let path: String
    private let baudRate: speed_t
    private var originalTermios = termios()
    private(set) var lastError: (any Error)?
    
    var isOpen: Bool { fd >= 0 }
    
    init(path: String, baudRate: Int = 1_000_000) {
        self.path = path
        // Map common baud rates. macOS custom baud via IOSSIOSPEED.
        self.baudRate = speed_t(baudRate)
    }
    
    // MARK: - Open / Close
    
    func open() throws {
        guard !isOpen else { return }
        let descriptor = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard descriptor >= 0 else {
            throw SerialError.cannotOpen(path: path, errno: errno)
        }

        var savedTermios = termios()
        var hasSavedTermios = false
        var configured = false
        defer {
            if !configured {
                if hasSavedTermios {
                    tcsetattr(descriptor, TCSANOW, &savedTermios)
                }
                Darwin.close(descriptor)
            }
        }
        
        // Clear non-blocking after open (we'll use timeouts instead)
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0 else {
            throw SerialError.cannotConfigure(operation: "F_GETFL", errno: errno)
        }
        guard fcntl(descriptor, F_SETFL, flags & ~O_NONBLOCK) == 0 else {
            throw SerialError.cannotConfigure(operation: "F_SETFL", errno: errno)
        }
        
        // Save original termios
        guard tcgetattr(descriptor, &savedTermios) == 0 else {
            throw SerialError.cannotConfigure(operation: "tcgetattr", errno: errno)
        }
        hasSavedTermios = true
        
        // Configure raw mode
        var raw = savedTermios
        cfmakeraw(&raw)
        
        // 8N1, no flow control
        raw.c_cflag |= UInt(CS8 | CLOCAL | CREAD)
        raw.c_cflag &= ~UInt(PARENB | CSTOPB | CRTSCTS)
        raw.c_iflag &= ~UInt(IXON | IXOFF | IXANY)
        raw.c_lflag &= ~UInt(ICANON | ECHO | ECHOE | ISIG)
        raw.c_oflag &= ~UInt(OPOST)
        
        // VMIN=0: a read returns whatever has arrived. read() does its waiting with
        // select(), so VTIME only bounds a read that finds nothing after select().
        raw.c_cc.16 = 0   // VMIN
        raw.c_cc.17 = 10  // VTIME (tenths of second)
        
        guard tcsetattr(descriptor, TCSANOW, &raw) == 0 else {
            throw SerialError.cannotConfigure(operation: "tcsetattr", errno: errno)
        }
        
        // Set custom baud rate via IOSSIOSPEED ioctl
        var speed = baudRate
        // _IOW('T', 2, speed_t); the encoded size must match the native speed_t.
        let IOSSIOSPEED = UInt(0x80005402) | (UInt(MemoryLayout<speed_t>.size) << 16)
        guard ioctl(descriptor, IOSSIOSPEED, &speed) == 0 else {
            throw SerialError.cannotSetBaud(baud: Int(baudRate), errno: errno)
        }
        
        // Flush
        guard tcflush(descriptor, TCIOFLUSH) == 0 else {
            throw SerialError.cannotConfigure(operation: "tcflush", errno: errno)
        }
        originalTermios = savedTermios
        fd = descriptor
        configured = true
    }
    
    func close() {
        guard fd >= 0 else { return }
        tcsetattr(fd, TCSANOW, &originalTermios)
        Darwin.close(fd)
        fd = -1
    }
    
    // MARK: - Timeout

    /// How long a read waits for more data. Once IOSSIOSPEED has selected a non-POSIX
    /// baud rate, termios reports that rate and macOS rejects every later tcsetattr
    /// with EINVAL, so VTIME cannot carry this value; read() waits with select().
    private var readTimeout = 1.0

    @discardableResult
    func setTimeout(seconds: Double) -> Bool {
        guard fd >= 0 else {
            lastError = SerialError.notOpen
            return false
        }
        guard seconds.isFinite, seconds >= 0 else {
            lastError = SerialError.cannotConfigure(operation: "read timeout", errno: EINVAL)
            return false
        }
        // The range VTIME could express: 0.1 s to 25.5 s.
        readTimeout = max(0.1, min(25.5, seconds))
        return true
    }
    
    // MARK: - Read / Write
    
    func write(_ data: Data) throws {
        lastError = nil
        do {
            guard fd >= 0 else { throw SerialError.notOpen }
            try data.withUnsafeBytes { bytes in
                var totalWritten = 0
                while totalWritten < bytes.count {
                    let written = Darwin.write(fd, bytes.baseAddress! + totalWritten, bytes.count - totalWritten)
                    if written < 0 {
                        if errno == EINTR { continue }
                        throw SerialError.writeFailed(errno: errno)
                    }
                    guard written > 0 else {
                        throw SerialError.writeFailed(errno: EIO)
                    }
                    totalWritten += written
                }
            }
        } catch {
            lastError = error
            throw error
        }
    }
    
    func read(count: Int, timeout: Double = 1.0) -> Data {
        lastError = nil
        guard fd >= 0 else {
            lastError = SerialError.notOpen
            return Data()
        }
        guard count > 0, setTimeout(seconds: timeout) else { return Data() }

        let received = Self.read(from: fd, count: count, timeout: readTimeout, overall: timeout + 0.5)
        lastError = received.error
        return received.data
    }

    /// Reads from `descriptor` until `count` bytes have arrived, no data arrives for
    /// `timeout` seconds, or `overall` seconds have passed (checked before each wait).
    /// Bytes received before a timeout or failure are still returned.
    static func read(from descriptor: Int32, count: Int, timeout: Double, overall: Double)
        -> (data: Data, error: SerialError?) {
        var result = Data(count: count)
        var totalRead = 0
        var failure: SerialError?
        let deadline = ProcessInfo.processInfo.systemUptime + overall

        result.withUnsafeMutableBytes { buffer in
            reading: while totalRead < count && ProcessInfo.processInfo.systemUptime < deadline {
                switch waitForData(on: descriptor, seconds: timeout) {
                case .ready:
                    break
                case .timedOut:
                    break reading
                case .failed(let code):
                    failure = .readFailed(errno: code)
                    break reading
                }
                let n = Darwin.read(descriptor, buffer.baseAddress! + totalRead, count - totalRead)
                if n > 0 {
                    totalRead += n
                } else if n < 0 && errno == EINTR {
                    continue
                } else {
                    // select() reported data, so an empty read means the device is gone.
                    failure = .readFailed(errno: n < 0 ? errno : EIO)
                    break
                }
            }
        }
        result.count = totalRead
        return (result, failure)
    }

    private enum Wait {
        case ready
        case timedOut
        case failed(Int32)
    }

    /// Waits with select(), because macOS poll() does not support devices.
    private static func waitForData(on descriptor: Int32, seconds: Double) -> Wait {
        guard descriptor >= 0, descriptor < FD_SETSIZE else { return .failed(EBADF) }
        let end = ProcessInfo.processInfo.systemUptime + seconds
        while true {
            // select() rejects waits longer than 100,000,000 seconds.
            let remaining = max(0, min(100_000_000, end - ProcessInfo.processInfo.systemUptime))
            var readable = fd_set()
            __darwin_fd_set(descriptor, &readable)
            var wait = timeval(tv_sec: Int(remaining),
                               tv_usec: Int32((remaining - remaining.rounded(.down)) * 1_000_000))
            let ready = select(descriptor + 1, &readable, nil, nil, &wait)
            if ready > 0 { return .ready }
            if ready == 0 { return .timedOut }
            let code = errno
            if code != EINTR { return .failed(code) }
        }
    }
    
    func flush() {
        guard fd >= 0 else { return }
        tcflush(fd, TCIOFLUSH)
    }
    
    func flushInput() {
        guard fd >= 0 else { return }
        tcflush(fd, TCIFLUSH)
    }
    
    // MARK: - Device Discovery
    
    static func availablePorts() -> [String] {
        let fm = FileManager.default
        do {
            let devContents = try fm.contentsOfDirectory(atPath: "/dev")
            return devContents
                .filter { $0.hasPrefix("tty.usbserial") || $0.hasPrefix("tty.usbmodem") }
                .map { "/dev/\($0)" }
                .sorted()
        } catch {
            return []
        }
    }
    
    deinit {
        close()
    }
}

// MARK: - Errors

nonisolated enum SerialError: LocalizedError {
    case cannotOpen(path: String, errno: Int32)
    case cannotConfigure(operation: String, errno: Int32)
    case cannotSetBaud(baud: Int, errno: Int32)
    case notOpen
    case readFailed(errno: Int32)
    case writeFailed(errno: Int32)
    
    var errorDescription: String? {
        switch self {
        case .cannotOpen(let path, let err):
            return "Cannot open \(path): \(String(cString: strerror(err)))"
        case .cannotConfigure(let operation, let err):
            return "Cannot configure serial port (\(operation)): \(String(cString: strerror(err)))"
        case .cannotSetBaud(let baud, let err):
            return "Cannot set baud \(baud): \(String(cString: strerror(err)))"
        case .notOpen:
            return "Serial port not open"
        case .readFailed(let err):
            return "Read failed: \(String(cString: strerror(err)))"
        case .writeFailed(let err):
            return "Write failed: \(String(cString: strerror(err)))"
        }
    }
}
