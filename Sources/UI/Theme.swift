import SwiftUI
import UIKit

struct Palette {
    var bg, card, border, text, sub, track, accent, onAccent, warn, warnBg, danger, ok, hero, heroText, heroTrack, heroAccent: Color
    var scheme: ColorScheme

    static func of(_ t: AppTheme) -> Palette {
        switch t {
        case .dark:
            return Palette(bg: .hex(0x0A0F1A), card: .hex(0x121A2B), border: .hex(0x1F2A40), text: .hex(0xF8FAFC), sub: .hex(0x94A3B8),
                           track: .hex(0x1E293B), accent: .hex(0x38BDF8), onAccent: .hex(0x04131D), warn: .hex(0xFBBF24), warnBg: .hex(0x2A1F06),
                           danger: .hex(0xF43F5E), ok: .hex(0x4ADE80), hero: .hex(0x0E2A3D), heroText: .hex(0xF8FAFC),
                           heroTrack: .hex(0x1B4258), heroAccent: .hex(0x38BDF8), scheme: .dark)
        case .light:
            return Palette(bg: .hex(0xF3F5F9), card: .hex(0xFFFFFF), border: .hex(0xE2E8F0), text: .hex(0x0F172A), sub: .hex(0x475569),
                           track: .hex(0xE2E8F0), accent: .hex(0x0369A1), onAccent: .white, warn: .hex(0xB45309), warnBg: .hex(0xFFF7E6),
                           danger: .hex(0xBE123C), ok: .hex(0x15803D), hero: .hex(0x0369A1), heroText: .white,
                           heroTrack: .hex(0x3B8CBF), heroAccent: .white, scheme: .light)
        case .youth:
            return Palette(bg: .hex(0x0C0B14), card: .hex(0x17152A), border: .hex(0x2B2850), text: .white, sub: .hex(0xA9A6CF),
                           track: .hex(0x25223F), accent: .hex(0xA3E635), onAccent: .hex(0x0C1400), warn: .hex(0xFB923C), warnBg: .hex(0x2B1708),
                           danger: .hex(0xF43F5E), ok: .hex(0xA3E635), hero: .hex(0x5B21B6), heroText: .white,
                           heroTrack: .hex(0x7C4DCC), heroAccent: .hex(0xA3E635), scheme: .dark)
        }
    }

    func color(_ l: AlertLevel) -> Color { l == .danger ? danger : (l == .warn ? warn : ok) }
}

extension Color {
    static func hex(_ v: UInt32) -> Color {
        Color(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

/// Car-dashboard style symbols, with safe fallbacks if a symbol is missing on the installed iOS.
enum CarIcon: String {
    case coolant, oil, fuel, battery, tires, rail, scan, station, home, camera, settings, brake, bump, engine

    var symbol: String {
        let options: [String]
        switch self {
        case .coolant: options = ["thermometer.and.liquid.waves", "thermometer.medium"]
        case .oil: options = ["oilcan.fill", "drop.fill"]
        case .fuel: options = ["fuelpump.fill"]
        case .battery: options = ["minus.plus.batteryblock.fill", "bolt.car.fill", "bolt.fill"]
        case .tires: options = ["exclamationmark.tirepressure", "tirepressure", "circle.circle"]
        case .rail: options = ["gauge.with.dots.needle.67percent", "gauge"]
        case .scan: options = ["checkmark.shield.fill", "stethoscope"]
        case .station: options = ["mappin.and.ellipse", "map"]
        case .home: options = ["house.fill"]
        case .camera: options = ["video.fill"]
        case .settings: options = ["gearshape.fill"]
        case .brake: options = ["exclamationmark.octagon.fill"]
        case .bump: options = ["waveform.path.ecg"]
        case .engine: options = ["engine.combustion.fill", "car.fill"]
        }
        return options.first { UIImage(systemName: $0) != nil } ?? "circle"
    }
}
