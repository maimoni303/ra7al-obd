import CarPlay
import Combine
import UIKit

/// CarPlay uses Apple's driving-task templates only, so each gauge is drawn as an image (ring + symbol + value)
/// and placed on a grid button — the closest CarPlay allows to the phone design.
@MainActor
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var interface: CPInterfaceController?
    private var scene: CPTemplateApplicationScene?
    private var grid: CPGridTemplate?
    private var alertsList: CPListTemplate?
    private var scanList: CPListTemplate?
    private var fuelInfo: CPInformationTemplate?
    private var bag = Set<AnyCancellable>()
    private var lastRefresh = Date.distantPast

    private var link: OBDLink { .shared }
    private var store: VehicleStore { .shared }

    nonisolated func templateApplicationScene(_ s: CPTemplateApplicationScene, didConnect ic: CPInterfaceController) {
        Task { @MainActor in self.connect(scene: s, interface: ic) }
    }

    nonisolated func templateApplicationScene(_ s: CPTemplateApplicationScene, didDisconnectInterfaceController ic: CPInterfaceController) {
        Task { @MainActor in self.interface = nil; self.bag.removeAll(); AlertCenter.shared.onDanger = nil }
    }

    private func connect(scene s: CPTemplateApplicationScene, interface ic: CPInterfaceController) {
        scene = s
        interface = ic
        let g = CPGridTemplate(title: "RA7AL OBD", gridButtons: gridButtons())
        g.tabTitle = "اللوحة"
        g.tabImage = UIImage(systemName: "gauge.with.dots.needle.67percent") ?? UIImage(systemName: "gauge")
        grid = g

        let al = CPListTemplate(title: "التنبيهات", sections: [alertsSection()])
        al.tabTitle = "التنبيهات"
        al.tabImage = UIImage(systemName: "exclamationmark.triangle.fill")
        al.emptyViewTitleVariants = ["لا توجد تنبيهات"]
        alertsList = al

        let sl = CPListTemplate(title: "الفحص", sections: scanSections())
        sl.tabTitle = "الفحص"
        sl.tabImage = UIImage(systemName: CarIcon.scan.symbol)
        scanList = sl

        let fi = CPInformationTemplate(title: "الوقود", layout: .twoColumn, items: fuelItems(), actions: fuelActions())
        fi.tabTitle = "الوقود"
        fi.tabImage = UIImage(systemName: CarIcon.fuel.symbol)
        fuelInfo = fi

        ic.setRootTemplate(CPTabBarTemplate(templates: [g, al, sl, fi]), animated: false, completion: nil)

        link.$readings.receive(on: RunLoop.main).sink { [weak self] _ in self?.refreshSoon() }.store(in: &bag)
        AlertCenter.shared.$active.receive(on: RunLoop.main).sink { [weak self] _ in self?.refreshAlerts() }.store(in: &bag)
        store.$data.receive(on: RunLoop.main).sink { [weak self] _ in self?.refreshScan() }.store(in: &bag)
        AlertCenter.shared.onDanger = { [weak self] a in self?.presentDanger(a) }
    }

    // MARK: Refresh (CarPlay limits how often templates may change; ~1 update / 2 s is safe)

    private func refreshSoon() {
        guard Date().timeIntervalSince(lastRefresh) > 2 else { return }
        lastRefresh = Date()
        grid?.updateGridButtons(gridButtons())
        fuelInfo?.items = fuelItems()
    }

    private func refreshAlerts() { alertsList?.updateSections([alertsSection()]) }
    private func refreshScan() { scanList?.updateSections(scanSections()) }

    // MARK: Dashboard grid (max 8 buttons)

    private func gridButtons() -> [CPGridButton] {
        let r = link.readings
        let l = store.data.limits
        let dark = interface?.carTraitCollection.userInterfaceStyle != .light
        let range = store.data.fuel.rangeKm(levelPercent: r.fuelLevelPercent)
        let tireValues: [Double?] = [r.tires.frontLeft, r.tires.frontRight, r.tires.rearLeft, r.tires.rearRight]
        let minTire: Double? = tireValues.compactMap { $0 }.min()
        let tireLevels: [AlertLevel] = [l.tireLevel(psi: r.tires.frontLeft, front: true), l.tireLevel(psi: r.tires.frontRight, front: true),
                                        l.tireLevel(psi: r.tires.rearLeft, front: false), l.tireLevel(psi: r.tires.rearRight, front: false)]
        let tireLevel: AlertLevel = tireLevels.max() ?? .ok
        let scan = store.lastScan
        func frac(_ v: Double?, _ lo: Double, _ hi: Double) -> Double {
            guard let v else { return 0 }
            return (v - lo) / (hi - lo)
        }

        struct Spec { var icon: CarIcon; var value: String; var title: String; var fraction: Double; var level: AlertLevel?; var action: () -> Void }
        var specs: [Spec] = []
        let coolantValue: String = r.coolantC.map { "\(Int($0))°" } ?? "—"
        specs.append(Spec(icon: .coolant, value: coolantValue, title: "حرارة الماء",
                          fraction: frac(r.coolantC, 40, l.coolantDanger), level: l.coolantLevel(r.coolantC), action: {}))
        let oilValue: String = r.oilC.map { "\(Int($0))°" } ?? "—"
        specs.append(Spec(icon: .oil, value: oilValue, title: "حرارة الزيت",
                          fraction: frac(r.oilC, 40, l.oilDanger), level: l.oilLevel(r.oilC), action: {}))
        let rangeValue: String = range.map { "\(Int($0))كم" } ?? "—"
        let fuelTitle: String = r.fuelLevelPercent.map { String(format: "الديزل %.0f%%", $0) } ?? "الديزل"
        let fuelFrac: Double = (r.fuelLevelPercent ?? 0) / 100
        specs.append(Spec(icon: .fuel, value: rangeValue, title: fuelTitle, fraction: fuelFrac,
                          level: l.fuelLevel(percent: r.fuelLevelPercent, rangeKm: range), action: { [weak self] in self?.showFuelTab() }))
        specs.append(Spec(icon: .battery, value: fmt(r.batteryV, "%.1fV"), title: "البطارية", fraction: frac(r.batteryV, 11, 15),
                          level: l.voltageLevel(r.batteryV, engineRunning: r.engineRunning), action: {}))
        let tireValue: String = minTire.map { "\(Int($0))" } ?? "—"
        let tireFrac: Double = (minTire ?? 0) / max(1, l.tireRearPsi)
        let tireLvl: AlertLevel? = r.tires.hasAny ? tireLevel : nil
        specs.append(Spec(icon: .tires, value: tireValue, title: r.tires.hasAny ? "أقل كفر psi" : "الكفرات", fraction: tireFrac, level: tireLvl, action: {}))
        let railValue: String = r.railKPa.map { "\(Int($0 / 100))" } ?? "—"
        specs.append(Spec(icon: .rail, value: railValue, title: "سكة الديزل بار", fraction: frac(r.railKPa, 0, 180_000), level: nil, action: {}))
        var scanValue = "ابدأ"
        var scanLevel: AlertLevel?
        if link.scanning { scanValue = "…" } else if let scan {
            let v = ScanVerdict.evaluate(scan, data: store.data)
            scanValue = v.short
            scanLevel = v.drive.level
        }
        specs.append(Spec(icon: .scan, value: scanValue, title: "فحص شامل", fraction: 1, level: scanLevel, action: { [weak self] in self?.link.requestScan() }))
        specs.append(Spec(icon: .station, value: "ديزل", title: "أقرب محطة", fraction: 1, level: nil, action: { [weak self] in self?.openNearestStation() }))
        return specs.map { s in
            let img = GaugeImage.render(icon: s.icon, value: s.value, fraction: s.fraction, level: s.level, dark: dark)
            let action = s.action
            return CPGridButton(titleVariants: [s.title], image: img) { _ in action() }
        }
    }

    // MARK: Lists

    private func alertsSection() -> CPListSection {
        let items = AlertCenter.shared.active.map { a -> CPListItem in
            let i = CPListItem(text: a.title, detailText: a.message,
                               image: UIImage(systemName: a.level == .danger ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill"))
            return i
        }
        return CPListSection(items: items)
    }

    private func scanSections() -> [CPListSection] {
        var head: [CPListItem] = []
        let run = CPListItem(text: link.scanning ? "جاري الفحص…" : "فحص شامل الآن", detailText: link.scanProgress.isEmpty ? nil : link.scanProgress,
                             image: UIImage(systemName: CarIcon.scan.symbol))
        run.handler = { [weak self] _, done in self?.link.requestScan(); done() }
        head.append(run)
        guard let s = store.lastScan else { return [CPListSection(items: head)] }
        let v = ScanVerdict.evaluate(s, data: store.data)
        let verdict = CPListItem(text: v.headline,
                                 detailText: "القيادة: \(v.drive.title) · الاستعجال: \(v.urgency.title)" + (v.reason.map { " · " + $0 } ?? ""),
                                 image: UIImage(systemName: v.symbol)?.withTintColor(v.drive == .safe ? .systemGreen : (v.drive == .caution ? .systemYellow : .systemRed),
                                                                                      renderingMode: .alwaysOriginal))
        head.insert(verdict, at: 0)
        var rows: [CPListItem] = []
        for sec in v.sections where sec.status != .unavailable {
            rows.append(CPListItem(text: sec.title, detailText: sec.badge + (sec.codes.isEmpty ? "" : " — " + sec.codes.joined(separator: "، "))))
        }
        for c in s.allDTCs.prefix(6) {
            let i = DTCKnowledge.info(c)
            rows.append(CPListItem(text: c + " · " + i.title, detailText: "القيادة: \(i.drive.title) — " + i.action))
        }
        rows.append(CPListItem(text: "لمبة فحص المحرك", detailText: s.milOn ? "مضاءة" : "مطفأة"))
        rows.append(CPListItem(text: "البطارية", detailText: fmt(s.batteryV, "%.1f V")))
        if let k = store.data.oil.kmLeft() { rows.append(CPListItem(text: "عمر الزيت", detailText: "باقي ~\(Int(k)) كم")) }
        let f = DateFormatter(); f.locale = Locale(identifier: "ar"); f.dateFormat = "EEEE h:mm a"
        return [CPListSection(items: head), CPListSection(items: rows, header: "آخر فحص · " + f.string(from: s.date), sectionIndexTitle: nil)]
    }

    private func fuelItems() -> [CPInformationItem] {
        let r = link.readings
        let fuel = store.data.fuel
        let range = fuel.rangeKm(levelPercent: r.fuelLevelPercent)
        return [
            CPInformationItem(title: "المسافة المتبقية", detail: range.map { "\(Int($0)) كم" } ?? "—"),
            CPInformationItem(title: "في التانكي", detail: r.fuelLevelPercent.map { String(format: "%.0f%% · %.0f لتر", $0, fuel.litersLeft(levelPercent: $0)) } ?? "—"),
            CPInformationItem(title: "متوسط استهلاكك", detail: String(format: "%.1f L/100km", fuel.avgLper100)),
            CPInformationItem(title: "الاستهلاك الآن", detail: fmt(r.fuelRateLh, "%.1f L/h")),
        ]
    }

    private func fuelActions() -> [CPTextButton] {
        [CPTextButton(title: "أقرب محطة ديزل", textStyle: .confirm) { [weak self] _ in self?.openNearestStation() }]
    }

    private func showFuelTab() {
        guard let tabs = interface?.rootTemplate as? CPTabBarTemplate, let fi = fuelInfo else { return }
        tabs.select(fi)
    }

    /// Hands navigation to Google Maps on the car screen (CarPlay apps may not draw maps themselves).
    private func openNearestStation() {
        let finder = StationFinder.shared
        finder.start()
        Task {
            if finder.stations.isEmpty { await finder.search() }
            let url: URL
            if let s = finder.stations.first {
                url = StationFinder.directionsURL(to: s.placemark.coordinate)
            } else {
                url = URL(string: "comgooglemaps://?q=diesel+station&directionsmode=driving")!
            }
            scene?.open(url, options: nil, completionHandler: nil)
        }
    }

    private func presentDanger(_ a: ActiveAlert) {
        guard let ic = interface else { return }
        let alert = CPAlertTemplate(titleVariants: [a.title + " — " + a.message, a.title], actions: [
            CPAlertAction(title: "تم", style: .cancel) { _ in ic.dismissTemplate(animated: true, completion: nil) }
        ])
        if ic.presentedTemplate != nil { ic.dismissTemplate(animated: false, completion: nil) }
        ic.presentTemplate(alert, animated: true, completion: nil)
    }
}

/// Draws one gauge button image (used by CarPlay; also testable).
enum GaugeImage {
    static func render(icon: CarIcon, value: String, fraction: Double, level: AlertLevel?, dark: Bool) -> UIImage {
        let size = CGSize(width: 90, height: 90)
        let accent = UIColor(red: 0.22, green: 0.74, blue: 0.97, alpha: 1)
        let color: UIColor
        switch level {
        case .some(.danger): color = UIColor(red: 0.96, green: 0.25, blue: 0.37, alpha: 1)
        case .some(.warn): color = UIColor(red: 0.98, green: 0.75, blue: 0.14, alpha: 1)
        case .some(.ok): color = UIColor(red: 0.29, green: 0.87, blue: 0.50, alpha: 1)
        case .none: color = accent
        }
        let text = dark ? UIColor.white : UIColor.black
        let track = dark ? UIColor(white: 0.2, alpha: 1) : UIColor(white: 0.85, alpha: 1)
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 3
        return UIGraphicsImageRenderer(size: size, format: fmt).image { ctx in
            let c = ctx.cgContext
            let center = CGPoint(x: 45, y: 45)
            c.setLineWidth(6)
            c.setLineCap(.round)
            c.setStrokeColor(track.cgColor)
            c.addArc(center: center, radius: 40, startAngle: 0, endAngle: .pi * 2, clockwise: false)
            c.strokePath()
            let f = max(0.001, min(1, fraction))
            c.setStrokeColor(color.cgColor)
            c.addArc(center: center, radius: 40, startAngle: -.pi / 2, endAngle: -.pi / 2 + .pi * 2 * f, clockwise: false)
            c.strokePath()
            let cfg = UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold)
            if let sym = UIImage(systemName: icon.symbol, withConfiguration: cfg)?.withTintColor(color, renderingMode: .alwaysOriginal) {
                let s = sym.size
                sym.draw(in: CGRect(x: 45 - s.width / 2, y: 30 - s.height / 2, width: s.width, height: s.height))
            }
            let para = NSMutableParagraphStyle(); para.alignment = .center
            let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 17, weight: .bold), .foregroundColor: text, .paragraphStyle: para]
            (value as NSString).draw(in: CGRect(x: 6, y: 46, width: 78, height: 24), withAttributes: attrs)
        }
    }
}
