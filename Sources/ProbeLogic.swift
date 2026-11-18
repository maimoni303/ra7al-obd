import Foundation

/// Pure helpers (no CoreBluetooth) so they can be unit-tested.
enum ProbeLogic {
    /// Commands tried on every writable characteristic, in order.
    /// Read-only requests only: reset/identify, then standard OBD2 Mode 01/09 reads.
    static let probeCommands: [String] = [
        "ATZ",     // reset, prints ELM version
        "ATE0",    // echo off
        "ATL0",    // linefeeds off
        "ATS0",    // spaces off
        "ATH0",    // headers off
        "ATI",     // identify
        "AT@1",    // device description
        "ATRV",    // battery voltage (adapter)
        "ATSP0",   // auto protocol
        "0100",    // supported PIDs 01-20
        "ATDPN",   // which protocol was found
        "0120",    // supported PIDs 21-40
        "0140",    // supported PIDs 41-60
        "0151",    // fuel type
        "0105",    // coolant temp
        "010C",    // rpm
        "010D",    // speed
        "0902",    // VIN
        "0101",    // MIL status / DTC count
    ]

    /// Well-known BLE service UUIDs used by ELM327-style adapters.
    static let knownSerialServices: Set<String> = ["FFF0", "FFE0", "18F0", "E7810A71-73AE-499D-8C15-FAA9AEF0C3F2"]

    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    /// Printable ASCII view; control characters shown as escapes.
    static func ascii(_ data: Data) -> String {
        data.map { b -> String in
            switch b {
            case 0x0D: return "\\r"
            case 0x0A: return "\\n"
            case 0x20...0x7E: return String(UnicodeScalar(b))
            default: return "·"
            }
        }.joined()
    }

    /// True if the reply text looks like it came from an ELM327 interpreter.
    static func looksLikeELM(_ text: String) -> Bool {
        let t = text.uppercased()
        return t.contains("ELM") || t.contains("OK") || t.contains(">")
            || t.range(of: #"41\s?00"#, options: .regularExpression) != nil
            || t.contains("SEARCHING") || t.contains("NO DATA") || t.contains("UNABLE TO CONNECT")
    }

    /// Decode "41 51 XX" fuel type (SAE J1979 table) if present in a reply.
    static func fuelType(fromReply text: String) -> String? {
        let compact = text.uppercased().replacingOccurrences(of: " ", with: "")
        guard let r = compact.range(of: "4151") else { return nil }
        let after = compact[r.upperBound...]
        guard after.count >= 2, let v = UInt8(after.prefix(2), radix: 16) else { return nil }
        switch v {
        case 1: return "بنزين Gasoline"
        case 4: return "ديزل Diesel"
        case 8: return "كهرباء Electric"
        case 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22: return "هجين/مزدوج (\(v))"
        default: return "نوع \(v)"
        }
    }

    /// Splits a multi-frame reply and pulls VIN characters from a Mode 09 PID 02 answer.
    static func vin(fromReply text: String) -> String? {
        let cleaned = text.uppercased()
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        // Drop line prefixes like "0:" "1:" used by CAN multi-frame output.
        let tokens = cleaned.split(separator: " ").map(String.init).filter { !$0.hasSuffix(":") }
        var bytes: [UInt8] = []
        for tok in tokens {
            var s = Substring(tok)
            if s.contains(":") { s = s.split(separator: ":").last ?? "" }
            var i = s.startIndex
            while i < s.endIndex, let j = s.index(i, offsetBy: 2, limitedBy: s.endIndex) {
                if let b = UInt8(s[i..<j], radix: 16) { bytes.append(b) }
                i = j
            }
        }
        let chars = bytes.filter { (0x30...0x39).contains($0) || (0x41...0x5A).contains($0) }
        let str = String(decoding: chars, as: UTF8.self)
        // A VIN is 17 chars without I, O, Q.
        guard let m = str.range(of: #"[A-HJ-NPR-Z0-9]{17}"#, options: .regularExpression) else { return nil }
        return String(str[m])
    }
}
