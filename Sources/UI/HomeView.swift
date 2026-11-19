import SwiftUI

struct HomeView: View {
    let p: Palette
    var goTo: (MainTab) -> Void
    @ObservedObject var store = VehicleStore.shared
    @ObservedObject var link = OBDLink.shared
    @ObservedObject var alerts = AlertCenter.shared
    @State private var showScan = false

    private var r: Readings { link.readings }
    private var limits: Limits { store.data.limits }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                hero
                ForEach(alerts.active) { a in alertBanner(a) }
                gaugeGrid
                if link.scanning {
                    HStack { ProgressView(); Text("جاري الفحص: \(link.scanProgress)").foregroundStyle(p.sub) }
                        .frame(maxWidth: .infinity, minHeight: 54).card(p)
                } else {
                    PrimaryButton(p: p, title: "فحص شامل الآن", icon: CarIcon.scan.symbol) { link.requestScan() }
                }
                if !link.scanProgress.isEmpty && !link.scanning {
                    Text(link.scanProgress).font(.footnote).foregroundStyle(p.sub)
                }
            }
            .padding(.bottom, 8)
        }
        .scrollIndicators(.hidden)
        .navigationDestination(isPresented: $showScan) { ScanResultsView(p: p) }
    }

    private var gaugeGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            coolantGauge; oilGauge; fuelGauge; batteryGauge; railGauge; tireGauge
        }
    }

    private var coolantGauge: some View {
        let v: String = r.coolantC.map { "\(Int($0))°C" } ?? "—"
        return IconGauge(p: p, icon: .coolant, value: v, caption: "حرارة الماء",
                         fraction: frac(r.coolantC, 40, limits.coolantDanger), color: p.color(limits.coolantLevel(r.coolantC)))
    }
    private var oilGauge: some View {
        let v: String = r.oilC.map { "\(Int($0))°C" } ?? "—"
        return IconGauge(p: p, icon: .oil, value: v, caption: "حرارة الزيت",
                         fraction: frac(r.oilC, 40, limits.oilDanger), color: p.color(limits.oilLevel(r.oilC)))
    }
    private var fuelGauge: some View {
        let v: String = range.map { "\(Int($0)) كم" } ?? "—"
        let c: String = r.fuelLevelPercent.map { String(format: "الديزل %.0f%%", $0) } ?? "الديزل"
        let f: Double = (r.fuelLevelPercent ?? 0) / 100
        return IconGauge(p: p, icon: .fuel, value: v, caption: c, fraction: f, color: fuelColor)
    }
    private var batteryGauge: some View {
        let c: String = r.engineRunning ? "الدينمو يشحن" : "البطارية"
        let col: Color = p.color(limits.voltageLevel(r.batteryV, engineRunning: r.engineRunning))
        return IconGauge(p: p, icon: .battery, value: fmt(r.batteryV, "%.1f V"), caption: c, fraction: frac(r.batteryV, 11, 15), color: col)
    }
    private var railGauge: some View {
        let v: String = r.railKPa.map { "\(Int($0 / 100)) بار" } ?? "—"
        return IconGauge(p: p, icon: .rail, value: v, caption: "ضغط سكة الديزل", fraction: frac(r.railKPa, 0, 180_000), color: p.accent)
    }
    private var tireGauge: some View {
        let v: String = minTire.map { "\(Int($0)) psi" } ?? "—"
        let f: Double = (minTire ?? 0) / max(1, limits.tireRearPsi)
        return IconGauge(p: p, icon: .tires, value: v, caption: "أقل كفر", fraction: f, color: tireColor)
    }

    private var range: Double? { store.data.fuel.rangeKm(levelPercent: r.fuelLevelPercent) }
    private var fuelColor: Color {
        let l = limits.fuelLevel(percent: r.fuelLevelPercent, rangeKm: range)
        return l == .ok ? p.accent : p.color(l)
    }
    private var minTire: Double? {
        let all: [Double?] = [r.tires.frontLeft, r.tires.frontRight, r.tires.rearLeft, r.tires.rearRight]
        return all.compactMap { $0 }.min()
    }
    private var tireColor: Color {
        let t = r.tires
        let all: [AlertLevel] = [limits.tireLevel(psi: t.frontLeft, front: true), limits.tireLevel(psi: t.frontRight, front: true),
                                 limits.tireLevel(psi: t.rearLeft, front: false), limits.tireLevel(psi: t.rearRight, front: false)]
        let l: AlertLevel = all.max() ?? .ok
        return t.hasAny ? p.color(l) : p.sub
    }

    private func frac(_ v: Double?, _ lo: Double, _ hi: Double) -> Double {
        guard let v, hi > lo else { return 0 }
        return (v - lo) / (hi - lo)
    }

    private var hero: some View {
        let scan = store.lastScan
        let score = scan?.score(limits: limits)
        return Button { showScan = true } label: {
            HStack(spacing: 16) {
                ZStack {
                    Ring(fraction: Double(score ?? 0) / 100, color: p.heroAccent, track: p.heroTrack, width: 9)
                    Text(score.map { "\($0)%" } ?? "—").font(.system(size: 22, weight: .bold))
                }
                .frame(width: 88, height: 88)
                VStack(alignment: .leading, spacing: 4) {
                    Text("صحة السيارة").font(.system(size: 13)).opacity(0.8)
                    Text(heroTitle(scan)).font(.system(size: 20, weight: .bold))
                    Text(heroSub(scan)).font(.system(size: 13)).opacity(0.8)
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .foregroundStyle(p.heroText)
            .background(p.hero, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("صحة السيارة \(score.map { "\($0)%" } ?? "")")
        .accessibilityHint("يعرض تفاصيل آخر فحص")
        .accessibilityIdentifier("health")
    }

    private func heroTitle(_ s: ScanReport?) -> String {
        guard let s else { return "ما تم فحص بعد" }
        return ScanVerdict.evaluate(s, data: store.data).headline
    }

    private func heroSub(_ s: ScanReport?) -> String {
        guard let s else { return "شغّل السيارة واضغط فحص شامل" }
        let f = DateFormatter(); f.locale = Locale(identifier: "ar"); f.dateFormat = "EEEE h:mm a"
        return (s.allDTCs.isEmpty ? "لا أكواد أعطال · " : "\(s.allDTCs.count) كود · ") + "فحص " + f.string(from: s.date)
    }

    private func alertBanner(_ a: ActiveAlert) -> some View {
        let c = p.color(a.level)
        let icon: CarIcon = {
            switch a.kind {
            case .coolant: return .coolant
            case .oil, .oilLife: return .oil
            case .fuel: return .fuel
            case .tires: return .tires
            case .voltage: return .battery
            case .dtc: return .engine
            }
        }()
        return Button {
            switch a.kind {
            case .fuel: goTo(.fuel)
            case .tires, .oil, .oilLife: goTo(.oil)
            default: showScan = true
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon.symbol).font(.system(size: 20, weight: .semibold))
                VStack(alignment: .leading, spacing: 2) {
                    Text(a.title).font(.system(size: 14, weight: .bold))
                    if !a.message.isEmpty { Text(a.message).font(.system(size: 12)).lineLimit(2) }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.left").font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(c)
            .padding(12)
            .background(c.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(c.opacity(0.35), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}
