import SwiftUI
import UIKit

private func symbol(_ options: String...) -> String { options.first { UIImage(systemName: $0) != nil } ?? "circle" }

private func statusColor(_ s: SectionStatus, _ p: Palette) -> Color {
    switch s {
    case .ok: return p.ok
    case .warn: return p.warn
    case .danger: return p.danger
    case .unavailable: return p.sub
    }
}

private func sectionIcon(_ k: ScanSection.Kind) -> String {
    switch k {
    case .engine: return CarIcon.engine.symbol
    case .transmission: return symbol("gearshape.2.fill", "gearshape.fill")
    case .abs: return CarIcon.brake.symbol
    case .airbag: return symbol("figure.seated.seatbelt", "person.fill")
    case .body: return symbol("lightbulb.fill", "lightbulb")
    case .tires: return CarIcon.tires.symbol
    case .battery: return CarIcon.battery.symbol
    case .maintenance: return CarIcon.oil.symbol
    case .cluster: return symbol("gauge.with.dots.needle.67percent", "gauge")
    }
}

/// Chip row: drive / urgency / confidence.
struct VerdictChips: View {
    let p: Palette
    var drive: DriveAdvice
    var urgency: Urgency
    var confidence: Confidence?

    var body: some View {
        HStack(spacing: 8) {
            chip(drive.title, "القيادة", p.color(drive.level))
            chip(urgency.title, "الاستعجال", urgency >= .now ? p.danger : (urgency >= .soon ? p.warn : p.ok))
            if let confidence { chip(confidence.title, "الثقة", p.accent) }
        }
    }

