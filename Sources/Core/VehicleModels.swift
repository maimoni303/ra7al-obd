import Foundation

// MARK: - Alert levels and limits

enum AlertLevel: Int, Codable, Comparable {
    case ok = 0, warn = 1, danger = 2
    static func < (a: AlertLevel, b: AlertLevel) -> Bool { a.rawValue < b.rawValue }
}

/// User-adjustable limits. Defaults are conservative values for the 6.7 L Power Stroke; all editable in Settings.
struct Limits: Codable, Equatable {
    var coolantWarn: Double = 108
    var coolantDanger: Double = 115
    var oilWarn: Double = 120
    var oilDanger: Double = 130
    var fuelWarnPercent: Double = 25
    var rangeDangerKm: Double = 80
    var tireFrontPsi: Double = 60
    var tireRearPsi: Double = 75
    /// A tyre is "low" below this share of its placard pressure (Ford's TPMS uses about 25 %; we warn earlier).
    var tireLowRatio: Double = 0.85
    var chargingLowVolts: Double = 13.2
    var batteryLowVolts: Double = 12.2

    func coolantLevel(_ c: Double?) -> AlertLevel { Limits.rising(c, warn: coolantWarn, danger: coolantDanger) }
    func oilLevel(_ c: Double?) -> AlertLevel { Limits.rising(c, warn: oilWarn, danger: oilDanger) }

    func fuelLevel(percent: Double?, rangeKm: Double?) -> AlertLevel {
        if let r = rangeKm, r <= rangeDangerKm { return .danger }
        if let p = percent, p <= fuelWarnPercent { return .warn }
        return .ok
    }

    func tireLevel(psi: Double?, front: Bool) -> AlertLevel {
        guard let psi else { return .ok }
        let ref = front ? tireFrontPsi : tireRearPsi
        if psi < ref * (tireLowRatio - 0.15) { return .danger }
        if psi < ref * tireLowRatio { return .warn }
        return .ok
    }

    func voltageLevel(_ v: Double?, engineRunning: Bool) -> AlertLevel {
        guard let v else { return .ok }
        if engineRunning { return v < chargingLowVolts ? .warn : .ok }
        return v < batteryLowVolts ? .warn : .ok
    }

    static func rising(_ v: Double?, warn: Double, danger: Double) -> AlertLevel {
        guard let v else { return .ok }
        if v >= danger { return .danger }
        if v >= warn { return .warn }
        return .ok
    }
}

// MARK: - Live readings

struct TireSet: Codable, Equatable {
    var frontLeft: Double?
    var frontRight: Double?
    var rearLeft: Double?
    var rearRight: Double?
    var hasAny: Bool { [frontLeft, frontRight, rearLeft, rearRight].contains { $0 != nil } }
}

struct Readings: Equatable {
    var rpm: Double?
    var speedKmh: Double?
    var coolantC: Double?
    var oilC: Double?
    var loadPercent: Double?
    var mapKPa: Double?
    var intakeC: Double?
    var ambientC: Double?
    var baroKPa: Double?
    var railKPa: Double?
    var mafGs: Double?
    var fuelRateLh: Double?
    var fuelLevelPercent: Double?
    var batteryV: Double?
    var ecuV: Double?
    var runTimeS: Double?
    var milOn: Bool?
    var dtcCount: Int?
    var tires = TireSet()
    var updatedAt: Date?

    var engineRunning: Bool { (rpm ?? 0) > 300 }
}

// MARK: - Fuel range

struct FuelModel: Codable, Equatable {
    var tankLiters: Double = 129
    /// Learned average consumption in L/100 km (exponentially weighted).
    var avgLper100: Double = 14.0
    var learnedKm: Double = 0
    var lastLevelPercent: Double?
    var refuels: [Refuel] = []

    struct Refuel: Codable, Equatable {
        var date: Date
        var fromPercent: Double
        var toPercent: Double
        var liters: Double
    }

    func litersLeft(levelPercent: Double) -> Double { max(0, min(100, levelPercent)) / 100 * tankLiters }

    func rangeKm(levelPercent: Double?) -> Double? {
        guard let p = levelPercent, avgLper100 > 0 else { return nil }
        return litersLeft(levelPercent: p) / avgLper100 * 100
    }

