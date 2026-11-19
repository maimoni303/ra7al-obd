import Foundation

/// Pure helpers (no CoreBluetooth) so they can be unit-tested.
enum ProbeLogic {
    /// Commands tried on every writable characteristic, in order.
    /// Read-only requests only: reset/identify, then standard OBD2 Mode 01/09 reads.
    static let probeCommands: [String] = [
        "ATZ",     // reset, prints ELM version
        "ATE0",    // echo off
        "ATH0",    // headers off
        "ATRV",    // battery voltage (adapter)
        "0100",    // supported PIDs 01-20 (also opens the bus)
        "ATDPN",   // protocol number
        "ATDP",    // protocol name
        "0120", "0140", "0160", "0180", "01A0", "01C0", // supported PID bitmaps
        "0101",    // MIL status / DTC count
        "0151",    // fuel type
        "0104", "0105", "010B", "010C", "010D", "010F", "0110", "011F",
        "0121", "0123", "0131", "0133", "0142", "0146", "015C", "015E",
        "03",      // stored trouble codes (read only)
        "07",      // pending trouble codes (read only)
        "0A",      // permanent trouble codes (read only)
        "0900",    // supported Mode 09 PIDs
        "0902",    // VIN
        "0904",    // calibration ID
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
        let cleaned = stripChatter(text).uppercased()
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

    // MARK: - Reply parsing (standard ELM327 and the NONDA "ECU:n CMD:xxxx CNT:n" format)

    /// Removes adapter chatter so only data lines remain.
    static func stripChatter(_ text: String) -> String {
        var t = text.replacingOccurrences(of: "\r", with: "\n")
        let patterns = [
            #"(?i)connected[^\n]*"#,
            #"(?i)ECU:\s*\d+\s+CMD:\s*[0-9A-F]+\s+CNT:\s*\d+"#,
            #"(?i)ECU:\s*\d+\s+CMD:\s*[0-9A-F]+"#,
            #"(?i)SEARCHING\.*"#, #">"#,
        ]
        for p in patterns { t = t.replacingOccurrences(of: p, with: "\n", options: .regularExpression) }
        return t
    }

    /// Every line made only of hex byte pairs, returned as byte arrays (multi-frame "0:" prefixes dropped).
    static func dataLines(_ text: String) -> [[UInt8]] {
        stripChatter(text).split(separator: "\n").compactMap { raw -> [UInt8]? in
            var line = raw.trimmingCharacters(in: .whitespaces).uppercased()
            if let r = line.range(of: #"^[0-9A-F]:"#, options: .regularExpression) { line.removeSubrange(r) }
            let compact = line.replacingOccurrences(of: " ", with: "")
            guard compact.count >= 2, compact.count % 2 == 0,
                  compact.range(of: #"^[0-9A-F]+$"#, options: .regularExpression) != nil else { return nil }
            var out: [UInt8] = []
            var i = compact.startIndex
            while i < compact.endIndex {
                let j = compact.index(i, offsetBy: 2)
                out.append(UInt8(compact[i..<j], radix: 16)!)
                i = j
            }
            return out
        }
    }

    /// Data bytes (after "41 PID") of the first matching Mode 01 answer.
    static func mode01(_ pid: UInt8, in text: String) -> [UInt8]? {
        for l in dataLines(text) {
            if let k = (0..<max(0, l.count - 1)).first(where: { l[$0] == 0x41 && l[$0 + 1] == pid }) {
                return Array(l[(k + 2)...])
            }
        }
        return nil
    }

    /// PIDs reported as supported by a bitmap reply to 0100/0120/…; union of all ECUs.
    static func supportedPIDs(base: UInt8, in text: String) -> [UInt8] {
        var set = Set<UInt8>()
        for l in dataLines(text) {
            guard let k = (0..<max(0, l.count - 1)).first(where: { l[$0] == 0x41 && l[$0 + 1] == base }),
                  l.count >= k + 6 else { continue }
            let bits = Array(l[(k + 2)..<(k + 6)])
            for (byteIx, b) in bits.enumerated() {
                for bit in 0..<8 where b & (0x80 >> bit) != 0 {
                    set.insert(base &+ UInt8(byteIx * 8 + bit + 1))
                }
            }
        }
        return set.sorted()
    }

    /// Human-readable value for a Mode 01 PID (SAE J1979 formulas).
    static func describe(pid: UInt8, data d: [UInt8]) -> String? {
        func a() -> Double { Double(d[0]) }
        func ab() -> Double { Double(Int(d[0]) * 256 + Int(d[1])) }
        switch pid {
        case 0x01 where d.count >= 1:
            let mil = d[0] & 0x80 != 0
            return "لمبة الأعطال: \(mil ? "مضاءة" : "مطفأة") — عدد الأكواد: \(d[0] & 0x7F)"
        case 0x04 where d.count >= 1: return String(format: "حمل المحرك: %.0f%%", a() * 100 / 255)
        case 0x05 where d.count >= 1: return "حرارة الماء: \(Int(d[0]) - 40)°C"
        case 0x0B where d.count >= 1: return "ضغط المنفولد: \(d[0]) kPa"
        case 0x0C where d.count >= 2: return String(format: "دورات المحرك: %.0f rpm", ab() / 4)
        case 0x0D where d.count >= 1: return "السرعة: \(d[0]) km/h"
        case 0x0F where d.count >= 1: return "حرارة هواء السحب: \(Int(d[0]) - 40)°C"
        case 0x10 where d.count >= 2: return String(format: "تدفق الهواء MAF: %.2f g/s", ab() / 100)
        case 0x1F where d.count >= 2: return String(format: "زمن التشغيل: %.0f ثانية", ab())
        case 0x21 where d.count >= 2: return String(format: "مسافة مع لمبة الأعطال: %.0f km", ab())
        case 0x23 where d.count >= 2: return String(format: "ضغط سكة الديزل: %.0f kPa", ab() * 10)
        case 0x31 where d.count >= 2: return String(format: "مسافة منذ مسح الأكواد: %.0f km", ab())
        case 0x33 where d.count >= 1: return "الضغط الجوي: \(d[0]) kPa"
        case 0x42 where d.count >= 2: return String(format: "جهد وحدة التحكم: %.2f V", ab() / 1000)
        case 0x46 where d.count >= 1: return "حرارة الجو: \(Int(d[0]) - 40)°C"
        case 0x51 where d.count >= 1: return fuelType(fromReply: "4151" + String(format: "%02X", d[0])).map { "نوع الوقود: \($0)" }
        case 0x5C where d.count >= 1: return "حرارة الزيت: \(Int(d[0]) - 40)°C"
        case 0x5E where d.count >= 2: return String(format: "استهلاك الوقود: %.1f L/h", ab() / 20)
        default: return nil
        }
    }

    /// Trouble codes from a Mode 03/07/0A reply (CAN: "43 NN XX XX …", legacy: "43 XX XX …").
    static func troubleCodes(service: UInt8, in text: String) -> [String] {
        let answer = service &+ 0x40
        var codes: [String] = []
        for l in dataLines(text) {
            guard let k = l.firstIndex(of: answer) else { continue }
            var body = Array(l[(k + 1)...])
            if body.count % 2 == 1 { body.removeFirst() } // CAN count byte
            var i = 0
            while i + 1 < body.count {
                let hi = body[i], lo = body[i + 1]
                i += 2
                if hi == 0 && lo == 0 { continue }
                let letter = ["P", "C", "B", "U"][Int(hi >> 6)]
                let code = letter + String(hi >> 4 & 0x3) + String(format: "%01X%02X", hi & 0x0F, lo)
                if !codes.contains(code) { codes.append(code) }
            }
        }
        return codes
    }

    // MARK: - NONDA passive stream ("BD$V14.5;R00608;S000;GX1;GY-6;GZ-63;@3 …")

    /// Latest value of every key the adapter pushes on its own, in first-seen order.
    static func streamFields(_ text: String) -> [(key: String, value: String)] {
        var order: [String] = []
        var latest: [String: String] = [:]
        let lines = text.replacingOccurrences(of: "\r", with: "\n").split(separator: "\n")
        for line in lines where line.contains(";") || line.hasPrefix("BD$") {
            var l = String(line)
            if let r = l.range(of: "BD$") { l = String(l[r.upperBound...]) }
            for tok in l.split(separator: ";") {
                let t = tok.trimmingCharacters(in: .whitespaces)
                guard let m = t.range(of: #"^(XH|GX|GY|GZ|[A-Z@])-?[0-9]+(\.[0-9]+)?$"#, options: .regularExpression), m == t.startIndex..<t.endIndex else { continue }
                let key = t.hasPrefix("XH") || t.hasPrefix("GX") || t.hasPrefix("GY") || t.hasPrefix("GZ") ? String(t.prefix(2)) : String(t.prefix(1))
                let val = String(t.dropFirst(key.count))
                if latest[key] == nil { order.append(key) }
                latest[key] = val
            }
        }
        return order.map { ($0, latest[$0]!) }
    }
}
