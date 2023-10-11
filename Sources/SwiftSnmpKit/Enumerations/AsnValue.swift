//
//  AsnValue.swift
//  Snmp1
//
//  Created by Darrell Root on 6/29/22.
//  See https://luca.ntop.org/Teaching/Appunti/asn1.html

import Foundation

/// SNMP messages use ASN.1
/// https://en.wikipedia.org/wiki/ASN.1 encodings.
/// This defines how data structures can be encoded into network transmissions.  Some ASN.1 elements constitute individual structures (such as integers or octet strings) while others constitute sequences of ASN.1 elements.
/// SNMP replies include a `SnmpVariableBinding` which includes the OID of the object and then the object as an ASN.1 value.  Your program may need to switch on the ASN.1 value type to access the underlying data.
public enum AsnValue: Equatable, CustomStringConvertible, AsnData {
    
    static let classMask: UInt8 = 0b11000000
    
    case endOfContent
    case integer(Int64)
    #warning("TODO: Fix bitString implementation")
    case bitString(Data) // first octet indicates how many bits short of a multiple of 8 "number of unused bits". This implementation doesn't deal with this at this time
    case octetString(Data)
    case oid(SnmpOid)
    case null
    case sequence([AsnValue])
    case ia5(String)
    case snmpResponse(SnmpPdu)
    case snmpGet(SnmpPdu)
    case snmpGetNext(SnmpPdu)
    case snmpReport(SnmpPdu)
    case noSuchObject
    case ipv4(UInt32)
    case counter32(UInt32)
    case gauge32(UInt32)
    case timeticks(UInt32)
    case counter64(UInt64)
    case endOfMibView
    
    /// Initializes an AsnValue of type OctetString from a string.  In theory this should be ASCII, but we use UTF-8 anyway
    /// - Parameter octetString: This should be in ASCII format but we support UTF-8
    init(octetString: String) {
        // UTF-8 encoding should never fail
        let data = octetString.data(using: .utf8)!
        self = .octetString(data)
    }
    
    /// Initializes an AsnValue of type OctetString from data.  This is used for SNMPv3 engine IDs which are not encoded in ASCII
    /// - Parameter octetString: This should be in ASCII format but we support UTF-8
    init(octetStringData: Data) {
        // UTF-8 encoding should never fail
        self = .octetString(octetStringData)
    }
    
    /// Creates data to represent an ASN.1 length
    ///
    /// For lengths of 127 or less, this returns a single byte with that number
    /// For lengths greater than 128, it returns a byte encoding the number of bytes (with the most significant bit set), followed by the length in base-256
    /// - Parameter length: The length of data to encode
    /// - Returns: A sequence of Data bytes which represent the length
    internal static func encodeLength(_ length: Int) -> Data {
        guard length >= 0 else {
            SnmpError.log("Unexpected length \(length)")
            fatalError()
        }
        if length < 128 {
            return Data([UInt8(length)])
        }
        var octetsReversed: [UInt8] = []
        var power = 0
        while (length >= SnmpUtils.powerOf256(power)) {
            octetsReversed.append(UInt8(length / SnmpUtils.powerOf256(power)))
            power += 1
        }
        
        let firstOctet = UInt8(octetsReversed.count | 0b10000000)
        let prefix = Data([firstOctet])
        let suffix = Data(octetsReversed.reversed())
        return prefix + suffix
    }