    /// Feed one sample of driving. Idle time is ignored for the average (it has no distance) but still burns fuel,
    /// which shows up as a lower tank level and therefore a shorter range.
    mutating func learn(fuelRateLh: Double, speedKmh: Double, seconds: Double) {
        guard speedKmh > 8, fuelRateLh > 0, seconds > 0, seconds < 30 else { return }
        let km = speedKmh * seconds / 3600
        let instant = fuelRateLh / speedKmh * 100
        guard instant > 2, instant < 80 else { return }
        // Learns fast at first, then behaves like a ~300 km moving average.
        let horizon = min(300, learnedKm + 20)
        let w = min(0.2, km / horizon)
        avgLper100 = avgLper100 * (1 - w) + instant * w
        learnedKm += km
    }

    /// Detects a refuel (level jumps up ≥ 12 % while stopped). Returns the refuel when one is found.
    mutating func observe(levelPercent: Double, speedKmh: Double, at date: Date = Date()) -> Refuel? {
        defer { lastLevelPercent = levelPercent }
        guard let last = lastLevelPercent, speedKmh < 3, levelPercent - last >= 12 else { return nil }
        let r = Refuel(date: date, fromPercent: last, toPercent: levelPercent, liters: (levelPercent - last) / 100 * tankLiters)
        refuels.append(r)
        if refuels.count > 50 { refuels.removeFirst(refuels.count - 50) }
        return r
    }
}

// MARK: - Odometer and oil life

struct OilModel: Codable, Equatable {
    var intervalKm: Double = 8000
    var intervalEngineHours: Double = 250
    var intervalDays: Double = 180
    /// One hour of idling wears oil roughly like this many km of driving.
    var idleHourKmEquivalent: Double = 50

    var odometerKm: Double = 99173.6
    var lastChangeOdometerKm: Double?
    var lastChangeDate: Date?
    var engineHoursSinceChange: Double = 0
    var idleHoursSinceChange: Double = 0
    var totalEngineHours: Double = 0
    var totalIdleHours: Double = 0
    /// Oil life reported by the truck itself (Ford IOLM), when it can be read.
    var fordOilLifePercent: Double?

    mutating func tick(speedKmh: Double, rpm: Double, seconds: Double) {
        guard rpm > 300, seconds > 0, seconds < 30 else { return }
        let h = seconds / 3600
        odometerKm += max(0, speedKmh) * h
        totalEngineHours += h
        engineHoursSinceChange += h
        if speedKmh < 2 { totalIdleHours += h; idleHoursSinceChange += h }
    }

    mutating func recordChange(at date: Date = Date()) {
        lastChangeOdometerKm = odometerKm
        lastChangeDate = date
        engineHoursSinceChange = 0
        idleHoursSinceChange = 0
    }

    var kmSinceChange: Double? { lastChangeOdometerKm.map { max(0, odometerKm - $0) } }

    /// Remaining life 0…100 from our own counters (worst of distance, hours, time).
    func calculatedLifePercent(now: Date = Date()) -> Double? {
        guard let km = kmSinceChange else { return nil }
        let effectiveKm = km + idleHoursSinceChange * idleHourKmEquivalent
        var used = effectiveKm / intervalKm
        used = max(used, engineHoursSinceChange / intervalEngineHours)
        if let d = lastChangeDate { used = max(used, now.timeIntervalSince(d) / 86400 / intervalDays) }
        return max(0, min(100, (1 - used) * 100))
    }

    /// Prefer the truck's own figure when available.
    func lifePercent(now: Date = Date()) -> Double? { fordOilLifePercent ?? calculatedLifePercent(now: now) }

    func kmLeft(now: Date = Date()) -> Double? {
        guard let p = lifePercent(now: now) else { return nil }
        return p / 100 * intervalKm
    }

    func level(now: Date = Date()) -> AlertLevel {
        guard let p = lifePercent(now: now) else { return .ok }
        if p <= 5 { return .danger }
        if p <= 15 { return .warn }
        return .ok
    }
}

// MARK: - Scan report

