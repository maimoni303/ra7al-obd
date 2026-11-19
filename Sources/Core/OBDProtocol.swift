import Foundation

/// Pure parsing for the NONDA/ZUS "OBDBLE" adapter (ELM327 v1.5 dialect) — no CoreBluetooth, unit-tested.
enum OBDProtocol {
    static let serviceUUID = "FFE0"
    static let characteristicUUID = "FFE1"

    static let initCommands = ["ATZ", "ATE0", "ATH0"]

    /// Read-only Mode 01 PIDs polled while driving. Each entry: pid, seconds between reads.
    static let fastPIDs: [UInt8] = [0x5E, 0x5C, 0x23, 0x0B]
    static let slowPIDs: [UInt8] = [0x0F, 0x33, 0x46, 0x42, 0x01, 0x10]
    /// Used only when the adapter's own 1 Hz stream is not running.
    static let streamFallbackPIDs: [UInt8] = [0x0C, 0x0D, 0x05, 0x04, 0x2F]

    // MARK: Stream ("BD$V14.5;R00600;S000;…;@2")

    struct StreamFrame: Equatable {
        var volts: Double?
        var rpm: Double?
        var speedKmh: Double?
        var loadPercent: Double?
        var coolantC: Double?
        var fuelLevelPercent: Double?
        var tripFuelL: Double?
        var tripSeconds: Double?
        var accel: (x: Double, y: Double, z: Double)?

        static func == (a: StreamFrame, b: StreamFrame) -> Bool {
            a.volts == b.volts && a.rpm == b.rpm && a.speedKmh == b.speedKmh && a.loadPercent == b.loadPercent
                && a.coolantC == b.coolantC && a.fuelLevelPercent == b.fuelLevelPercent
        }
    }

