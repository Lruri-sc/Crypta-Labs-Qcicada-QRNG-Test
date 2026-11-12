// Run independently from the repository root:
// swiftc -swift-version 5 -default-isolation MainActor \
//   Qcicada/Models/SerialPort.swift Qcicada/Models/QCCProtocol.swift \
//   Tests/SerialProtocolTests.swift -o /tmp/qcicada-serial-tests
// /tmp/qcicada-serial-tests

import Foundation

nonisolated private final class ScriptedTransport: SerialTransport, @unchecked Sendable {
    var responses: [Data] = []
    var requests: [Int] = []
    var writes: [Data] = []
    var lastError: (any Error)?
    var nextReadError: (any Error)?
    var closeCount = 0

    func write(_ data: Data) throws { writes.append(data) }

    func read(count: Int, timeout: Double) -> Data {
        requests.append(count)
        lastError = nextReadError
        nextReadError = nil
        guard !responses.isEmpty else { return Data() }
        let response = responses.removeFirst()
        if response.count > count {
            responses.insert(Data(response.dropFirst(count)), at: 0)
        }
        return Data(response.prefix(count))
    }

    func setTimeout(seconds: Double) -> Bool { true }
    func flush() {}
    func flushInput() {}
    func close() { closeCount += 1 }
}

@main
struct SerialProtocolTests {
    static func main() {
        let transport = ScriptedTransport()
        let device = QCCDevice(serial: transport)

        transport.responses = [Data([0x11]), Data([0x81, 0x78, 0x56, 0x34, 0x12])]
        let status = device.getStatus()!
        precondition(status.readyBytes == 0x12345678)
        precondition(status.started && status.adaptiveProportion && !status.voltageLow)
        precondition(transport.writes.last == Data([0x01]))

        var info = Data([4, 3, 2, 1, 8, 7, 6, 5])
        info.append(Data("SERIAL-123".utf8))
        info.append(Data(repeating: 0, count: 24 - "SERIAL-123".utf8.count))
        info.append(Data("TEST HARDWARE".utf8))
        info.append(Data(repeating: 0, count: 24 - "TEST HARDWARE".utf8.count))
        transport.responses = [Data([0x1B]), info]
        let deviceInfo = device.getInfo()!
        precondition(deviceInfo.coreVersion == 0x01020304 && deviceInfo.swVersion == 0x05060708)
        precondition(deviceInfo.serial == "SERIAL-123" && deviceInfo.hwInfo == "TEST HARDWARE")

        transport.responses = [
            Data([0x19]),
            Data([
                8, 7, 6, 5, 4, 3, 2, 1,
                4, 3, 2, 1,
                8, 7, 6, 5,
                12, 11, 10, 9,
                16, 15, 14, 13,
                0x34, 0x12,
                0, 0, 0xC0, 0x3F,
            ]),
        ]
        let stats = device.getStatistics()!
        precondition(stats.generatedBytes == 0x0102030405060708)
        precondition(stats.repetitionCountFailures == 0x01020304)
        precondition(stats.adaptiveProportionFailures == 0x05060708)
        precondition(stats.bitcountFailures == 0x090A0B0C)
        precondition(stats.speed == 0x0D0E0F10 && stats.sensifAverage == 0x1234)
        precondition(stats.ledctrlLevel == 1.5) // The float begins at unaligned byte offset 26.

        transport.responses = [Data([0, 1, 2]), Data(), Data([3, 4, 5, 6, 7])]
        precondition(device.readContinuous(count: 8) == nil)
        precondition(device.readContinuous(count: 8) == nil)
        precondition(device.readContinuous(count: 8) == Data(0...7))
        precondition(Array(transport.requests.suffix(3)) == [8, 5, 5])

        // A flush must discard an incomplete sample before the next session.
        transport.responses = [Data([99]), Data()]
        precondition(device.readContinuous(count: 4) == nil)
        device.flushBuffers()
        transport.responses = [Data([10, 11, 12, 13])]
        precondition(device.readContinuous(count: 4) == Data([10, 11, 12, 13]))

        // Starting a new stream must also discard an incomplete previous sample.
        transport.responses = [Data([99]), Data([0x11]), Data(repeating: 0, count: 5)]
        precondition(device.readContinuous(count: 4) == nil)
        precondition(device.startContinuous())
        precondition(transport.writes.last == Data([0x04, 0, 0, 0]))
        transport.responses = [Data([20, 21, 22, 23])]
        precondition(device.readContinuous(count: 4) == Data([20, 21, 22, 23]))

        transport.nextReadError = SerialError.readFailed(errno: EIO)
        precondition(device.readContinuous(count: 4) == nil)
        guard case .readFailed(let errorNumber)? = device.lastTransportError as? SerialError else {
            preconditionFailure("Transport failure was not exposed")
        }
        precondition(errorNumber == EIO)
        transport.responses = [Data([30, 31, 32, 33])]
        precondition(device.readContinuous(count: 4) == Data([30, 31, 32, 33]))
        precondition(device.lastTransportError == nil)

        // NACK and truncated command responses must not be decoded as valid data.
        transport.responses = [Data([0x12])]
        precondition(device.getStatus() == nil)
        transport.responses = [Data([0x19]), Data([1, 2, 3])]
        precondition(device.getStatistics() == nil)

        device.closeComm()
        precondition(transport.closeCount == 1)

        let closed = SerialPort(path: "/qcicada-protocol-test-nonexistent")
        do {
            try closed.open()
            preconditionFailure("Unexpected open success")
        } catch {}
        precondition(!closed.isOpen)
        precondition(closed.read(count: 4).isEmpty)
        guard case .notOpen? = closed.lastError as? SerialError else {
            preconditionFailure("Read on a closed port did not report an error")
        }

        do {
            try closed.write(Data([0x04]))
            preconditionFailure("Write on a closed port unexpectedly succeeded")
        } catch {}
        guard case .notOpen? = closed.lastError as? SerialError else {
            preconditionFailure("Write failure was not exposed to the protocol layer")
        }

        let closedDevice = QCCDevice(serial: closed)
        precondition(!closedDevice.startContinuous())
        guard case .notOpen? = closedDevice.lastTransportError as? SerialError else {
            preconditionFailure("A failed start command hid the write error")
        }

        print("PASS: protocol decoding, unaligned Float, partial-read preservation, stream reset, transport errors, invalid responses, open failure")
        testDescriptorReads()
    }