    internal func encodeInteger(_ value: Int64) -> Data {
        if value > -129 && value < 128 {
            let bitPattern = Int8(value)
            
            return Data([0x02,0x01,UInt8(bitPattern: bitPattern)])
        }
        let negative = value < 0
        // get bitpattern for positive, then convert if negative
        var absValue: UInt64
        if value < 0 {
            absValue = UInt64(value * -1)
        } else {
            absValue = UInt64(value)
        }
        // at first this array is reversed from what we need
        var octets: [UInt8] = []
        while absValue > 0 {
            let newOctet = UInt8(absValue % 256)
            octets.append(newOctet)
            absValue = absValue / 256
        }
        // put array with highest magnitude first
        octets.reverse()
        
        // two's complement math
        // first octet needs space for sign bit
        if octets[0] > 127 && !negative || octets[0] > 128 && negative {
            octets.insert(0, at: 0)
        }
        if negative {
            for position in 0..<octets.count {
                octets[position] = ~octets[position]
            }
            var position = octets.count - 1
            var done = false
            while !done {
                if position < 0 {
                    // need to add an octet
                    octets = [1] + octets
                    done = true
                } else if octets[position] < 255 {
                    octets[position] = octets[position] + 1
                    done = true
                } else {
                    octets[position] = 0
                    position = position - 1
                }
            }
        }
        let lengthOctets = AsnValue.encodeLength(octets.count)
        return Data([0x02]) + lengthOctets + octets
    }
    /// Creates a Data array from an unsigned integer.  Base 128.  Every octet except the last has most significant bit set to 1.  Used to encode OIDs
    /// - Parameter value: Positive integer
    /// - Returns: Data array encoding integer base 128 with most significant bits set to 1
    internal static func base128ToData(_ value: Int) -> Data {
        if value == 0 {
            return Data([0])
        }
        var result = Data() // initially in reverse order
        var value = value
        while value > 0 {
            result.append(UInt8(value % 128))
            value = value / 128
        }
        result.reverse() // most significant octet now leading
        // set most significant bit in every octet except last
        for position in 0..<(result.count - 1) {
            result[position] = result[position] | 0b10000000
        }
        return result
    }