    private func chip(_ value: String, _ label: String, _ c: Color) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(size: 14, weight: .bold)).foregroundStyle(c).lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.system(size: 11)).foregroundStyle(p.sub)
        }
        .frame(maxWidth: .infinity, minHeight: 50)
        .background(p.bg.opacity(0.55), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Full-scan results

struct ScanResultsView: View {
    let p: Palette
    @ObservedObject var store = VehicleStore.shared
    @ObservedObject var link = OBDLink.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if let s = store.lastScan {
                    let v = ScanVerdict.evaluate(s, data: store.data)
                    hero(v, s)
                    sectionsCard(v)
                    if !s.allDTCs.isEmpty { codesCard(s) }
                    if !s.notes.isEmpty { notesCard(s) }
                } else {
                    Text("ما فيه فحص محفوظ بعد. شغّل السيارة واضغط إعادة الفحص.")
                        .foregroundStyle(p.sub).frame(maxWidth: .infinity, minHeight: 80).card(p)
                }
                if link.scanning {
                    HStack { ProgressView(); Text("جاري الفحص: \(link.scanProgress)").foregroundStyle(p.sub) }
                        .frame(maxWidth: .infinity, minHeight: 54).card(p)
                } else {
                    PrimaryButton(p: p, title: "إعادة الفحص", icon: CarIcon.scan.symbol) { link.requestScan() }
                        .accessibilityIdentifier("rescan")
                }
                HStack(spacing: 10) {
                    NavigationLink { VehicleInfoView(p: p) } label: { linkLabel("بيانات السيارة", "car.fill") }
                        .buttonStyle(.plain).accessibilityIdentifier("vehicle-info")
                    NavigationLink { DTCLibraryView(p: p) } label: { linkLabel("دليل الأكواد", "book.fill") }
                        .buttonStyle(.plain).accessibilityIdentifier("dtc-library")
                }
                if let s = store.lastScan {
                    ShareLink(item: reportText(s)) {
                        Label("مشاركة التقرير", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .foregroundStyle(p.accent)
                }
                if store.data.scans.count > 1 { historyCard }
            }
            .padding(16)
        }
        .scrollIndicators(.hidden)
        .background(p.bg.ignoresSafeArea())
        .navigationTitle("نتيجة الفحص الشامل")
        .navigationBarTitleDisplayMode(.inline)
        .arabicBackButton()
    }

    private func linkLabel(_ t: String, _ icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
            Text(t).font(.system(size: 15, weight: .semibold))
        }
        .frame(maxWidth: .infinity, minHeight: 48)
        .foregroundStyle(p.text)
        .card(p, radius: 14)
    }

    private func hero(_ v: ScanVerdict, _ s: ScanReport) -> some View {
        let c = p.color(v.drive.level)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: v.symbol).font(.system(size: 40, weight: .bold)).foregroundStyle(c)
                VStack(alignment: .leading, spacing: 3) {
                    Text(v.headline).font(.system(size: 22, weight: .heavy)).foregroundStyle(c)
                    Text("الفحص \(arDate(s.date)) • \(v.sections.filter { $0.status != .unavailable }.count) أنظمة")
                        .font(.system(size: 12)).foregroundStyle(p.heroText.opacity(0.75))
                    if let r = v.reason { Text(r).font(.system(size: 12, weight: .semibold)).foregroundStyle(p.heroText) }
                }
                Spacer(minLength: 0)
            }
            VerdictChips(p: p, drive: v.drive, urgency: v.urgency, confidence: v.confidence)
        }
        .padding(16)
        .background(p.hero, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func sectionsCard(_ v: ScanVerdict) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(v.sections.enumerated()), id: \.element.id) { i, sec in
                if i > 0 { Divider().overlay(p.border) }
                let c = statusColor(sec.status, p)
                HStack(spacing: 10) {
                    Image(systemName: sectionIcon(sec.kind)).font(.system(size: 16, weight: .semibold)).foregroundStyle(c)
                        .frame(width: 34, height: 34).background(p.bg.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(sec.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(p.text)
                        Text(sec.detail).font(.system(size: 11.5)).foregroundStyle(p.sub).lineLimit(2)
                    }
                    Spacer(minLength: 4)
                    Text(sec.badge).font(.system(size: 11.5, weight: .bold)).foregroundStyle(c)
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(c.opacity(0.15), in: Capsule())
                }
                .padding(.vertical, 9)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 4)
        .card(p)
    }

    private func codesCard(_ s: ScanReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("أكواد الأعطال").font(.system(size: 13, weight: .semibold)).foregroundStyle(p.sub)
            ForEach(s.allDTCs, id: \.self) { c in
                let info = DTCKnowledge.info(c)
                NavigationLink { DTCDetailView(p: p, code: c, kinds: kinds(c, s), freeze: s.freezeFrame) } label: {
                    HStack(spacing: 10) {
                        Text(c).font(.system(size: 16, weight: .heavy, design: .monospaced)).foregroundStyle(p.color(info.drive.level))
                            .environment(\.layoutDirection, .leftToRight)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(info.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(p.text)
                            Text(kinds(c, s)).font(.system(size: 11)).foregroundStyle(p.sub)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.left").foregroundStyle(p.sub)
                    }
                    .padding(10)
                    .background(p.bg.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .card(p)
    }

    private func notesCard(_ s: ScanReport) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("ملاحظات").font(.system(size: 13, weight: .semibold)).foregroundStyle(p.sub)
            ForEach(s.notes, id: \.self) { Text("• " + $0).font(.system(size: 13)).foregroundStyle(p.text) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .card(p)
    }

    private var historyCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("الفحوصات السابقة").font(.system(size: 13, weight: .semibold)).foregroundStyle(p.sub)
            ForEach(store.data.scans.dropFirst().prefix(10)) { s in
                HStack {
                    Text(arDate(s.date)).foregroundStyle(p.text)
                    Spacer()
                    Text(s.allDTCs.isEmpty ? "سليم" : "\(s.allDTCs.count) كود").foregroundStyle(s.allDTCs.isEmpty ? p.ok : p.warn)
                }
                .font(.system(size: 13))
            }
        }
        .padding(14)
        .card(p)
    }

    private func kinds(_ c: String, _ s: ScanReport) -> String {
        var k: [String] = []
        if s.storedDTCs.contains(c) { k.append("مخزن") }
        if s.pendingDTCs.contains(c) { k.append("معلق") }
        if s.permanentDTCs.contains(c) { k.append("دائم") }
        for m in s.modules ?? [] where m.dtcs.contains(c) { k.append(m.name) }
        return k.joined(separator: " · ")
    }

    private func reportText(_ s: ScanReport) -> String {
        let v = ScanVerdict.evaluate(s, data: store.data)
        var t = "تقرير RA7AL OBD — \(arDate(s.date))\n"
        t += "النتيجة: \(v.headline) (القيادة: \(v.drive.title) · الاستعجال: \(v.urgency.title) · الثقة: \(v.confidence.title))\n"
        t += "VIN: \(s.vin ?? store.data.vin ?? "-")\n"
        for sec in v.sections { t += "• \(sec.title): \(sec.badge) — \(sec.detail)\n" }
        if !s.allDTCs.isEmpty {
            t += "الأكواد:\n" + s.allDTCs.map { "  \($0) \(DTCKnowledge.info($0).title)" }.joined(separator: "\n") + "\n"
        }
        t += "البطارية: \(fmt(s.batteryV, "%.1f")) V · الماء: \(fmt(s.coolantC))°C · الزيت: \(fmt(s.oilC))°C\n"
        return t
    }
}

// MARK: - One code explained

struct DTCDetailView: View {
    let p: Palette
    var code: String
    var kinds: String = ""
    var freeze: FreezeFrame?

    var body: some View {
        let info = DTCKnowledge.info(code)
        let c = p.color(info.drive.level)
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(info.code).font(.system(size: 26, weight: .heavy, design: .monospaced)).foregroundStyle(p.text)
                            .environment(\.layoutDirection, .leftToRight)
                        Spacer()
                        Text(info.urgency.title).font(.system(size: 12, weight: .bold)).foregroundStyle(c)
                            .padding(.horizontal, 10).padding(.vertical, 4).background(c.opacity(0.15), in: Capsule())
                    }
                    Text(info.title).font(.system(size: 18, weight: .bold)).foregroundStyle(p.text)
                    if !kinds.isEmpty { Text(kinds).font(.system(size: 12)).foregroundStyle(p.sub) }
                }
                .padding(14)
                .card(p)
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(c.opacity(0.5), lineWidth: 1))

                VerdictChips(p: p, drive: info.drive, urgency: info.urgency, confidence: info.generic ? .medium : .high)

                VStack(alignment: .leading, spacing: 6) {
                    label("وش معناه")
                    Text(info.meaning).font(.system(size: 15)).foregroundStyle(p.text)
                    label("أشهر الأسباب")
                    ForEach(info.causes, id: \.self) { Text("• " + $0).font(.system(size: 15)).foregroundStyle(p.text) }
                    label("وش تسوي الحين")
                    Text(info.action).font(.system(size: 15, weight: .semibold)).foregroundStyle(p.text)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .card(p)

                if let f = freeze, f.dtc == nil || f.dtc == info.code {
                    VStack(alignment: .leading, spacing: 6) {
                        label("لحظة تسجيل العطل (Freeze Frame)")
                        row("الدوران", f.rpm.map { "\(Int($0)) rpm" })
                        row("السرعة", f.speedKmh.map { "\(Int($0)) كم/س" })
                        row("حرارة الماء", f.coolantC.map { "\(Int($0))°" })
                    }
                    .padding(14)
                    .card(p)
                }

                if info.generic {
                    Text("الشرح عام حسب نوع الكود لأنه غير موجود في دليل التطبيق.")
                        .font(.footnote).foregroundStyle(p.sub)
                }
            }
            .padding(16)
        }
        .scrollIndicators(.hidden)
        .background(p.bg.ignoresSafeArea())
        .navigationTitle("شرح الكود")
        .navigationBarTitleDisplayMode(.inline)
        .arabicBackButton()
    }

    private func label(_ t: String) -> some View {
        Text(t).font(.system(size: 12, weight: .semibold)).foregroundStyle(p.sub).padding(.top, 4)
    }

    private func row(_ k: String, _ v: String?) -> some View {
        HStack { Text(k).foregroundStyle(p.sub); Spacer(); Text(v ?? "—").foregroundStyle(p.text) }.font(.system(size: 14))
    }
}

