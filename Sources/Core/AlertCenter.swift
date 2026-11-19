import Foundation
import AVFoundation
import UserNotifications

struct ActiveAlert: Identifiable, Equatable {
    enum Kind: String { case coolant, oil, fuel, tires, voltage, dtc, oilLife }
    var kind: Kind
    var level: AlertLevel
    var title: String
    var message: String
    var date = Date()
    var id: String { kind.rawValue }
}

/// Turns readings into alerts: phone notification, spoken Arabic warning, and a CarPlay alert for danger.
@MainActor
final class AlertCenter: ObservableObject {
    static let shared = AlertCenter()

    @Published private(set) var active: [ActiveAlert] = []
    /// CarPlay listens to this to show its own alert card.
    var onDanger: ((ActiveAlert) -> Void)?

    private var lastAnnounced: [ActiveAlert.Kind: (AlertLevel, Date)] = [:]
    private let speech = AVSpeechSynthesizer()

    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    /// Pure evaluation, exposed for tests.
    static func alerts(for r: Readings, data: AppData) -> [ActiveAlert] {
        let l = data.limits
        var out: [ActiveAlert] = []
        let ct = l.coolantLevel(r.coolantC)
        if ct != .ok, let c = r.coolantC {
            out.append(ActiveAlert(kind: .coolant, level: ct, title: "حرارة الماء مرتفعة",
                                   message: "\(Int(c))°C. " + (ct == .danger ? "وقّف في مكان آمن وطفّ المحرك بعد ما يبرد شوي." : "خفف السرعة وطفّ المكيف.")))
        }
        let ot = l.oilLevel(r.oilC)
        if ot != .ok, let c = r.oilC {
            out.append(ActiveAlert(kind: .oil, level: ot, title: "حرارة الزيت مرتفعة",
                                   message: "\(Int(c))°C. " + (ot == .danger ? "وقّف وخلّ المحرك يرتاح." : "خفف الحمل والسرعة.")))
        }
        let range = data.fuel.rangeKm(levelPercent: r.fuelLevelPercent)
        let ft = l.fuelLevel(percent: r.fuelLevelPercent, rangeKm: range)
        if ft != .ok {
            let km = range.map { "تقدر تمشي تقريبًا \(Int($0)) كم." } ?? ""
            out.append(ActiveAlert(kind: .fuel, level: ft, title: ft == .danger ? "الديزل قارب يخلص" : "الديزل منخفض", message: km))
        }
        let t = r.tires
        let tl = [l.tireLevel(psi: t.frontLeft, front: true), l.tireLevel(psi: t.frontRight, front: true),
                  l.tireLevel(psi: t.rearLeft, front: false), l.tireLevel(psi: t.rearRight, front: false)].max() ?? .ok
        if tl != .ok {
            out.append(ActiveAlert(kind: .tires, level: tl, title: "ضغط الكفرات منخفض",
                                   message: "المعتمد \(Int(l.tireFrontPsi)) قدام و\(Int(l.tireRearPsi)) ورا."))
        }
        let vt = l.voltageLevel(r.batteryV, engineRunning: r.engineRunning)
        if vt != .ok, let v = r.batteryV {
            out.append(ActiveAlert(kind: .voltage, level: vt, title: r.engineRunning ? "الدينمو ما يشحن كفاية" : "البطارية ضعيفة",
                                   message: String(format: "%.1f فولت.", v)))
        }
        if r.milOn == true {
            out.append(ActiveAlert(kind: .dtc, level: .warn, title: "لمبة فحص المحرك مضاءة", message: "سوّ فحص شامل لمعرفة الكود."))
        }
        let ol = data.oil.level()
        if ol != .ok {
            let km = data.oil.kmLeft().map { "باقي تقريبًا \(Int($0)) كم." } ?? ""
            out.append(ActiveAlert(kind: .oilLife, level: ol, title: "موعد تغيير الزيت قرب", message: km))
        }
        return out.sorted { $0.level > $1.level }
    }

    func evaluate(readings: Readings, store: VehicleStore) {
        let now = AlertCenter.alerts(for: readings, data: store.data)
        active = now
        for a in now {
            let prev = lastAnnounced[a.kind]
            let escalated = prev == nil || a.level > prev!.0
            let stale = prev.map { Date().timeIntervalSince($0.1) > 15 * 60 } ?? true
            guard escalated || stale else { continue }
            lastAnnounced[a.kind] = (a.level, Date())
            announce(a, speak: store.data.speakAlerts)
        }
        for k in Array(lastAnnounced.keys) where !now.contains(where: { $0.kind == k }) { lastAnnounced[k] = nil }
    }

    func scanFinished(_ r: ScanReport, store: VehicleStore) {
        let body: String
        if r.healthy {
            body = "السيارة سليمة. لا توجد أكواد أعطال."
        } else {
            body = "وجدنا \(r.allDTCs.count) كود: " + r.allDTCs.joined(separator: "، ")
        }
        notify(title: "نتيجة الفحص التلقائي", body: body, id: "scan")
    }

    func refuelDetected(_ r: FuelModel.Refuel) {
        notify(title: "تعبئة ديزل", body: String(format: "انضاف تقريبًا %.0f لتر.", r.liters), id: "refuel")
    }

    private func announce(_ a: ActiveAlert, speak: Bool) {
        if OBDLink.isUITesting { return }
        notify(title: a.title, body: a.message, id: a.id)
        if a.level == .danger { onDanger?(a) }
        if speak { say(a.title + ". " + a.message) }
    }

    private func notify(title: String, body: String, id: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        c.interruptionLevel = .timeSensitive
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id + "-" + UUID().uuidString, content: c, trigger: nil))
    }

    private func say(_ text: String) {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .voicePrompt, options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(language: "ar-SA")
        u.rate = 0.48
        speech.speak(u)
    }
}