    /// Splits text into complete lines; returns (lines, unfinished remainder).
    static func takeLines(_ buffer: String) -> ([String], String) {
        let unified = buffer.replacingOccurrences(of: "\r", with: "\n")
        var parts = unified.components(separatedBy: "\n")
        let rest = parts.removeLast()
        return (parts.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }, rest)
    }

    static let streamPattern = #"BD\$[^@]*@\d"#

    /// Pulls stream frames out of a line and returns the line with them removed (what's left may be a command reply).
    static func extractStream(from line: String) -> (frames: [StreamFrame], rest: String) {
        var frames: [StreamFrame] = []
        var rest = line
        while let r = rest.range(of: streamPattern, options: .regularExpression) {
            if let f = parseStream(String(rest[r])) { frames.append(f) }
            rest.removeSubrange(r)
        }
        return (frames, rest)
    }

    static func parseStream(_ text: String) -> StreamFrame? {
        guard let start = text.range(of: "BD$") else { return nil }
        var f = StreamFrame()
        var gx: Double?, gy: Double?, gz: Double?
        for tok in text[start.upperBound...].split(separator: ";") {
            let t = String(tok)
            func num(_ prefix: Int) -> Double? { Double(t.dropFirst(prefix)) }
            if t.hasPrefix("XH") { continue }
            if t.hasPrefix("GX") { gx = num(2); continue }
            if t.hasPrefix("GY") { gy = num(2); continue }
            if t.hasPrefix("GZ") { gz = num(2); continue }
            guard let k = t.first else { continue }
            switch k {
            case "V": f.volts = num(1)
            case "R": f.rpm = num(1)
            case "S": f.speedKmh = num(1)
            case "O": f.loadPercent = num(1)
            case "C": f.coolantC = num(1)
            case "L": f.fuelLevelPercent = num(1)
            case "F": f.tripFuelL = num(1)
            case "T": f.tripSeconds = num(1)
            default: break
            }
        }
        if let gx, let gy, let gz { f.accel = (gx / 64, gy / 64, gz / 64) }
        guard f.rpm != nil || f.volts != nil else { return nil }
        return f
    }

    // MARK: Command replies

    /// Applies one Mode 01 reply to the readings. Returns true when something was understood.
    @discardableResult
    static func apply(pid: UInt8, reply: String, to r: inout Readings) -> Bool {
        guard let d = ProbeLogic.mode01(pid, in: reply) else { return false }
        func a() -> Double { Double(d[0]) }
        func ab() -> Double { Double(Int(d[0]) * 256 + Int(d[1])) }
        switch pid {
        case 0x01 where d.count >= 1: r.milOn = d[0] & 0x80 != 0; r.dtcCount = Int(d[0] & 0x7F)
        case 0x04 where d.count >= 1: r.loadPercent = a() * 100 / 255
        case 0x05 where d.count >= 1: r.coolantC = a() - 40
        case 0x0B where d.count >= 1: r.mapKPa = a()
        case 0x0C where d.count >= 2: r.rpm = ab() / 4
        case 0x0D where d.count >= 1: r.speedKmh = a()
        case 0x0F where d.count >= 1: r.intakeC = a() - 40
        case 0x10 where d.count >= 2: r.mafGs = ab() / 100
        case 0x1F where d.count >= 2: r.runTimeS = ab()
        case 0x23 where d.count >= 2: r.railKPa = ab() * 10
        case 0x2F where d.count >= 1: r.fuelLevelPercent = a() * 100 / 255
        case 0x33 where d.count >= 1: r.baroKPa = a()
        case 0x42 where d.count >= 2: r.ecuV = ab() / 1000
        case 0x46 where d.count >= 1: r.ambientC = a() - 40
        case 0x5C where d.count >= 1: r.oilC = a() - 40
        case 0x5E where d.count >= 2: r.fuelRateLh = ab() / 20
        default: return false
        }
        return true
    }

    static func batteryVolts(fromATRV reply: String) -> Double? {
        guard let r = reply.range(of: #"\d{1,2}\.\d"#, options: .regularExpression) else { return nil }
        return Double(reply[r])
    }

    /// A VIN only counts when its check digit is right (long replies can lose BLE packets).
    static func validVIN(fromReply reply: String) -> String? {
        guard let v = ProbeLogic.vin(fromReply: reply), VIN.isValid(v) else { return nil }
        return v
    }

    // MARK: Ford body-module tyre pressures (experimental, read-only service 0x22)

    /// Ford BCM physical request header and the four TPMS DIDs commonly used on 2017+ Super Duty.
    static let fordBCMHeader = "726"
    static let fordTPMSDIDs: [(did: String, position: String)] = [("2813", "FL"), ("2814", "FR"), ("2815", "RR"), ("2816", "RL")]

    /// Raw 16-bit value of a `62 DID XX XX` reply, if present.
    static func fordDIDRaw(did: String, reply: String) -> Int? {
        guard did.count == 4, let hi = UInt8(did.prefix(2), radix: 16), let lo = UInt8(did.suffix(2), radix: 16) else { return nil }
        for l in ProbeLogic.dataLines(reply) {
            guard let k = (0..<max(0, l.count - 2)).first(where: { l[$0] == 0x62 && l[$0 + 1] == hi && l[$0 + 2] == lo }),
                  l.count >= k + 5 else { continue }
            return Int(l[k + 3]) * 256 + Int(l[k + 4])
        }
        return nil
    }

    /// Ford modules differ in how they scale TPMS values, so the app learns the scale once from the dash
    /// readout (see `TPMSCalibration`) and only shows pressures after that.
    static func psi(raw: Int, scale: Double, offset: Double) -> Double { Double(raw) * scale + offset }
}

/// Learned conversion for this truck's TPMS raw values (set once from the dash readout).
struct TPMSCalibration: Codable, Equatable {
    var scale: Double = 0.05
    var offset: Double = 0
    var confirmed = false

    /// Picks the common Ford encodings and keeps the one that matches the readings on the cluster.
    static func fit(raw: [Int], dash: [Double]) -> TPMSCalibration? {
        guard raw.count == dash.count, !raw.isEmpty else { return nil }
        let candidates: [(Double, Double)] = [(0.05, 0), (0.05, -14.7), (1.0 / 6.895, 0), (0.1, 0), (1.0 / 6.895 / 10, 0), (0.0145, 0)]
        var best: (TPMSCalibration, Double)?
        for (s, o) in candidates {
            var total = 0.0
            for i in 0..<raw.count {
                let predicted: Double = Double(raw[i]) * s + o
                total += abs(predicted - dash[i])
            }
            let err: Double = total / Double(raw.count)
            if best == nil || err < best!.1 { best = (TPMSCalibration(scale: s, offset: o, confirmed: err < 2), err) }
        }
        return best?.0
    }
}