// MARK: - Code guide (look up any code)

struct DTCLibraryView: View {
    let p: Palette
    @State private var query = ""

    private var results: [DTCInfo] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return DTCKnowledge.all }
        if let code = DTCKnowledge.normalize(q) { return [DTCKnowledge.info(code)] }
        return DTCKnowledge.all.filter { $0.code.localizedCaseInsensitiveContains(q) || $0.title.contains(q) }
    }

    var body: some View {
        List {
            Section {
                ForEach(results) { i in
                    NavigationLink { DTCDetailView(p: p, code: i.code) } label: {
                        HStack(spacing: 10) {
                            Text(i.code).font(.system(size: 15, weight: .bold, design: .monospaced)).foregroundStyle(p.color(i.drive.level))
                                .environment(\.layoutDirection, .leftToRight)
                            Text(i.title).font(.system(size: 14)).foregroundStyle(p.text).lineLimit(2)
                        }
                    }
                    .listRowBackground(p.card)
                }
            } footer: {
                Text("اكتب أي كود (مثل P0299) أو كلمة (مثل التيربو). الدليل يشتغل بدون إنترنت.").foregroundStyle(p.sub)
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "ابحث بالكود أو الوصف")
        .scrollContentBackground(.hidden)
        .background(p.bg.ignoresSafeArea())
        .navigationTitle("دليل أكواد الأعطال")
        .navigationBarTitleDisplayMode(.inline)
        .arabicBackButton()
    }
}