    internal var asnData: Data {
        switch self {
            
        case .endOfContent:
            return Data([])
        case .integer(let value):
            return encodeInteger(value)
        case .bitString(let data):
            let lengthData = AsnValue.encodeLength(data.count)
            let prefix = Data([0x03])
            return prefix + lengthData + data
        case .octetString(let octets):
            let lengthData = AsnValue.encodeLength(octets.count)
            let prefix = Data([0x04])
            return prefix + lengthData + octets
        case .oid(let oid):
            return oid.asnData
        case .null:
            return Data([0x05,0x00])
        case .sequence(let contents):
            var contentData = Data()
            for content in contents {
                contentData += content.asnData
            }
            let lengthData = AsnValue.encodeLength(contentData.count)
            let prefix = Data([0x30])
            return prefix + lengthData + contentData
        case .ia5(let string):
            // only valid if string characters are ascii
            // we will warn, and then encode as UTF-8 anyway rather than crash
            if string.data(using: .ascii) == nil {
                SnmpError.log("Unable to encode ia5 string \(string) as ASCII")
            }
            guard let stringData = string.data(using: .utf8) else {
                // the above line should never fail
                fatalError("Unexpectedly unable to convert \(string) to utf-8 encoding")
            }
            let lengthData = AsnValue.encodeLength(stringData.count)
            let prefix = Data([0x16])
            return prefix + lengthData + stringData
        case .snmpGet(let pdu), .snmpGetNext(let pdu),.snmpResponse(let pdu), .snmpReport(let pdu):
            return pdu.asnData
        #warning("TODO Update counter32, gauge32, and timetick32 to produce smaller data if they can be encoded in less than 4 octets")
        case .counter32(let value):
            var counterData = Data(capacity: 6)
            counterData[0] = 0x41
            counterData[1] = 0x04
            counterData[2] = UInt8((value & UInt32(0xff000000)) >> 24)
            counterData[3] = UInt8((value & UInt32(0x00ff0000)) >> 16)
            counterData[4] = UInt8((value & UInt32(0x0000ff00)) >> 8)
            counterData[5] = UInt8(value & UInt32(0x000000ff))
            return counterData
        case .gauge32(let value):
            var gaugeData = Data(capacity: 6)
            gaugeData[0] = 0x42
            gaugeData[1] = 0x04
            gaugeData[2] = UInt8((value & UInt32(0xff000000)) >> 24)
            gaugeData[3] = UInt8((value & UInt32(0x00ff0000)) >> 16)
            gaugeData[4] = UInt8((value & UInt32(0x0000ff00)) >> 8)
            gaugeData[5] = UInt8(value & UInt32(0x000000ff))
            return gaugeData
        case .timeticks(let value):
            var timeData = Data(capacity: 6)
            timeData[0] = 0x43
            timeData[1] = 0x04
            timeData[2] = UInt8((value & UInt32(0xff000000)) >> 24)
            timeData[3] = UInt8((value & UInt32(0x00ff0000)) >> 16)
            timeData[4] = UInt8((value & UInt32(0x0000ff00)) >> 8)
            timeData[5] = UInt8(value & UInt32(0x000000ff))
            return timeData
        case .noSuchObject:
            return Data([0x80,0x00])
        case .ipv4(let value):
            var ipv4Data = Data(capacity: 6)
            ipv4Data[0] = 0x40
            ipv4Data[1] = 0x04
            ipv4Data[2] = UInt8((value & UInt32(0xff000000)) >> 24)
            ipv4Data[3] = UInt8((value & UInt32(0x00ff0000)) >> 16)
            ipv4Data[4] = UInt8((value & UInt32(0x0000ff00)) >> 8)
            ipv4Data[5] = UInt8(value & UInt32(0x000000ff))
            return ipv4Data
        case .counter64(let value):
            var counterData = Data(capacity: 10)
            counterData[0] = 0x46
            counterData[1] = 0x08
            counterData[2] = UInt8((value & UInt64(0xff000000_00000000)) >> 56)
            counterData[3] = UInt8((value & UInt64(0x00ff0000_00000000)) >> 48)
            counterData[4] = UInt8((value & UInt64(0x0000ff00_00000000)) >> 40)
            counterData[5] = UInt8((value & UInt64(0x000000ff_00000000)) >> 32)
            counterData[6] = UInt8((value & UInt64(0x00000000_ff000000)) >> 24)
            counterData[7] = UInt8((value & UInt64(0x00000000_00ff0000)) >> 16)
            counterData[8] = UInt8((value & UInt64(0x00000000_0000ff00)) >> 8)
            counterData[9] = UInt8(value & UInt64(0x00000000_000000ff))
            return counterData
        case .endOfMibView:
            return Data([0x82,0x00])
        }
    }
    static func pduLength(data: Data) throws -> Int {
        /* Input: The start of an ASN1 value
         Output: The length of the value
         Errors: If the size of the data is insufficient for the PDU, it throws an error */
        try validateLength(data: data)
        let prefixLength = try prefixLength(data: data)
        let valueLength = try valueLength(data: data[(data.startIndex + 1)...])
        return prefixLength + valueLength
    }
    static func validateLength(data: Data) throws {
        /* this function validates that there are sufficient data octets to read the type, length, and value, preventing a crash */
        guard data.count > 1 else {
            throw SnmpError.badLength
        }
        let valueLength = try AsnValue.valueLength(data: data[(data.startIndex+1)...])
        let prefixLength = try AsnValue.prefixLength(data: data)
        guard data.count >= valueLength + prefixLength else {
            throw SnmpError.badLength
        }
    }
    init(data: Data) throws {
        guard data.count > 0 else {
            throw SnmpError.badLength
        }
        let identifierOctet = data[data.startIndex]
        
        switch identifierOctet {
        case 2: // ASN1 Integer
            try AsnValue.validateLength(data: data)
            let integerLength = try AsnValue.valueLength(data: data[(data.startIndex+1)...])
            let prefixLength = try AsnValue.prefixLength(data: data)
            let firstNumericOctet = data[data.startIndex + prefixLength]
            // checking two's complement sign
            let negative: Bool = firstNumericOctet & 0b10000000 > 0
            var magnitude = Int64(firstNumericOctet & 0b01111111)
            
            for octet in data[(data.startIndex + prefixLength + 1)..<(data.startIndex + prefixLength + integerLength)] {
                // use bitshifiting to multiply by 256
                magnitude = (magnitude << 8)
                magnitude = magnitude + Int64(octet)
            }
            // Two's complement by adding magnitude to -(256^digits)
            if negative {
                var lowerbound: Int64 = -128
                for _ in 1..<integerLength {
                    lowerbound = lowerbound * 256
                }
                magnitude = lowerbound + magnitude
            }
            self = .integer(magnitude)
            return
        case 4:
            // Octet String

            guard data.count > 1 else {
                throw SnmpError.badLength
            }
            let stringLength = try AsnValue.valueLength(data: data[(data.startIndex+1)...])
            let prefixLength = try AsnValue.prefixLength(data: data)
            guard data.count >= stringLength + prefixLength else {
                throw SnmpError.badLength
            }
            let stringData = data[(data.startIndex + prefixLength)..<(data.startIndex + prefixLength + stringLength)]
            //let string = String(decoding: stringData, as: UTF8.self)
            self = .octetString(stringData)
        case 5: // ASN1 Null
            self = .null
            return
        case 6: // OID
            try AsnValue.validateLength(data: data)
            let prefixLength = try AsnValue.prefixLength(data: data)
            let valueLength = try AsnValue.valueLength(data: data.advanced(by: 1))
            let firstOctet = data[data.startIndex + prefixLength]
            var result: [Int] = []
            // special ASN rules for first two octets
            result.append(Int(firstOctet) / 40)
            result.append(Int(firstOctet) % 40)
            var nextValue = 0
            for octet in data[(data.startIndex + prefixLength + 1) ..< (data.startIndex + prefixLength + valueLength)] {
                // base 128 math.  Each number ends when most significant bit is not set
                if octet > 127 {
                    nextValue = nextValue * 128 + Int(octet) - 128
                } else {
                    nextValue = nextValue * 128 + Int(octet)
                    result.append(nextValue)
                    nextValue = 0
                }
            }
            guard let oid = SnmpOid(nodes: result) else {
                throw SnmpError.unexpectedSnmpPdu
            }
            self = .oid(oid)
            return
        case 22: // ASN1 IA5 (ASCII) encoding
            guard data.count > 1 else {
                throw SnmpError.badLength
            }
            let stringLength = try AsnValue.valueLength(data: data[(data.startIndex+1)...])
            let prefixLength = try AsnValue.prefixLength(data: data)
            guard data.count >= stringLength + prefixLength else {
                throw SnmpError.badLength
            }
            let stringData = data[(data.startIndex + prefixLength)..<(data.startIndex + prefixLength + stringLength)]
            let string = String(decoding: stringData, as: UTF8.self)
            self = .ia5(string)
        case 16,48: // sequence of
            try AsnValue.validateLength(data: data)
            let prefixLength = try AsnValue.prefixLength(data: data)
            let pduLength = try AsnValue.pduLength(data: data)
            var contentData = data[(data.startIndex + prefixLength)..<(data.startIndex + pduLength)]
            var contents: [AsnValue] = []
            while (contentData.count > 0) {
                let newValueLength = try AsnValue.pduLength(data: contentData)
                let newValue = try AsnValue(data: contentData)
                contents.append(newValue)
                contentData = contentData.advanced(by: newValueLength)
            }
            self = .sequence(contents)
            return
        case 0x40: //IPv4 address
            try AsnValue.validateLength(data: data)
            let valueLength = try AsnValue.valueLength(data: data[(data.startIndex+1)...])
            let prefixLength = try AsnValue.prefixLength(data: data)
            guard prefixLength == 2 else {
                throw SnmpError.badLength
            }
            guard valueLength == 4 else {
                throw SnmpError.badLength
            }
            var value: UInt32 = 0
            for octetPosition in prefixLength..<(prefixLength+valueLength) {
                value = (value << 8) + UInt32(data[octetPosition])
            }
            self = .ipv4(value)
            return
        case 0x41: //counter32
            try AsnValue.validateLength(data: data)
            let counterLength = try AsnValue.valueLength(data: data[(data.startIndex+1)...])
            let prefixLength = try AsnValue.prefixLength(data: data)
            var value: UInt32 = 0
            for octetPosition in prefixLength..<(prefixLength+counterLength) {
                value = (value << 8) + UInt32(data[octetPosition])
            }
            self = .counter32(value)
            return
        case 0x42: //gauge32
            try AsnValue.validateLength(data: data)
            let gaugeLength = try AsnValue.valueLength(data: data[(data.startIndex+1)...])
            let prefixLength = try AsnValue.prefixLength(data: data)
            var value: UInt32 = 0
            for octetPosition in prefixLength..<(prefixLength+gaugeLength) {
                value = (value << 8) + UInt32(data[octetPosition])
            }
            self = .gauge32(value)
            return
        case 0x43: //timeticks
            try AsnValue.validateLength(data: data)
            let timetickLength = try AsnValue.valueLength(data: data[(data.startIndex+1)...])
            let prefixLength = try AsnValue.prefixLength(data: data)
            var value: UInt32 = 0
            for octetPosition in prefixLength..<(prefixLength+timetickLength) {
                value = (value << 8) + UInt32(data[octetPosition])
            }
            self = .timeticks(value)
            return
        case 0x46: // counter64
            try AsnValue.validateLength(data: data)
            let gaugeLength = try AsnValue.valueLength(data: data[(data.startIndex+1)...])
            let prefixLength = try AsnValue.prefixLength(data: data)
            var value: UInt64 = 0
            for octetPosition in prefixLength..<(prefixLength+gaugeLength) {
                value = (value << 8) + UInt64(data[octetPosition])
            }
            self = .counter64(value)
            return
        case 0x80:
            self = .noSuchObject
            return
        case 0x82:
            self = .endOfMibView
            return
        case 0xa0,0xa1,0xa2,0xa8: // SNMP Response PDU
            try AsnValue.validateLength(data: data)
            //let prefixLength = try AsnValue.prefixLength(data: data)
            let pduLength = try AsnValue.pduLength(data: data)
            let pduData = data[(data.startIndex)..<(data.startIndex + pduLength)]
            let pdu = try SnmpPdu(data: pduData)
            switch pdu.pduType {
            case .getRequest:
                self = .snmpGet(pdu)
            case .getNextRequest:
                self = .snmpGetNext(pdu)
            case .getResponse:
                self = .snmpResponse(pdu)
            case .snmpReport:
                self = .snmpReport(pdu)
            }
            return
        default:
            SnmpError.log("Unexpected identifier octet \(identifierOctet) in \(data.hexdump)")
            throw SnmpError.unsupportedType
        }
    }
    
