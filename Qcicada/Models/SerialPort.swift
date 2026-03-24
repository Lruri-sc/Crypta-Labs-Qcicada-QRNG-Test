// SerialPort.swift
// Qcicada
//
// Pure Swift serial port using POSIX APIs.
// No IOKit USB layer needed — macOS kernel already exposes
// FTDI devices as /dev/tty.usbserial-* BSD nodes.

import Foundation

final class SerialPort: @unchecked Sendable {
    
    private var fd: Int32 = -1
    private let path: String
    private let baudRate: speed_t
    private var originalTermios = termios()
    
    var isOpen: Bool { fd >= 0 }
    
    init(path: String, baudRate: Int = 1_000_000) {
        self.path = path
        // Map common baud rates. macOS custom baud via IOSSIOSPEED.
        self.baudRate = speed_t(baudRate)
    }
    
    // MARK: - Open / Close
    
    func open() throws {
        fd = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else {
            throw SerialError.cannotOpen(path: path, errno: errno)
        }
        
        // Clear non-blocking after open (we'll use timeouts instead)
        var flags = fcntl(fd, F_GETFL)
        flags &= ~O_NONBLOCK
        fcntl(fd, F_SETFL, flags)
        
        // Save original termios
        tcgetattr(fd, &originalTermios)
        
        // Configure raw mode
        var raw = termios()
        tcgetattr(fd, &raw)
        cfmakeraw(&raw)
        
        // 8N1, no flow control
        raw.c_cflag |= UInt(CS8 | CLOCAL | CREAD)
        raw.c_cflag &= ~UInt(PARENB | CSTOPB | CRTSCTS)
        raw.c_iflag &= ~UInt(IXON | IXOFF | IXANY)
        raw.c_lflag &= ~UInt(ICANON | ECHO | ECHOE | ISIG)
        raw.c_oflag &= ~UInt(OPOST)
        
        // VMIN=0, VTIME=10 (1 second default timeout)
        raw.c_cc.16 = 0   // VMIN
        raw.c_cc.17 = 10  // VTIME (tenths of second)
        
        tcsetattr(fd, TCSANOW, &raw)
        
        // Set custom baud rate via IOSSIOSPEED ioctl
        var speed = baudRate
        let IOSSIOSPEED: UInt = 0x80045402
        guard ioctl(fd, IOSSIOSPEED, &speed) == 0 else {
            let err = errno
            Darwin.close(fd)
            fd = -1
            throw SerialError.cannotSetBaud(baud: Int(baudRate), errno: err)
        }
        
        // Flush
        tcflush(fd, TCIOFLUSH)
    }
    
    func close() {
        guard fd >= 0 else { return }
        tcsetattr(fd, TCSANOW, &originalTermios)
        Darwin.close(fd)
        fd = -1
    }
    
    // MARK: - Timeout
    
    func setTimeout(seconds: Double) {
        guard fd >= 0 else { return }
        var raw = termios()
        tcgetattr(fd, &raw)
        let tenths = max(1, min(255, Int(seconds * 10)))
        raw.c_cc.16 = 0                  // VMIN
        raw.c_cc.17 = UInt8(tenths)      // VTIME
        tcsetattr(fd, TCSANOW, &raw)
    }
    
    // MARK: - Read / Write
    
    func write(_ data: Data) throws {
        guard fd >= 0 else { throw SerialError.notOpen }
        let bytes = [UInt8](data)
        var totalWritten = 0
        while totalWritten < bytes.count {
            let written = bytes.withUnsafeBufferPointer { buf in
                Darwin.write(fd, buf.baseAddress! + totalWritten, bytes.count - totalWritten)
            }
            if written < 0 {
                throw SerialError.writeFailed(errno: errno)
            }
            totalWritten += written
        }
    }
    
    func read(count: Int, timeout: Double = 1.0) -> Data {
        guard fd >= 0 else { return Data() }
        setTimeout(seconds: timeout)
        
        var result = Data(capacity: count)
        var remaining = count
        let deadline = Date().addingTimeInterval(timeout + 0.5)
        
        while remaining > 0 && Date() < deadline {
            var buf = [UInt8](repeating: 0, count: remaining)
            let n = buf.withUnsafeMutableBufferPointer { ptr in
                Darwin.read(fd, ptr.baseAddress!, remaining)
            }
            if n > 0 {
                result.append(contentsOf: buf[0..<n])
                remaining -= n
            } else if n == 0 {
                // Timeout, no more data
                break
            } else {
                // Error
                break
            }
        }
        return result
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

enum SerialError: LocalizedError {
    case cannotOpen(path: String, errno: Int32)
    case cannotSetBaud(baud: Int, errno: Int32)
    case notOpen
    case writeFailed(errno: Int32)
    
    var errorDescription: String? {
        switch self {
        case .cannotOpen(let path, let err):
            return "Cannot open \(path): \(String(cString: strerror(err)))"
        case .cannotSetBaud(let baud, let err):
            return "Cannot set baud \(baud): \(String(cString: strerror(err)))"
        case .notOpen:
            return "Serial port not open"
        case .writeFailed(let err):
            return "Write failed: \(String(cString: strerror(err)))"
        }
    }
}
