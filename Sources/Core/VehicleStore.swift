import Foundation
import SwiftUI

enum AppTheme: String, Codable, CaseIterable, Identifiable {
    case dark, light, youth
    var id: String { rawValue }
    var title: String {
        switch self {
        case .dark: return "ليلي"
        case .light: return "نهاري"
        case .youth: return "شبابي"
        }
    }
}

/// Everything the app remembers between launches. Saved automatically on every change.
struct AppData: Codable, Equatable {
    var theme: AppTheme = .dark
    var limits = Limits()
    var fuel = FuelModel()
    var oil = OilModel()
    var peripheralID: String?
    var vin: String?
    var scans: [ScanReport] = []
    var tpms = TPMSCalibration()
    var lastTPMSRaw: [String: Int] = [:]
    // Added in 1.0.3 — optional so data saved by older versions still loads.
    var tpmsStatus: String?
    var tpmsDiag: [String]?
    var tpmsReadAt: Date?
    var tpmsFormat: Int?
    var dashcamHost: String?
    var speakAlerts = true
    var autoScanOnConnect = true
}

@MainActor
final class VehicleStore: ObservableObject {
    static let shared = VehicleStore()

    @Published var data: AppData { didSet { if data != oldValue { save() } } }

    private let key = "ra7al.obd.appdata.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let raw = defaults.data(forKey: key), let d = try? JSONDecoder().decode(AppData.self, from: raw) {
            data = d
        } else {
            data = AppData()
        }
    }

    func save() {
        if let raw = try? JSONEncoder().encode(data) { defaults.set(raw, forKey: key) }
    }

    func addScan(_ r: ScanReport) {
        data.scans.insert(r, at: 0)
        if data.scans.count > 30 { data.scans.removeLast(data.scans.count - 30) }
        if let v = r.vin { data.vin = v }
    }

    var lastScan: ScanReport? { data.scans.first }
}
