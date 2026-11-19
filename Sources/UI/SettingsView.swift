import SwiftUI

struct SettingsView: View {
    let p: Palette
    @ObservedObject var store = VehicleStore.shared
    @ObservedObject var link = OBDLink.shared
    @State private var odometerText = ""

    var body: some View {
        Form {
            Section("المظهر") {
                Picker("المظهر", selection: $store.data.theme) {
                    ForEach(AppTheme.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            Section("حدود التنبيه") {
                stepper("حرارة الماء — تنبيه", $store.data.limits.coolantWarn, 95...125, "°C")
                stepper("حرارة الماء — خطر", $store.data.limits.coolantDanger, 100...130, "°C")
                stepper("حرارة الزيت — تنبيه", $store.data.limits.oilWarn, 100...140, "°C")
                stepper("حرارة الزيت — خطر", $store.data.limits.oilDanger, 110...150, "°C")
                stepper("الديزل — تنبيه عند", $store.data.limits.fuelWarnPercent, 5...50, "%")
                stepper("الديزل — خطر عند مسافة", $store.data.limits.rangeDangerKm, 20...200, "كم", step: 10)
                stepper("ضغط الكفرات الأمامية", $store.data.limits.tireFrontPsi, 30...90, "psi")
                stepper("ضغط الكفرات الخلفية", $store.data.limits.tireRearPsi, 30...90, "psi")
                Toggle("قراءة التنبيهات بالصوت", isOn: $store.data.speakAlerts)
            }

            Section("السيارة") {
                NavigationLink { VehicleInfoView(p: p) } label: { Label("بيانات السيارة", systemImage: "car.fill") }
                    .accessibilityIdentifier("settings-vehicle")
                NavigationLink { DTCLibraryView(p: p) } label: { Label("دليل أكواد الأعطال", systemImage: "book.fill") }
                stepper("سعة التانكي", $store.data.fuel.tankLiters, 60...250, "لتر")
                HStack {
                    Text("العداد الحالي")
                    TextField("كم", text: $odometerText).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                        .onSubmit(saveOdometer)
                    Button("حفظ", action: saveOdometer)
                }
                if let v = store.data.vin { row("رقم الهيكل", v) }
                row("متوسط الاستهلاك المتعلم", String(format: "%.1f L/100km", store.data.fuel.avgLper100))
            }

            Section("الزيت") {
                stepper("التغيير كل", $store.data.oil.intervalKm, 3000...20000, "كم", step: 500)
                stepper("أو كل ساعات تشغيل", $store.data.oil.intervalEngineHours, 100...600, "ساعة", step: 25)
                stepper("أو كل", $store.data.oil.intervalDays, 60...365, "يوم", step: 15)
                if let d = store.data.oil.lastChangeDate { row("آخر تغيير", arDate(d, time: false)) }
            }

            Section("الفحص التلقائي") {
                Toggle("فحص شامل عند الاتصال بالسيارة", isOn: $store.data.autoScanOnConnect)
                Text("لفتح التطبيق على شاشة السيارة تلقائيًا: تطبيق الاختصارات ← الأتمتة ← جديد ← CarPlay ← عند الاتصال ← «فحص شامل» من RA7AL OBD ← تشغيل فورًا.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section("القطعة") {
                row("الحالة", link.status.title)
                row("بث القطعة التلقائي", link.streamActive ? "يعمل" : "متوقف")
                NavigationLink("أداة فحص القطعة") {
                    ProbeView()
                        .arabicBackButton()
                        .onAppear { link.pause() }
                        .onDisappear { link.resume() }
                }
                Button("نسيان القطعة والبحث من جديد", role: .destructive) { link.forgetAdapter() }
            }

            Section("حول") {
                row("الإصدار", (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "-")
                row("القطعة المدعومة", "ZUS / NONDA OBDBLE")
            }
        }
        .navigationTitle("الإعدادات")
        .arabicBackButton()
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background(p.bg.ignoresSafeArea())
        .onAppear { odometerText = String(format: "%.0f", store.data.oil.odometerKm) }
    }

    private func saveOdometer() {
        if let v = Double(odometerText.replacingOccurrences(of: ",", with: "")), v > 0 { store.data.oil.odometerKm = v }
    }

    private func row(_ a: String, _ b: String) -> some View {
        HStack { Text(a); Spacer(); Text(b).foregroundStyle(.secondary).textSelection(.enabled) }
    }

    private func stepper(_ title: String, _ v: Binding<Double>, _ range: ClosedRange<Double>, _ unit: String, step: Double = 1) -> some View {
        Stepper(value: v, in: range, step: step) {
            HStack { Text(title); Spacer(); Text("\(Int(v.wrappedValue)) \(unit)").foregroundStyle(.secondary) }
        }
    }
}
