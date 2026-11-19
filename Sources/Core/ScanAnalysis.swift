import Foundation

// MARK: - Ford modules (read-only UDS service 0x19 "read DTC information")

struct FordModuleSpec: Identifiable {
    var key: String
    var name: String
    var header: String
    var id: String { key }

    static let all: [FordModuleSpec] = [
        FordModuleSpec(key: "pcm", name: "المحرك PCM", header: "7E0"),
        FordModuleSpec(key: "tcm", name: "القير TCM", header: "7E1"),
        FordModuleSpec(key: "abs", name: "الفرامل ABS", header: "760"),
        FordModuleSpec(key: "rcm", name: "الإيرباق RCM", header: "737"),
        FordModuleSpec(key: "bcm", name: "البودي BCM", header: "726"),
        FordModuleSpec(key: "ipc", name: "العدادات IPC", header: "720"),
    ]

    static func spec(_ key: String) -> FordModuleSpec? { all.first { $0.key == key } }
}

struct ModuleResult: Codable, Equatable, Identifiable {
    var key: String
    /// The module answered (positively or with a "not supported" reply).
    var responded: Bool
    /// The module allowed its trouble codes to be read.
    var readable: Bool
    var dtcs: [String] = []
    var id: String { key }
    var name: String { FordModuleSpec.spec(key)?.name ?? key.uppercased() }
}

enum UDS {
    /// Request sent to each module: report DTCs by status mask (testFailed | confirmed | …).
    static let readDTCRequest = "19028F"

    /// Parses a `59 02 <mask> [DTC_hi DTC_mid FTB status]…` reply (single or multi-frame).
    static func parseDTCReply(_ reply: String) -> (responded: Bool, readable: Bool, codes: [String]) {
        let bytes = ProbeLogic.dataLines(reply).flatMap { $0 }
        if (0..<max(0, bytes.count - 1)).contains(where: { bytes[$0] == 0x7F && bytes[$0 + 1] == 0x19 }) {
            return (true, false, [])
        }
        guard let k = (0..<max(0, bytes.count - 1)).first(where: { bytes[$0] == 0x59 && bytes[$0 + 1] == 0x02 }) else {
            return (false, false, [])
        }
        var codes: [String] = []
        var i = k + 3   // skip 59 02 and the availability mask
        while i + 3 < bytes.count {
            let hi = bytes[i], mid = bytes[i + 1], status = bytes[i + 3]
            i += 4
            guard hi != 0 || mid != 0, status & 0x09 != 0 else { continue }
            let code = dtcString(hi: hi, lo: mid)
            if !codes.contains(code) { codes.append(code) }
        }
        return (true, true, codes)
    }

    static func dtcString(hi: UInt8, lo: UInt8) -> String {
        let letter = ["P", "C", "B", "U"][Int(hi >> 6)]
        return letter + String(hi >> 4 & 0x3) + String(format: "%01X%02X", hi & 0x0F, lo)
    }

    /// Ford PCM odometer (DID DD01, 3 bytes, km) from a `62 DD 01 A B C` reply.
    static func fordOdometerKm(_ reply: String) -> Double? {
        for l in ProbeLogic.dataLines(reply) {
            guard let k = (0..<max(0, l.count - 2)).first(where: { l[$0] == 0x62 && l[$0 + 1] == 0xDD && l[$0 + 2] == 0x01 }),
                  l.count >= k + 6 else { continue }
            return Double(Int(l[k + 3]) << 16 | Int(l[k + 4]) << 8 | Int(l[k + 5]))
        }
        return nil
    }

    /// Engine run time and idle time in hours from Mode 01 PID 7F (`41 7F A B..E F..I …`).
    static func engineHours(_ reply: String) -> (total: Double, idle: Double)? {
        guard let d = ProbeLogic.mode01(0x7F, in: reply), d.count >= 9 else { return nil }
        func u32(_ o: Int) -> Double { Double(UInt32(d[o]) << 24 | UInt32(d[o + 1]) << 16 | UInt32(d[o + 2]) << 8 | UInt32(d[o + 3])) }
        let total = u32(1) / 3600
        let idle = u32(5) / 3600
        guard total > 0, total < 200_000 else { return nil }
        return (total, idle)
    }

