import SwiftUI

@main
struct RA7ALOBDProbeApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.layoutDirection, .rightToLeft)
                .preferredColorScheme(.dark)
        }
    }
}

struct ContentView: View {
    @StateObject private var probe = BLEProbe()
    private let accent = Color(red: 0.13, green: 0.83, blue: 0.93)

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("أداة فحص القطعة").font(.title2.bold())
                        Text("شغّل السيارة، وأغلق تطبيق ZUS تمامًا، ثم اضغط بحث واختر القطعة (OBDBLE). الفحص يقرأ فقط ولا يغيّر شيئًا في السيارة.")
                            .font(.footnote).foregroundStyle(.secondary)
                        Text(probe.state).font(.callout.bold()).foregroundStyle(accent)
                            .accessibilityIdentifier("state")
                    }.padding(.vertical, 4)
                    Button {
                        probe.startScan()
                    } label: {
                        Label(probe.isScanning ? "جاري البحث…" : "بحث عن القطعة", systemImage: "antenna.radiowaves.left.and.right")
                    }
                    .disabled(probe.isScanning || probe.isRunning)
                    .accessibilityIdentifier("scan")
                }

                if !probe.devices.isEmpty && !probe.isRunning && probe.summary.isEmpty {
                    Section("الأجهزة القريبة") {
                        ForEach(probe.devices) { d in
                            Button { probe.connect(d) } label: {
                                HStack {
                                    Image(systemName: d.name.uppercased().contains("OBD") ? "car.fill" : "dot.radiowaves.left.and.right")
                                        .foregroundStyle(d.name.uppercased().contains("OBD") ? accent : .secondary)
                                    Text(d.name)
                                    Spacer()
                                    Text(d.rssi == 0 ? "متصل بالجوال" : "\(d.rssi) dBm").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                if probe.isRunning {
                    Section { HStack { ProgressView(); Text("الفحص جارٍ… لا تقفل الشاشة") } }
                }

                if !probe.summary.isEmpty {
                    Section("الملخص") {
                        ForEach(Array(probe.summary.enumerated()), id: \.offset) { _, s in
                            Text(s).font(.footnote).textSelection(.enabled)
                        }
                    }
                }

                if !probe.log.isEmpty {
                    Section {
                        ShareLink(item: probe.reportText, subject: Text("RA7AL OBD Probe"), message: Text("تقرير فحص القطعة")) {
                            Label("مشاركة التقرير", systemImage: "square.and.arrow.up")
                        }.accessibilityIdentifier("share")
                        Button {
                            UIPasteboard.general.string = probe.reportText
                        } label: { Label("نسخ التقرير", systemImage: "doc.on.doc") }
                        if probe.isRunning {
                            Button(role: .destructive) { probe.disconnect() } label: { Label("إيقاف", systemImage: "stop.circle") }
                        }
                    }
                    Section("السجل (\(probe.log.count))") {
                        ForEach(Array(probe.log.suffix(150).enumerated()), id: \.offset) { _, l in
                            Text(l).font(.system(size: 11, design: .monospaced))
                                .environment(\.layoutDirection, .leftToRight)
                        }
                    }
                }
            }
            .navigationTitle("RA7AL OBD")
        }
        .tint(accent)
    }
}
