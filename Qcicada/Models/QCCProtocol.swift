// QCCProtocol.swift
// Qcicada
//
// Implements the Crypta Labs Cmd&Ctrl protocol.
// Reverse-engineered from pyqcc v0.1.4 cmdctrl.py

import Foundation

/// All commands and reads are performed serially by the acquisition worker.
nonisolated final class QCCDevice: @unchecked Sendable {
    
    private let serial: any SerialTransport
    private var pendingContinuousData = Data()

    var lastTransportError: (any Error)? { serial.lastError }
    
    // Command codes
    static let CMD_GET_STATUS: UInt8    = 0x01
    static let CMD_START: UInt8         = 0x04
    static let CMD_STOP: UInt8          = 0x05
    static let CMD_GET_STATISTICS: UInt8 = 0x09
    static let CMD_INFO: UInt8          = 0x0B
    
    // Response codes
    static let RESP_ACK: UInt8          = 0x11
    static let RESP_NACK: UInt8         = 0x12
    static let RESP_STATISTICS: UInt8   = 0x19
    static let RESP_INFO: UInt8         = 0x1B
    
    // Expected success response for each command
    private static let successResponse: [UInt8: UInt8] = [
        CMD_GET_STATUS:     RESP_ACK,
        CMD_START:          RESP_ACK,
        CMD_STOP:           RESP_ACK,
        CMD_GET_STATISTICS: RESP_STATISTICS,
        CMD_INFO:           RESP_INFO,
    ]
    
    // Payload size for each response type
    private static let payloadSize: [UInt8: Int] = [
        RESP_ACK:        5,
        RESP_NACK:       0,
        RESP_STATISTICS: 30,
        RESP_INFO:       56,
    ]
    
    private static let MAX_BLOCK_SIZE = 4096
    
    init(serial: any SerialTransport) {
        self.serial = serial
    }
    
    // MARK: - High-level commands
    
    nonisolated struct DeviceStatus: Sendable {
        let started: Bool
        let startupTestInProgress: Bool
        let voltageLow: Bool
        let voltageHigh: Bool
        let voltageUndefined: Bool
        let bitcount: Bool
        let repetitionCount: Bool
        let adaptiveProportion: Bool
        let readyBytes: UInt32
    }
    
    nonisolated struct DeviceInfo: Sendable {
        let coreVersion: UInt32
        let swVersion: UInt32
        let serial: String
        let hwInfo: String
    }
    
    nonisolated struct DeviceStatistics: Sendable {
        let generatedBytes: UInt64
        let repetitionCountFailures: UInt32
        let adaptiveProportionFailures: UInt32
        let bitcountFailures: UInt32
        let speed: UInt32
        let sensifAverage: UInt16
        let ledctrlLevel: Float
    }
    
    func getStatus() -> DeviceStatus? {
        guard let payload = command(cmd: Self.CMD_GET_STATUS, payload: nil) else {
            return nil
        }
        guard payload.count == 5 else { return nil }
        
        let flags = payload[0]
        let readyBytes = payload.withUnsafeBytes {
            UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 1, as: UInt32.self))
        }
        
        return DeviceStatus(
            started: (flags & 0x01) != 0,
            startupTestInProgress: (flags >> 1 & 0x01) != 0,
            voltageLow: (flags >> 2 & 0x01) != 0,
            voltageHigh: (flags >> 3 & 0x01) != 0,
            voltageUndefined: (flags >> 4 & 0x01) != 0,
            bitcount: (flags >> 5 & 0x01) != 0,
            repetitionCount: (flags >> 6 & 0x01) != 0,
            adaptiveProportion: (flags >> 7 & 0x01) != 0,
            readyBytes: readyBytes
        )
    }
    
    func getInfo() -> DeviceInfo? {
        guard let payload = command(cmd: Self.CMD_INFO, payload: nil) else {
            return nil
        }
        guard payload.count == 56 else { return nil }
        
        let coreVersion = payload.withUnsafeBytes {
            UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self))
        }
        let swVersion = payload.withUnsafeBytes {
            UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self))
        }
        
        let serialData = payload.subdata(in: 8..<32)
        let hwData = payload.subdata(in: 32..<56)
        
        let serialStr = String(data: serialData.prefix(while: { $0 != 0 }), encoding: .utf8) ?? "?"
        let hwStr = String(data: hwData.prefix(while: { $0 != 0 }), encoding: .utf8) ?? "?"
        
        return DeviceInfo(
            coreVersion: coreVersion,
            swVersion: swVersion,
            serial: serialStr,
            hwInfo: hwStr
        )
    }
    
    func getStatistics() -> DeviceStatistics? {
        guard let payload = command(cmd: Self.CMD_GET_STATISTICS, payload: nil) else {
            return nil
        }
        guard payload.count == 30 else { return nil }
        
        return payload.withUnsafeBytes { buf in
            DeviceStatistics(
                generatedBytes: UInt64(littleEndian: buf.loadUnaligned(fromByteOffset: 0, as: UInt64.self)),
                repetitionCountFailures: UInt32(littleEndian: buf.loadUnaligned(fromByteOffset: 8, as: UInt32.self)),
                adaptiveProportionFailures: UInt32(littleEndian: buf.loadUnaligned(fromByteOffset: 12, as: UInt32.self)),
                bitcountFailures: UInt32(littleEndian: buf.loadUnaligned(fromByteOffset: 16, as: UInt32.self)),
                speed: UInt32(littleEndian: buf.loadUnaligned(fromByteOffset: 20, as: UInt32.self)),
                sensifAverage: UInt16(littleEndian: buf.loadUnaligned(fromByteOffset: 24, as: UInt16.self)),
                ledctrlLevel: Float(bitPattern: UInt32(littleEndian: buf.loadUnaligned(fromByteOffset: 26, as: UInt32.self)))
            )
        }
    }
    
    /// Start continuous random data streaming
    func startContinuous() -> Bool {
        // Payload: mode=0x00 (continuous), length=0x0000
        let payload = Data([0x00, 0x00, 0x00])
        return command(cmd: Self.CMD_START, payload: payload) != nil
    }
    
    /// Read random bytes in continuous mode (blocking)
    func readContinuous(count: Int) -> Data? {
        guard count > 0 else { return nil }
        let timeout = 0.1 + 0.0001 * Double(count)
        if pendingContinuousData.count < count {
            pendingContinuousData.append(serial.read(
                count: count - pendingContinuousData.count,
                timeout: timeout
            ))
        }
        guard pendingContinuousData.count >= count else { return nil }

        let data = Data(pendingContinuousData.prefix(count))
        pendingContinuousData.removeFirst(count)
        return data
    }
    
    /// Stop continuous mode
    func stop() -> Bool {
        pendingContinuousData.removeAll(keepingCapacity: true)
        serial.flush()
        
        // Send stop command
        let cmdData = Data([Self.CMD_STOP])
        do {
            try serial.write(cmdData)
        } catch {
            return false
        }
        
        // Drain buffer looking for ACK
        // The device may still be sending random data, so we read large chunks
        // and look for the ACK response byte at the expected position
        serial.setTimeout(seconds: 0.1)
        
        for _ in 0..<3 {
            let resp = serial.read(
                count: Self.MAX_BLOCK_SIZE * 2 + (Self.payloadSize[Self.RESP_ACK] ?? 5) + 1,
                timeout: 0.5
            )
            if resp.count == 1 && resp[0] == Self.RESP_NACK {
                return false
            }
            let ackPayloadSize = Self.payloadSize[Self.RESP_ACK] ?? 5
            if resp.count >= ackPayloadSize + 1 {
                let ackPos = resp.count - 1 - ackPayloadSize
                if resp[ackPos] == Self.RESP_ACK {
                    return true
                }
            }
        }
        return false
    }
    
    /// Flush serial buffers
    func flushBuffers() {
        pendingContinuousData.removeAll(keepingCapacity: true)
        serial.flush()
        serial.flushInput()
        // Drain any remaining data
        _ = serial.read(count: 8192, timeout: 0.1)
    }
    
    func closeComm() {
        pendingContinuousData.removeAll(keepingCapacity: false)
        serial.close()
    }
    
    // MARK: - Generic command
    
    /// Send command and receive response payload.
    /// Returns payload Data on success, nil on failure.
    private func command(cmd: UInt8, payload: Data?) -> Data? {
        pendingContinuousData.removeAll(keepingCapacity: true)
        serial.flush()
        
        var toSend = Data([cmd])
        if let payload = payload {
            toSend.append(payload)
        }
        
        do {
            try serial.write(toSend)
        } catch {
            return nil
        }
        
        // Stop command has special handling (done in stop() method)
        if cmd == Self.CMD_STOP {
            return Data() // placeholder, stop() handles its own logic
        }
        
        // Read 1-byte response code
        serial.setTimeout(seconds: 3)
        let resp = serial.read(count: 1, timeout: 3)
        guard resp.count == 1 else { return nil }
        
        let respCode = resp[0]
        let expectedResp = Self.successResponse[cmd] ?? Self.RESP_ACK
        
        if respCode == expectedResp {
            let expectedSize = Self.payloadSize[expectedResp] ?? 0
            if expectedSize > 0 {
                let payloadData = serial.read(
                    count: expectedSize,
                    timeout: 0.001 * Double(expectedSize) + 0.5
                )
                return payloadData.count == expectedSize ? payloadData : nil
            } else {
                return Data()
            }
        } else if respCode == Self.RESP_NACK {
            return nil
        } else {
            // Unexpected byte — likely dirty buffer
            return nil
        }
    }
}