    /// Freeze-frame value `42 PID 00 …` for Mode 02 frame 0.
    static func freezeFrame(_ pid: UInt8, in reply: String) -> [UInt8]? {
        for l in ProbeLogic.dataLines(reply) {
            if let k = (0..<max(0, l.count - 2)).first(where: { l[$0] == 0x42 && l[$0 + 1] == pid && l[$0 + 2] == 0x00 }) {
                let d = Array(l[(k + 3)...])
                return d.isEmpty ? nil : d
            }
        }
        return nil
    }
}

/// Engine conditions when the first fault was stored (Mode 02, frame 0).
struct FreezeFrame: Codable, Equatable {
    var dtc: String?
    var rpm: Double?
    var speedKmh: Double?
    var coolantC: Double?
}

// MARK: - VIN decoding (offline)

struct VehicleIdentity: Equatable {
    var make: String
    var model: String?
    var year: Int?
    var engine: String?
    var plant: String?

    var displayName: String {
        [make, model, year.map(String.init)].compactMap { $0 }.joined(separator: " ")
    }

    static func decode(_ vin: String) -> VehicleIdentity? {
        let v = Array(vin.uppercased())
        guard v.count == 17 else { return nil }
        let wmi = String(v[0..<3])
        let ford = ["1FT", "1FD", "1FM", "1FA", "1FB", "1FC", "2FT", "3FT", "3FD", "2FM", "3FA", "1ZV"]
        guard ford.contains(wmi) else { return VehicleIdentity(make: "غير معروف (\(wmi))", year: VIN.year(vin)) }
        var id = VehicleIdentity(make: "Ford", year: VIN.year(vin))
        if ["1FT", "1FD", "2FT", "3FT", "3FD"].contains(wmi) {
            switch v[5] {
            case "1": id.model = "F-150"
            case "2": id.model = "F-250 Super Duty"
            case "3": id.model = "F-350 Super Duty"
            case "4": id.model = "F-450 Super Duty"
            case "5": id.model = "F-550 Super Duty"
            default: break
            }
            if id.model?.contains("Super Duty") == true {
                switch v[7] {
                case "T": id.engine = "6.7L Power Stroke V8 ديزل"
                case "6": id.engine = "6.2L V8 بنزين"
                case "N": id.engine = "7.3L V8 بنزين"
                default: break
                }
            }
        }
        switch v[10] {
        case "E": id.plant = "Kentucky Truck"
        case "D": id.plant = "Ohio Assembly"
        case "F": id.plant = "Dearborn"
        case "K": id.plant = "Kansas City"
        case "C": id.plant = "Ontario"
        default: break
        }
        return id
    }
}

// MARK: - Verdict and sections

enum SectionStatus: Int, Comparable {
    case ok = 0, warn = 1, danger = 2, unavailable = -1
    static func < (a: SectionStatus, b: SectionStatus) -> Bool { a.rawValue < b.rawValue }
    var label: String {
        switch self {
        case .ok: return "سليم"
        case .warn: return "تنبيه"
        case .danger: return "خطر"
        case .unavailable: return "غير متاح"
        }
    }
    init(_ l: AlertLevel) {
        switch l {
        case .ok: self = .ok
        case .warn: self = .warn
        case .danger: self = .danger
        }
    }
}

struct ScanSection: Identifiable, Equatable {
    enum Kind: String { case engine, transmission, abs, airbag, body, tires, battery, maintenance, cluster }
    var kind: Kind
    var title: String
    var detail: String
    var status: SectionStatus
    var badge: String
    var codes: [String] = []
    var id: String { kind.rawValue }
}

enum Confidence: Int, Comparable {
    case low = 0, medium = 1, high = 2
    static func < (a: Confidence, b: Confidence) -> Bool { a.rawValue < b.rawValue }
    var title: String {
        switch self {
        case .low: return "منخفضة"
        case .medium: return "متوسطة"
        case .high: return "عالية"
        }
    }
}

struct ScanVerdict: Equatable {
    var drive: DriveAdvice
    var urgency: Urgency
    var confidence: Confidence
    var sections: [ScanSection]
    var reason: String?

