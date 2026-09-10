import Foundation

/// uTP packet types (BEP 29).
public enum UTPPacketType: UInt8, Sendable, Equatable, Hashable {
    case data = 0    // ST_DATA
    case fin = 1     // ST_FIN
    case state = 2   // ST_STATE (ACK)
    case reset = 3   // ST_RESET
    case syn = 4     // ST_SYN
}

/// uTP extension types.
public enum UTPExtensionType: UInt8, Sendable {
    case none = 0
    case selectiveAck = 1
}

/// A parsed uTP packet header (20 bytes minimum).
public struct UTPPacket: Sendable, Equatable {
    public let type: UTPPacketType
    public let version: UInt8         // always 1
    public let extensionType: UInt8
    public let connectionID: UInt16
    public let timestampMicroseconds: UInt32
    public let timestampDifference: UInt32
    public let windowSize: UInt32
    public let sequenceNumber: UInt16
    public let ackNumber: UInt16
    public let sackBitmask: Data?     // Selective ACK extension data
    public let payload: Data

    public static let headerSize = 20

    public init(
        type: UTPPacketType,
        version: UInt8 = 1,
        extensionType: UInt8 = 0,
        connectionID: UInt16,
        timestampMicroseconds: UInt32 = 0,
        timestampDifference: UInt32 = 0,
        windowSize: UInt32 = 0,
        sequenceNumber: UInt16 = 0,
        ackNumber: UInt16 = 0,
        sackBitmask: Data? = nil,
        payload: Data = Data()
    ) {
        self.type = type
        self.version = version
        self.extensionType = sackBitmask != nil ? UTPExtensionType.selectiveAck.rawValue : extensionType
        self.connectionID = connectionID
        self.timestampMicroseconds = timestampMicroseconds
        self.timestampDifference = timestampDifference
        self.windowSize = windowSize
        self.sequenceNumber = sequenceNumber
        self.ackNumber = ackNumber
        self.sackBitmask = sackBitmask
        self.payload = payload
    }

    /// Encode to wire format.
    public func encode() -> Data {
        var data = Data(capacity: Self.headerSize + (sackBitmask?.count ?? 0) + 2 + payload.count)

        // Byte 0: type (4 bits) | version (4 bits)
        let typeAndVersion = (type.rawValue << 4) | (version & 0x0F)
        data.append(typeAndVersion)

        // Byte 1: extension type
        data.append(extensionType)

        // Bytes 2-3: connection_id
        data.append(contentsOf: connectionID.bigEndianBytes)

        // Bytes 4-7: timestamp_microseconds
        data.append(contentsOf: timestampMicroseconds.bigEndianBytes)

        // Bytes 8-11: timestamp_difference_microseconds
        data.append(contentsOf: timestampDifference.bigEndianBytes)

        // Bytes 12-15: wnd_size
        data.append(contentsOf: windowSize.bigEndianBytes)

        // Bytes 16-17: seq_nr
        data.append(contentsOf: sequenceNumber.bigEndianBytes)

        // Bytes 18-19: ack_nr
        data.append(contentsOf: ackNumber.bigEndianBytes)

        // Extension data (SACK)
        if let sack = sackBitmask {
            data.append(0) // next extension = none
            data.append(UInt8(sack.count))
            data.append(sack)
        }

        // Payload
        data.append(payload)

        return data
    }

    /// Decode from wire format.
    public static func decode(from data: Data) throws -> UTPPacket {
        guard data.count >= headerSize else {
            throw UTPError.packetTooShort
        }

        let typeAndVersion = data[data.startIndex]
        let typeBits = typeAndVersion >> 4
        let versionBits = typeAndVersion & 0x0F

        guard versionBits == 1 else {
            throw UTPError.unsupportedVersion(versionBits)
        }

        guard let packetType = UTPPacketType(rawValue: typeBits) else {
            throw UTPError.unknownPacketType(typeBits)
        }

        let extType = data[data.startIndex + 1]
        let connID = data.readUInt16BE(at: 2)
        let timestamp = data.readUInt32BE(at: 4)
        let timestampDiff = data.readUInt32BE(at: 8)
        let wndSize = data.readUInt32BE(at: 12)
        let seqNr = data.readUInt16BE(at: 16)
        let ackNr = data.readUInt16BE(at: 18)

        var offset = headerSize
        var sackBitmask: Data?

        // Parse extensions
        var currentExt = extType
        while currentExt != 0 && offset < data.count {
            guard offset + 2 <= data.count else { break }
            let nextExt = data[data.startIndex + offset]
            let extLen = Int(data[data.startIndex + offset + 1])
            offset += 2

            if currentExt == UTPExtensionType.selectiveAck.rawValue && offset + extLen <= data.count {
                sackBitmask = data.subdata(in: (data.startIndex + offset)..<(data.startIndex + offset + extLen))
            }
            offset += extLen
            currentExt = nextExt
        }

        let payload = offset < data.count ? Data(data[(data.startIndex + offset)...]) : Data()

        return UTPPacket(
            type: packetType,
            version: versionBits,
            extensionType: extType,
            connectionID: connID,
            timestampMicroseconds: timestamp,
            timestampDifference: timestampDiff,
            windowSize: wndSize,
            sequenceNumber: seqNr,
            ackNumber: ackNr,
            sackBitmask: sackBitmask,
            payload: payload
        )
    }
}

public enum UTPError: Error, Equatable {
    case packetTooShort
    case unsupportedVersion(UInt8)
    case unknownPacketType(UInt8)
    case connectionRefused
    case connectionTimeout
    case connectionReset
}
