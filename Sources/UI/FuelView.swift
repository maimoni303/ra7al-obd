import SwiftUI
import MapKit
import CoreLocation

@MainActor
final class StationFinder: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = StationFinder()
    @Published var stations: [MKMapItem] = []
    @Published var location: CLLocation?
    @Published var searching = false
    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func start() {
        manager.requestWhenInUseAuthorization()
        manager.startUpdatingLocation()
    }

    func search() async {
        guard let loc = location else { return }
        searching = true
        defer { searching = false }
        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = "محطة وقود ديزل"
        req.pointOfInterestFilter = MKPointOfInterestFilter(including: [.gasStation])
        req.region = MKCoordinateRegion(center: loc.coordinate, latitudinalMeters: 15000, longitudinalMeters: 15000)
        let items = (try? await MKLocalSearch(request: req).start())?.mapItems ?? []
        stations = items.sorted {
            ($0.placemark.location?.distance(from: loc) ?? .greatestFiniteMagnitude) < ($1.placemark.location?.distance(from: loc) ?? .greatestFiniteMagnitude)
        }
    }

    nonisolated func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        guard let l = locs.last else { return }
        Task { @MainActor in
            let first = self.location == nil
            self.location = l
            if first { await self.search() }
        }
    }

    /// Google Maps when installed (CarPlay too), otherwise Google Maps on the web, otherwise Apple Maps.
    static func directionsURL(to c: CLLocationCoordinate2D) -> URL {
        let app = URL(string: "comgooglemaps://?daddr=\(c.latitude),\(c.longitude)&directionsmode=driving")!
        if UIApplication.shared.canOpenURL(app) { return app }
        return URL(string: "https://www.google.com/maps/dir/?api=1&destination=\(c.latitude),\(c.longitude)&travelmode=driving")!
    }
}

struct FuelView: View {
    let p: Palette
    @ObservedObject var store = VehicleStore.shared
    @ObservedObject var link = OBDLink.shared
    @ObservedObject var finder = StationFinder.shared
    @Environment(\.openURL) private var openURL
    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)

    private var level: Double? { link.readings.fuelLevelPercent }
    private var range: Double? { store.data.fuel.rangeKm(levelPercent: level) }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                rangeCard
                mapCard
                if !store.data.fuel.refuels.isEmpty { refuelsCard }
            }
            .padding(.bottom, 8)
        }
        .scrollIndicators(.hidden)
        .onAppear { if !OBDLink.isUITesting { finder.start() } }
    }

    private var rangeCard: some View {
        let lvl = store.data.limits.fuelLevel(percent: level, rangeKm: range)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: CarIcon.fuel.symbol).foregroundStyle(lvl == .ok ? p.accent : p.color(lvl))
                Text("تمشي قبل ما يخلص الديزل").font(.system(size: 13)).foregroundStyle(p.sub)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(range.map { "\(Int($0))" } ?? "—").font(.system(size: 46, weight: .bold)).foregroundStyle(p.text)
                Text("كم").font(.system(size: 18)).foregroundStyle(p.sub)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(p.track)
                    Capsule().fill(lvl == .ok ? p.accent : p.color(lvl)).frame(width: g.size.width * CGFloat((level ?? 0) / 100))
                }
                .environment(\.layoutDirection, .leftToRight)
            }
            .frame(height: 14)
            HStack {
                stat("في التانكي", level.map { String(format: "%.0f من %.0f لتر", store.data.fuel.litersLeft(levelPercent: $0), store.data.fuel.tankLiters) } ?? "—")
                stat("متوسطك", String(format: "%.1f L/100km", store.data.fuel.avgLper100))
                stat("الآن", fmt(link.readings.fuelRateLh, "%.1f L/h"))
            }
            Text("الحساب يتعلم من استهلاكك الحقيقي، ويصير أدق مع كل مشوار.").font(.system(size: 11)).foregroundStyle(p.sub)
        }
        .padding(16)
        .card(p, radius: 22)
    }

    private func stat(_ t: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(t).font(.system(size: 11)).foregroundStyle(p.sub)
            Text(v).font(.system(size: 15, weight: .semibold)).foregroundStyle(p.text).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var mapCard: some View {
        VStack(spacing: 0) {
            Map(position: $camera) {
                UserAnnotation()
                ForEach(Array(finder.stations.prefix(8).enumerated()), id: \.offset) { _, s in
                    Marker(s.name ?? "محطة", systemImage: "fuelpump.fill", coordinate: s.placemark.coordinate).tint(.orange)
                }
            }
            .frame(height: 260)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            if let s = finder.stations.first {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("أقرب محطة · \(distance(s))").font(.system(size: 14, weight: .semibold)).foregroundStyle(p.text)
                        Text(s.name ?? "").font(.system(size: 12)).foregroundStyle(p.sub).lineLimit(1)
                    }
                    Spacer()
                    Button("ابدأ في قوقل ماب") { openURL(StationFinder.directionsURL(to: s.placemark.coordinate)) }
                        .font(.system(size: 14, weight: .bold))
                        .padding(.horizontal, 12).frame(height: 44)
                        .foregroundStyle(p.onAccent).background(p.accent, in: RoundedRectangle(cornerRadius: 12))
                }
                .padding(12)
            } else {
                Text(finder.searching ? "جاري البحث عن محطات قريبة…" : "اسمح بالموقع لعرض أقرب محطات الديزل")
                    .font(.system(size: 13)).foregroundStyle(p.sub).padding(12)
            }
        }
        .card(p, radius: 22)
    }

    private func distance(_ s: MKMapItem) -> String {
        guard let a = finder.location, let b = s.placemark.location else { return "" }
        return String(format: "%.1f كم", a.distance(from: b) / 1000)
    }

    private var refuelsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("آخر التعبئات").font(.system(size: 14, weight: .semibold)).foregroundStyle(p.text)
            ForEach(store.data.fuel.refuels.suffix(5).reversed(), id: \.date) { r in
                HStack {
                    Text(arDate(r.date)).foregroundStyle(p.sub)
                    Spacer()
                    Text(String(format: "+%.0f لتر", r.liters)).foregroundStyle(p.text)
                }
                .font(.system(size: 13))
            }
        }
        .padding(14)
        .card(p)
    }
}