    static func prefixLength(data: Data) throws -> Int {
        // input: the Data starting with the ASN1 type octet to be analyzed
        // output: the count of the type and length octets.  In other words how many octets to skip to get to the data
        guard data.count > 1 else {
            throw SnmpError.badLength
        }
        if data[data.startIndex+1] < 128 {
            return 2
        } else {
            return Int(data[data.startIndex+1]) - 126
        }
    }
    static func valueLength(data: Data) throws -> Int {
        // pass the octet that starts the length term
        // returns number of data octets which encodes the value using BER rules.  does not include the type or length fields itself
        guard data.count > 0 else {
            SnmpError.log("Bad length length \(data.hexdump)")
            throw SnmpError.badLength
        }
        let firstOctet = data[data.startIndex]
        guard firstOctet > 127 else {
            return Int(firstOctet)
        }
        let numberLengthBytes = Int(firstOctet & 0b01111111)
        guard data.count > numberLengthBytes else {
            SnmpError.log("Invalid Length \(data.hexdump)")
            throw SnmpError.badLength
        }
        var length = Int(data[data.startIndex + 1])
        for position in 2..<(numberLengthBytes+1) {
            length = length * 256 + Int(data[data.startIndex + position])
        }
        return length
    }
    
    public var stringValue: String {
        switch self {
            
        case .endOfContent:
            return "EndOfContent"
        case .integer(let integer):
            return "\(integer)"
        case .bitString(let bitString):
            return "\(bitString)"
        case .octetString(let octetString):
            if let text = String(data: octetString, encoding: .utf8) {
                return "\(text)"
            } else {
                return "\(octetString.hexdump)"
            }
        case .oid(let oid):
            return "\(oid)"
        case .null:
            return "Null"
        case .sequence(let contents):
            var result = ""
            for content in contents {
                result += "  \(content)\n"
            }
            return result
        case .ia5(let string):
            return "\(string)"
        case .snmpResponse(let pdu):
            return "\(pdu)"
        case .snmpGet(let pdu):
            return "\(pdu)"
        case .snmpGetNext(let pdu):
            return "\(pdu)"
        case .snmpReport(let pdu):
            return "\(pdu)"
        case .ipv4(let address):
            let octet1 = (address & 0xff000000) >> 24
            let octet2 = (address & 0x00ff0000) >> 16
            let octet3 = (address & 0x0000ff00) >> 8
            let octet4 = (address & 0x000000ff)
            return "\(octet1).\(octet2).\(octet3).\(octet4)"
        case .counter32(let value):
            return "\(value)"
        case .gauge32(let value):
            return "\(value)"
        case .timeticks(let ticks):
            return "\(ticks)"
        case .counter64(let value):
            return "\(value)"
        case .noSuchObject:
            return "NoSuchObject"
        case .endOfMibView:
            return "EndOfMibView"
        
    }
    
    public var description: String {
        switch self {
            
        case .endOfContent:
            return "EndOfContent"
        case .integer(let integer):
            return "Integer: \(integer)"
        case .bitString(let bitString):
            return "BitString: \(bitString)"
        case .octetString(let octetString):
            if let text = String(data: octetString, encoding: .utf8) {
                return "OctetString: \(text)"
            } else {
                return "OctetString: \(octetString.hexdump)"
            }
        case .oid(let oid):
            return "Oid: \(oid)"
        case .null:
            return "Null"
        case .sequence(let contents):
            var result = "Sequence:\n"
            for content in contents {
                result += "  \(content)\n"
            }
            return result
        case .ia5(let string):
            return "IA5: \(string)"
        case .snmpResponse(let pdu):
            return "SNMP Response \(pdu)"
        case .snmpGet(let pdu):
            return "SNMP Get \(pdu)"
        case .snmpGetNext(let pdu):
            return "SNMP GetNext \(pdu)"
        case .snmpReport(let pdu):
            return "SNMP Report \(pdu)"
        case .ipv4(let address):
            let octet1 = (address & 0xff000000) >> 24
            let octet2 = (address & 0x00ff0000) >> 16
            let octet3 = (address & 0x0000ff00) >> 8
            let octet4 = (address & 0x000000ff)
            return "IPv4: \(octet1).\(octet2).\(octet3).\(octet4)"
        case .counter32(let value):
            return "Counter32: \(value)"
        case .gauge32(let value):
            return "Gauge32: \(value)"
        case .timeticks(let ticks):
            return "Timeticks: \(ticks)"
        case .counter64(let value):
            return "Counter64: \(value)"
        case .noSuchObject:
            return "NoSuchObject"
        case .endOfMibView:
            return "EndOfMibView"

        }
    }

}
