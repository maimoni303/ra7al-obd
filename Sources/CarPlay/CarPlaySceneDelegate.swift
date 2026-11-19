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
        let minTire = [r.tires.frontLeft, r.tires.frontRight, r.tires.rearLeft, r.tires.rearRight].compactMap { $0 }.min()
        let tireLevel = [l.tireLevel(psi: r.tires.frontLeft, front: true), l.tireLevel(psi: r.tires.frontRight, front: true),
                         l.tireLevel(psi: r.tires.rearLeft, front: false), l.tireLevel(psi: r.tires.rearRight, front: false)].max() ?? .ok
        let scan = store.lastScan
        func frac(_ v: Double?, _ lo: Double, _ hi: Double) -> Double { v.map { ($0 - lo) / (hi - lo) } ?? 0 }

        let specs: [(CarIcon, String, String, Double, AlertLevel?, () -> Void)] = [
            (.coolant, r.coolantC.map { "\(Int($0))°" } ?? "—", "حرارة الماء", frac(r.coolantC, 40, l.coolantDanger), l.coolantLevel(r.coolantC), {}),
            (.oil, r.oilC.map { "\(Int($0))°" } ?? "—", "حرارة الزيت", frac(r.oilC, 40, l.oilDanger), l.oilLevel(r.oilC), {}),
            (.fuel, range.map { "\(Int($0))كم" } ?? "—", r.fuelLevelPercent.map { String(format: "الديزل %.0f%%", $0) } ?? "الديزل",
             (r.fuelLevelPercent ?? 0) / 100, l.fuelLevel(percent: r.fuelLevelPercent, rangeKm: range), { [weak self] in self?.showFuelTab() }),
            (.battery, fmt(r.batteryV, "%.1fV"), "البطارية", frac(r.batteryV, 11, 15), l.voltageLevel(r.batteryV, engineRunning: r.engineRunning), {}),
            (.tires, minTire.map { "\(Int($0))" } ?? "—", r.tires.hasAny ? "أقل كفر psi" : "الكفرات",
             (minTire ?? 0) / max(1, l.tireRearPsi), r.tires.hasAny ? tireLevel : nil, {}),
            (.rail, r.railKPa.map { "\(Int($0 / 100))" } ?? "—", "سكة الديزل بار", frac(r.railKPa, 0, 180_000), nil, {}),
            (.scan, link.scanning ? "…" : (scan.map { $0.healthy ? "سليم" : "\($0.allDTCs.count) كود" } ?? "ابدأ"), "فحص شامل",
             1, scan.map { $0.healthy ? AlertLevel.ok : .warn }, { [weak self] in self?.link.requestScan() }),
            (.station, "ديزل", "أقرب محطة", 1, nil, { [weak self] in self?.openNearestStation() }),
        ]
        return specs.map { s in
            let img = GaugeImage.render(icon: s.0, value: s.1, fraction: s.3, level: s.4, dark: dark)
            return CPGridButton(titleVariants: [s.2], image: img) { _ in s.5() }
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
        var rows: [CPListItem] = []
        rows.append(CPListItem(text: "أكواد الأعطال", detailText: s.allDTCs.isEmpty ? "لا يوجد" : s.allDTCs.joined(separator: "، ")))
        for c in s.allDTCs.prefix(6) { rows.append(CPListItem(text: c, detailText: DTCText.describe(c))) }
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
            CPInformationItem(title: "متوسط استهلاكك", detail: String(format: "%.1f ل/100 كم", fuel.avgLper100)),
            CPInformationItem(title: "الاستهلاك الآن", detail: fmt(r.fuelRateLh, "%.1f لتر/ساعة")),
        ]
    }

    private func fuelActions() -> [CPTextButton] {
        [CPTextButton(title: "أقرب محطة ديزل", textStyle: .confirm) { [weak self] _ in self?.openNearestStation() }]
    }

    private func showFuelTab() {
        guard let tabs = interface?.rootTemplate as? CPTabBarTemplate, let fi = fuelInfo else { return }
        tabs.selectTemplate(fi)
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