    var headline: String {
        switch drive {
        case .safe: return "تقدر تسوق بأمان"
        case .caution: return "تقدر تسوق بحذر"
        case .stop: return "أوقف السيارة"
        }
    }

    var short: String {
        switch drive {
        case .safe: return "بأمان"
        case .caution: return "بحذر"
        case .stop: return "أوقف"
        }
    }

    var symbol: String {
        switch drive {
        case .safe: return "checkmark.shield.fill"
        case .caution: return "exclamationmark.triangle.fill"
        case .stop: return "xmark.octagon.fill"
        }
    }

    static func evaluate(_ r: ScanReport, data: AppData, now: Date = Date()) -> ScanVerdict {
        let l = data.limits
        var drive: DriveAdvice = .safe
        var urgency: Urgency = .none
        var reason: String?
        let codes = r.allDTCs
        var unknownCodes = 0
        for c in codes {
            let i = DTCKnowledge.info(c)
            if i.generic { unknownCodes += 1 }
            if i.drive > drive { drive = i.drive; reason = "\(c): \(i.title)" }
            urgency = max(urgency, i.urgency)
        }
        if r.milOn && drive == .safe { drive = .caution; urgency = max(urgency, .soon); reason = reason ?? "لمبة فحص المحرك مضاءة" }
        if l.coolantLevel(r.coolantC) == .danger, let c = r.coolantC {
            drive = .stop; urgency = .now; reason = "حرارة الماء \(Int(c))° — أعلى من حد فورد"
        }
        if l.oilLevel(r.oilC) == .danger, let c = r.oilC {
            drive = .stop; urgency = .now; reason = "حرارة الزيت \(Int(c))° — أعلى من الحد"
        }

        let mods = r.modules ?? []
        func module(_ key: String) -> ModuleResult? { mods.first { $0.key == key } }
        func codeStatus(_ list: [String]) -> SectionStatus {
            guard !list.isEmpty else { return .ok }
            let worst = list.map { DTCKnowledge.info($0).drive }.max() ?? .caution
            return worst == .stop ? .danger : .warn
        }
        func moduleSection(_ kind: ScanSection.Kind, _ title: String, _ key: String) -> ScanSection {
            let spec = FordModuleSpec.spec(key)
            guard let m = module(key), m.responded else {
                return ScanSection(kind: kind, title: title, detail: "القطعة لم تسمح بالوصول لهذا الكمبيوتر", status: .unavailable, badge: "غير متاح")
            }
            guard m.readable else {
                return ScanSection(kind: kind, title: title, detail: "الكمبيوتر يرد لكن ما سمح بقراءة الأكواد", status: .unavailable, badge: "غير متاح")
            }
            let st = codeStatus(m.dtcs)
            let detail = m.dtcs.isEmpty ? "كمبيوتر فورد \(spec?.header ?? "") • لا أكواد" : m.dtcs.joined(separator: "، ")
            return ScanSection(kind: kind, title: title, detail: detail, status: st,
                               badge: m.dtcs.isEmpty ? "سليم" : "\(m.dtcs.count) كود", codes: m.dtcs)
        }

        var sections: [ScanSection] = []

        // Engine: generic OBD codes outside the transmission range + PCM module codes.
        let isTrans: (String) -> Bool = { c in c.hasPrefix("P07") || c.hasPrefix("P08") || c.hasPrefix("P09") }
        let generic = r.storedDTCs + r.pendingDTCs + r.permanentDTCs
        var engineCodes = Array(Set(generic.filter { $0.hasPrefix("P") && !isTrans($0) } + (module("pcm")?.dtcs ?? []).filter { !isTrans($0) })).sorted()
        engineCodes += generic.filter { $0.hasPrefix("U") && !engineCodes.contains($0) }
        var engineStatus = codeStatus(engineCodes)
        if r.milOn && engineStatus == .ok { engineStatus = .warn }
        let tempLevel = max(l.coolantLevel(r.coolantC), l.oilLevel(r.oilC))
        if tempLevel != .ok { engineStatus = max(engineStatus, SectionStatus(tempLevel)) }
        var engineDetail = engineCodes.isEmpty ? "لا أكواد" : engineCodes.joined(separator: "، ")
        if let c = r.coolantC { engineDetail += " • الماء \(Int(c))°" }
        if r.milOn { engineDetail += " • لمبة المحرك مضاءة" }
        sections.append(ScanSection(kind: .engine, title: "المحرك والانبعاثات", detail: engineDetail, status: engineStatus,
                                    badge: engineCodes.isEmpty ? (engineStatus == .ok ? "سليم" : "تنبيه") : "\(engineCodes.count) كود", codes: engineCodes))

        let transCodes = Array(Set(generic.filter(isTrans) + (module("tcm")?.dtcs ?? []) + (module("pcm")?.dtcs ?? []).filter(isTrans))).sorted()
        let transStatus = codeStatus(transCodes)
        sections.append(ScanSection(kind: .transmission, title: "ناقل الحركة (القير)",
                                    detail: transCodes.isEmpty ? "لا أكواد" : transCodes.joined(separator: "، "),
                                    status: transStatus, badge: transCodes.isEmpty ? "سليم" : "\(transCodes.count) كود", codes: transCodes))

        sections.append(moduleSection(.abs, "الفرامل ABS", "abs"))
        sections.append(moduleSection(.airbag, "الإيرباق", "rcm"))
        sections.append(moduleSection(.body, "البودي والإضاءة BCM", "bcm"))

        // Tyres
        if r.tires.hasAny {
            let t = r.tires
            let items: [(Double?, Bool, String)] = [(t.frontLeft, true, "أمامي يسار"), (t.frontRight, true, "أمامي يمين"),
                                                    (t.rearLeft, false, "خلفي يسار"), (t.rearRight, false, "خلفي يمين")]
            var worst: AlertLevel = .ok
            var worstName = ""
            var worstPsi = 0.0
            for (v, front, name) in items {
                let lv = l.tireLevel(psi: v, front: front)
                if lv > worst, let v { worst = lv; worstName = name; worstPsi = v }
            }
            sections.append(ScanSection(kind: .tires, title: "ضغط الكفرات", detail: "من حساسات الفورد الأصلية",
                                        status: SectionStatus(worst), badge: worst == .ok ? "سليم" : "\(worstName) \(Int(worstPsi))"))
        } else {
            sections.append(ScanSection(kind: .tires, title: "ضغط الكفرات", detail: r.tireSource ?? "وحدة الكفرات ما ردت",
                                        status: .unavailable, badge: "غير متاح"))
        }

        // Battery / charging
        if let v = r.batteryV {
            let charging = v >= 13.2
            let lv = charging ? AlertLevel.ok : l.voltageLevel(v, engineRunning: false)
            sections.append(ScanSection(kind: .battery, title: "البطارية والشحن",
                                        detail: String(format: charging ? "%.1f فولت — الدينمو يشحن" : "%.1f فولت", v),
                                        status: SectionStatus(lv), badge: lv == .ok ? (charging ? "ممتاز" : "سليم") : "ضعيفة"))
        } else {
            sections.append(ScanSection(kind: .battery, title: "البطارية والشحن", detail: "لم تُقرأ", status: .unavailable, badge: "غير متاح"))
        }

        // Maintenance (oil life)
        if let p = data.oil.lifePercent(now: now) {
            let km = data.oil.kmLeft(now: now).map { "باقي \(Int($0)) كم على الغيار" } ?? ""
            let lv = data.oil.level(now: now)
            sections.append(ScanSection(kind: .maintenance, title: "الصيانة والزيت", detail: km, status: SectionStatus(lv),
                                        badge: "\(Int(p))%"))
            if lv == .danger { urgency = max(urgency, .soon) }
        } else {
            sections.append(ScanSection(kind: .maintenance, title: "الصيانة والزيت", detail: "سجّل آخر تغيير زيت من صفحة الزيت",
                                        status: .unavailable, badge: "غير مسجل"))
        }

        sections.append(moduleSection(.cluster, "العدادات IPC", "ipc"))

        let unavailable = sections.filter { $0.status == .unavailable }.count
        var confidence: Confidence = unavailable <= 1 ? .high : (unavailable <= 3 ? .medium : .low)
        if unknownCodes > 0 { confidence = min(confidence, .medium) }
        return ScanVerdict(drive: drive, urgency: urgency, confidence: confidence, sections: sections, reason: reason)
    }
}