    /// SerialPort's descriptor read on pipes. The wait must be the caller's timeout:
    /// on the real port macOS refuses VTIME changes after the custom baud rate, which
    /// once pinned every wait at one second and once failed every read.
    private static func testDescriptorReads() {
        func makePipe() -> (read: Int32, write: Int32) {
            var descriptors: [Int32] = [0, 0]
            precondition(pipe(&descriptors) == 0)
            return (descriptors[0], descriptors[1])
        }
        func send(_ bytes: [UInt8], to descriptor: Int32) {
            precondition(Darwin.write(descriptor, bytes, bytes.count) == bytes.count)
        }
        func timedRead(_ descriptor: Int32, count: Int, timeout: Double, overall: Double)
            -> (data: Data, error: SerialError?, elapsed: Double) {
            let start = ProcessInfo.processInfo.systemUptime
            let result = SerialPort.read(from: descriptor, count: count, timeout: timeout, overall: overall)
            return (result.data, result.error, ProcessInfo.processInfo.systemUptime - start)
        }

        let link = makePipe()
        // A complete reply that is already waiting returns at once.
        send(Array(0..<8), to: link.write)
        var reply = timedRead(link.read, count: 8, timeout: 0.3, overall: 0.8)
        precondition(reply.data == Data(0..<8) && reply.error == nil && reply.elapsed < 0.2)

        // A short reply ends after the requested quiet time, with its bytes and no error.
        send([1, 2, 3], to: link.write)
        reply = timedRead(link.read, count: 8, timeout: 0.3, overall: 0.8)
        precondition(reply.data == Data([1, 2, 3]) && reply.error == nil)
        precondition(reply.elapsed >= 0.28 && reply.elapsed < 0.7, "Quiet time was \(reply.elapsed) s, not 0.3 s")

        // Silence is a timeout, not a failure.
        reply = timedRead(link.read, count: 8, timeout: 0.2, overall: 0.7)
        precondition(reply.data.isEmpty && reply.error == nil)
        precondition(reply.elapsed >= 0.18 && reply.elapsed < 0.6, "Idle wait was \(reply.elapsed) s, not 0.2 s")

        // Pieces arriving within the quiet time are joined, and the read ends on the count.
        let writers = DispatchGroup()
        let output = link.write
        DispatchQueue.global().async(group: writers) {
            _ = Darwin.write(output, [10, 11, 12, 13] as [UInt8], 4)
            usleep(60_000)
            _ = Darwin.write(output, [14, 15, 16, 17] as [UInt8], 4)
        }
        reply = timedRead(link.read, count: 8, timeout: 0.3, overall: 0.8)
        writers.wait()
        precondition(reply.data == Data(10...17) && reply.error == nil && reply.elapsed < 0.3)

        // A trickle that never pauses for the quiet time still ends at the overall limit.
        DispatchQueue.global().async(group: writers) {
            for value in 0..<12 {
                _ = Darwin.write(output, [UInt8(value)], 1)
                usleep(50_000)
            }
        }
        reply = timedRead(link.read, count: 1000, timeout: 0.2, overall: 0.3)
        writers.wait()
        precondition(reply.error == nil && (1...11).contains(reply.data.count))
        precondition(reply.elapsed >= 0.28 && reply.elapsed < 0.8, "Overall limit took \(reply.elapsed) s, not 0.3 s")
        precondition(reply.data == Data((0..<reply.data.count).map(UInt8.init)))
        close(link.read)
        close(link.write)

        // A vanished peer is readable with nothing to read: a failure that keeps earlier bytes.
        let unplugged = makePipe()
        send([42], to: unplugged.write)
        close(unplugged.write)
        reply = timedRead(unplugged.read, count: 4, timeout: 0.3, overall: 0.8)
        close(unplugged.read)
        guard reply.data == Data([42]), case .readFailed(let gone)? = reply.error, gone == EIO, reply.elapsed < 0.2 else {
            preconditionFailure("A closed peer was treated as an idle port")
        }

        reply = timedRead(-1, count: 4, timeout: 0.1, overall: 0.6)
        guard reply.data.isEmpty, case .readFailed(let invalid)? = reply.error, invalid == EBADF else {
            preconditionFailure("An invalid descriptor was not reported")
        }
        print("PASS: descriptor reads honour the requested quiet time and overall limit, join pieces, and report a vanished peer")
    }
}
