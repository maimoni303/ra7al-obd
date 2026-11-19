import SwiftUI

enum MainTab: String, CaseIterable, Identifiable {
    case home, fuel, oil, cam
    var id: String { rawValue }
    var title: String {
        switch self {
        case .home: return "الرئيسية"
        case .fuel: return "الوقود"
        case .oil: return "الزيت والكفرات"
        case .cam: return "الداشكام"
        }
    }
    var icon: CarIcon {
        switch self {
        case .home: return .home
        case .fuel: return .fuel
        case .oil: return .oil
        case .cam: return .camera
        }
    }
}

struct RootView: View {
    @ObservedObject var store = VehicleStore.shared
    @ObservedObject var link = OBDLink.shared
    @State private var tab: MainTab = .home
    @State private var showSettings = false

    var p: Palette { Palette.of(store.data.theme) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                header
                Group {
                    switch tab {
                    case .home: HomeView(p: p, goTo: { tab = $0 })
                    case .fuel: FuelView(p: p)
                    case .oil: OilTiresView(p: p)
                    case .cam: DashcamView(p: p)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
                tabBar
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 6)
            .background(p.bg.ignoresSafeArea())
            .navigationDestination(isPresented: $showSettings) { SettingsView(p: p) }
            .toolbar(.hidden, for: .navigationBar)
        }
        .tint(p.accent)
        .preferredColorScheme(p.scheme)
        .onReceive(NotificationCenter.default.publisher(for: .ra7alStartScan)) { _ in tab = .home; link.requestScan() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(tab == .home ? "RA7AL OBD" : tab.title).font(.system(size: 21, weight: .bold)).foregroundStyle(p.text)
                HStack(spacing: 6) {
                    Circle().fill(link.status == .connected ? p.ok : p.sub).frame(width: 7, height: 7)
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(p.sub).lineLimit(1)
                }
            }
            Spacer()
            themeSwitch
            Button { showSettings = true } label: {
                Image(systemName: CarIcon.settings.symbol).font(.system(size: 18, weight: .semibold))
                    .frame(width: 44, height: 44).foregroundStyle(p.text).card(p, radius: 22)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("الإعدادات")
            .accessibilityIdentifier("settings")
        }
        .frame(height: 50)
        .padding(.top, 4)
    }

    private var subtitle: String {
        var parts = [link.status.title]
        if let vin = store.data.vin, let y = VIN.year(vin) { parts.append("F-250 · \(y)") }
        parts.append(String(format: "%.0f كم", store.data.oil.odometerKm))
        return parts.joined(separator: " · ")
    }

    private var themeSwitch: some View {
        HStack(spacing: 2) {
            ForEach(AppTheme.allCases) { t in
                let pal = Palette.of(t)
                Button { store.data.theme = t } label: {
                    Circle().fill(pal.accent).frame(width: 14, height: 14)
                        .frame(width: 34, height: 34)
                        .background(store.data.theme == t ? pal.hero : Color.clear, in: RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("مظهر \(t.title)")
                .accessibilityIdentifier("theme-\(t.rawValue)")
            }
        }
        .padding(3)
        .card(p, radius: 12)
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(MainTab.allCases) { t in
                let on = t == tab
                Button { tab = t } label: {
                    VStack(spacing: 2) {
                        Image(systemName: t.icon.symbol).font(.system(size: 19, weight: .semibold))
                        Text(t.title).font(.system(size: 11, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity, minHeight: 54)
                    .foregroundStyle(on ? p.onAccent : p.sub)
                    .background(on ? p.accent : Color.clear, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(t.title)
                .accessibilityIdentifier("tab-\(t.rawValue)")
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(6)
        .card(p, radius: 20)
    }
}

extension Notification.Name {
    static let ra7alStartScan = Notification.Name("ra7al.startScan")
}