struct ScanReport: Codable, Equatable, Identifiable {
    var id = UUID()
    var date = Date()
    var vin: String?
    var storedDTCs: [String] = []
    var pendingDTCs: [String] = []
    var permanentDTCs: [String] = []
    var milOn = false
    var batteryV: Double?
    var coolantC: Double?
    var oilC: Double?
    var railKPa: Double?
    var fuelPercent: Double?
    var tires = TireSet()
    var tireSource: String?
    var notes: [String] = []

    var allDTCs: [String] { Array(Set(storedDTCs + pendingDTCs + permanentDTCs)).sorted() }
    var healthy: Bool { allDTCs.isEmpty && !milOn }

    /// 0…100 score shown on the home ring.
    func score(limits: Limits) -> Int {
        var s = 100
        s -= min(60, allDTCs.count * 20)
        if milOn { s -= 15 }
        if limits.voltageLevel(batteryV, engineRunning: true) != .ok { s -= 5 }
        let tireLevels: [AlertLevel] = [limits.tireLevel(psi: tires.frontLeft, front: true), limits.tireLevel(psi: tires.frontRight, front: true),
                          limits.tireLevel(psi: tires.rearLeft, front: false), limits.tireLevel(psi: tires.rearRight, front: false)]
        s -= tireLevels.filter { $0 != .ok }.count * 3
        if limits.coolantLevel(coolantC) != .ok { s -= 10 }
        if limits.oilLevel(oilC) != .ok { s -= 10 }
        return max(0, s)
    }
}

// MARK: - DTC descriptions (common powertrain codes; unknown ones show the code only)

enum DTCText {
    static let known: [String: String] = [
        "P0087": "ضغط سكة الديزل منخفض",
        "P0088": "ضغط سكة الديزل مرتفع",
        "P0101": "حساس تدفق الهواء خارج المدى",
        "P0128": "حرارة المحرك ما توصل للطبيعي (ثرموستات)",
        "P0217": "المحرك سخن زيادة",
        "P0234": "ضغط التيربو زايد",
        "P0299": "ضغط التيربو ناقص",
        "P0300": "تقطيع عشوائي في الاحتراق",
        "P0401": "تدفق EGR غير كافي",
        "P0402": "تدفق EGR زايد",
        "P0471": "حساس ضغط العادم",
        "P0562": "جهد النظام منخفض",
        "P0563": "جهد النظام مرتفع",
        "P2002": "كفاءة فلتر الجزيئات DPF منخفضة",
        "P2463": "تراكم سخام في فلتر DPF",
        "U0100": "انقطاع الاتصال بكمبيوتر المحرك",
        "U0101": "انقطاع الاتصال بكمبيوتر القير",
    ]
    static func describe(_ code: String) -> String { known[code] ?? "كود عطل — ابحث عنه أو اعرضه على الوكالة" }
}

// MARK: - VIN

enum VIN {
    /// ISO 3779 / North-American check digit (position 9).
    static func isValid(_ vin: String) -> Bool {
        let v = vin.uppercased()
        guard v.count == 17, v.range(of: #"^[A-HJ-NPR-Z0-9]{17}$"#, options: .regularExpression) != nil else { return false }
        let map: [Character: Int] = ["A":1,"B":2,"C":3,"D":4,"E":5,"F":6,"G":7,"H":8,"J":1,"K":2,"L":3,"M":4,"N":5,
                                     "P":7,"R":9,"S":2,"T":3,"U":4,"V":5,"W":6,"X":7,"Y":8,"Z":9]
        let weights = [8,7,6,5,4,3,2,10,0,9,8,7,6,5,4,3,2]
        var sum = 0
        for (i, ch) in v.enumerated() {
            let n = ch.wholeNumberValue ?? map[ch] ?? 0
            sum += n * weights[i]
        }
        let r = sum % 11
        let check: Character = r == 10 ? "X" : Character(String(r))
        return Array(v)[8] == check
    }

    /// Model year from position 10 (2010–2039 cycle).
    static func year(_ vin: String) -> Int? {
        guard vin.count == 17 else { return nil }
        let c = Array(vin.uppercased())[9]
        let codes = Array("ABCDEFGHJKLMNPRSTVWXY123456789")
        guard let i = codes.firstIndex(of: c) else { return nil }
        return 2010 + i
    }
}