// MARK: - Vehicle data read from the truck

struct VehicleInfoView: View {
    let p: Palette
    @ObservedObject var store = VehicleStore.shared

    var body: some View {
        let scan = store.lastScan
        let vin = scan?.vin ?? store.data.vin
        let id = vin.flatMap(VehicleIdentity.decode)
        ScrollView {
            VStack(spacing: 12) {
                VStack(spacing: 6) {
                    Image(systemName: symbol("truck.pickup.side.fill", "car.fill")).font(.system(size: 44)).foregroundStyle(p.heroAccent)
                    Text(id?.displayName ?? "بانتظار أول فحص").font(.system(size: 20, weight: .heavy)).foregroundStyle(p.heroText)
                        .multilineTextAlignment(.center)
                    if let e = id?.engine ?? scan?.fuelType { Text(e).font(.system(size: 13)).foregroundStyle(p.heroText.opacity(0.8)) }
                    Text(vin != nil ? "✓ قُرئت تلقائيًا من السيارة — ما تحتاج تكتب شيء" : "شغّل السيارة وسوّ فحص شامل لقراءة البيانات")
                        .font(.system(size: 12)).foregroundStyle(p.heroText.opacity(0.85))
                }
                .frame(maxWidth: .infinity)
                .padding(18)
                .background(p.hero, in: RoundedRectangle(cornerRadius: 22, style: .continuous))

                VStack(spacing: 0) {
                    row("رقم الهيكل", vin.map { VIN.isValid($0) ? $0 + " ✓" : $0 }, ltr: true)
                    row("العداد", String(format: "%.0f كم", store.data.oil.odometerKm)
                        + (scan?.fordOdometerKm != nil ? " (من كمبيوتر فورد)" : ""))
                    row("ساعات المحرك", scan?.engineHours.map { "\(Int($0)) ساعة" })
                    row("ساعات التباطؤ", scan?.idleHours.map { "\(Int($0)) ساعة" })
                    row("نوع الوقود", scan?.fuelType)
                    row("المصنع", id?.plant)
                    row("سعة الخزان", "\(Int(store.data.fuel.tankLiters)) لتر")
                }
                .padding(.horizontal, 14).padding(.vertical, 4)
                .card(p)

                VStack(alignment: .leading, spacing: 8) {
                    Text("كمبيوترات فورد").font(.system(size: 13, weight: .semibold)).foregroundStyle(p.sub)
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                        ForEach(FordModuleSpec.all) { m in
                            let r = scan?.modules?.first { $0.key == m.key }
                            let ok = r?.responded == true
                            HStack {
                                Text(m.name).font(.system(size: 13)).foregroundStyle(p.text)
                                Spacer()
                                Image(systemName: ok ? "circle.fill" : "circle").font(.system(size: 10)).foregroundStyle(ok ? p.ok : p.sub)
                            }
                            .padding(10)
                            .background(p.bg.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                    Text("● يستجيب   ○ القطعة لم تسمح بالوصول أو لم يُفحص بعد").font(.system(size: 11)).foregroundStyle(p.sub)
                }
                .padding(14)
                .card(p)
            }
            .padding(16)
        }
        .scrollIndicators(.hidden)
        .background(p.bg.ignoresSafeArea())
        .navigationTitle("بيانات السيارة")
        .navigationBarTitleDisplayMode(.inline)
        .arabicBackButton()
    }

    private func row(_ k: String, _ v: String?, ltr: Bool = false) -> some View {
        HStack {
            Text(k).foregroundStyle(p.sub)
            Spacer()
            Text(v ?? "—").foregroundStyle(p.text).textSelection(.enabled)
                .font(ltr ? .system(size: 13, design: .monospaced) : .system(size: 14))
        }
        .font(.system(size: 14))
        .padding(.vertical, 9)
    }
}
