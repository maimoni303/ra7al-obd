import SwiftUI

struct OilTiresView: View {
    let p: Palette
    @ObservedObject var store = VehicleStore.shared
    @ObservedObject var link = OBDLink.shared
    @State private var confirmChange = false
    @State private var showCalibrate = false

    private var oil: OilModel { store.data.oil }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                oilCard
                tiresCard
            }
            .padding(.bottom, 8)
        }
        .scrollIndicators(.hidden)
        .confirmationDialog("تأكيد تغيير الزيت", isPresented: $confirmChange, titleVisibility: .visible) {
            Button("نعم، غيّرت الزيت اليوم") { store.data.oil.recordChange() }
            Button("إلغاء", role: .cancel) {}
        } message: {
            Text(String(format: "يبدأ العداد من جديد على %.0f كم.", oil.odometerKm))
        }
        .sheet(isPresented: $showCalibrate) { TPMSCalibrationView(p: p).environment(\.layoutDirection, .rightToLeft) }
    }

    private var oilCard: some View {
        let life = oil.lifePercent()
        let c = p.color(oil.level())
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                ZStack {
                    Ring(fraction: (life ?? 0) / 100, color: life == nil ? p.sub : c, track: p.track, width: 9)
                    VStack(spacing: 0) {
                        Image(systemName: CarIcon.oil.symbol).font(.system(size: 16, weight: .semibold)).foregroundStyle(c)
                        Text(life.map { "\(Int($0))%" } ?? "—").font(.system(size: 19, weight: .bold)).foregroundStyle(p.text)
                    }
                }
                .frame(width: 88, height: 88)
                VStack(alignment: .leading, spacing: 3) {
                    Text("عمر زيت المكينة").font(.system(size: 13)).foregroundStyle(p.sub)
                    if life == nil {
                        Text("سجّل آخر تغيير").font(.system(size: 18, weight: .bold)).foregroundStyle(p.text)
                        Text("اضغط «غيّرت الزيت» يوم تغيّره، أو عدّل من الإعدادات").font(.system(size: 12)).foregroundStyle(p.sub)
                    } else {
                        Text("باقي ~\(Int(oil.kmLeft() ?? 0)) كم").font(.system(size: 18, weight: .bold)).foregroundStyle(p.text)
                        Text(oil.fordOilLifePercent != nil ? "المصدر: كمبيوتر فورد" : "المصدر: حساب التطبيق (كم + ساعات + وقوف)")
                            .font(.system(size: 12)).foregroundStyle(p.sub)
                    }
                }
                Spacer(minLength: 0)
            }
            HStack {
                stat("كم منذ التغيير", oil.kmSinceChange.map { "\(Int($0))" } ?? "—")
                stat("ساعات تشغيل", String(format: "%.0f", oil.engineHoursSinceChange))
                stat("منها وقوف", String(format: "%.0f", oil.idleHoursSinceChange))
            }
            SecondaryButton(p: p, title: "غيّرت الزيت اليوم", icon: "checkmark.circle") { confirmChange = true }
        }
        .padding(16)
        .card(p, radius: 22)
    }

    private func stat(_ t: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(t).font(.system(size: 11)).foregroundStyle(p.sub)
            Text(v).font(.system(size: 15, weight: .semibold)).foregroundStyle(p.text)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var tiresCard: some View {
        let tires = link.readings.tires.hasAny ? link.readings.tires : (store.lastScan?.tires ?? TireSet())
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: CarIcon.tires.symbol).foregroundStyle(p.accent)
                Text("ضغط الكفرات").font(.system(size: 14, weight: .semibold)).foregroundStyle(p.text)
                Spacer()
                Text(String(format: "المعتمد %.0f قدام · %.0f ورا", store.data.limits.tireFrontPsi, store.data.limits.tireRearPsi))
                    .font(.system(size: 12)).foregroundStyle(p.sub)
            }
            TireDiagram(p: p, tires: tires, limits: store.data.limits)
            if !tires.hasAny {
                Text(tireHint).font(.system(size: 12)).foregroundStyle(p.sub)
                if !store.data.lastTPMSRaw.isEmpty && !store.data.tpms.confirmed {
                    SecondaryButton(p: p, title: "معايرة الكفرات (مرة وحدة)", icon: "slider.horizontal.3") { showCalibrate = true }
                }
            }
        }
        .padding(16)
        .card(p, radius: 22)
    }

    private var tireHint: String {
        if store.data.lastTPMSRaw.isEmpty { return "تظهر القيم بعد أول فحص شامل إذا القطعة توصل لوحدة الكفرات." }
        return "القطعة قرأت وحدة الكفرات. اكتب الأرقام اللي في الطبلون مرة وحدة عشان يتعلم التطبيق طريقة قراءتها."
    }
}

struct TPMSCalibrationView: View {
    let p: Palette
    @ObservedObject var store = VehicleStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var fl = ""
    @State private var fr = ""
    @State private var rl = ""
    @State private var rr = ""
    @State private var result: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("اكتب ضغط كل كفر كما يظهر في الطبلون (psi)") {
                    field("أمامي يسار", $fl); field("أمامي يمين", $fr); field("خلفي يسار", $rl); field("خلفي يمين", $rr)
                }
                Section("القراءة الخام من السيارة") {
                    ForEach(store.data.lastTPMSRaw.sorted(by: { $0.key < $1.key }), id: \.key) { item in
                        HStack { Text(item.key); Spacer(); Text("\(item.value)").foregroundStyle(.secondary) }
                    }
                }
                if let result { Section { Text(result) } }
                Section {
                    Button("احفظ المعايرة", action: save)
                }
            }
            .navigationTitle("معايرة الكفرات")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("إغلاق") { dismiss() } } }
        }
        .preferredColorScheme(p.scheme)
    }

    private func field(_ t: String, _ b: Binding<String>) -> some View {
        HStack { Text(t); TextField("psi", text: b).keyboardType(.decimalPad).multilineTextAlignment(.trailing) }
    }

    private func save() {
        let raw = store.data.lastTPMSRaw
        let pairs: [(String, String)] = [("FL", fl), ("FR", fr), ("RL", rl), ("RR", rr)]
        var r: [Int] = [], d: [Double] = []
        for (k, s) in pairs { if let v = raw[k], let x = Double(s) { r.append(v); d.append(x) } }
        guard let cal = TPMSCalibration.fit(raw: r, dash: d) else { result = "اكتب رقم كفر واحد على الأقل."; return }
        if cal.confirmed {
            store.data.tpms = cal
            result = "تمت المعايرة ✓ — بتظهر الأرقام من الفحص الجاي."
        } else {
            result = "الأرقام ما تطابق أي طريقة معروفة. أرسل لقطة من هذي الشاشة للتحديث الجاي."
        }
    }
}
