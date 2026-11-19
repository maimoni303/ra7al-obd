import SwiftUI

struct CardStyle: ViewModifier {
    let p: Palette
    var radius: CGFloat = 18
    func body(content: Content) -> some View {
        content
            .background(p.card, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(p.border, lineWidth: 1))
    }
}

extension View {
    func card(_ p: Palette, radius: CGFloat = 18) -> some View { modifier(CardStyle(p: p, radius: radius)) }
}

struct Ring: View {
    var fraction: Double
    var color: Color
    var track: Color
    var width: CGFloat = 7
    var body: some View {
        ZStack {
            Circle().stroke(track, lineWidth: width)
            Circle().trim(from: 0, to: max(0.001, min(1, fraction)))
                .stroke(color, style: StrokeStyle(lineWidth: width, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.5), value: fraction)
        }
    }
}

/// The approved "design 2" gauge: ring with a dashboard symbol inside, big value, small caption.
struct IconGauge: View {
    let p: Palette
    var icon: CarIcon
    var value: String
    var caption: String
    var fraction: Double
    var color: Color

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Ring(fraction: fraction, color: color, track: p.track, width: 6)
                Image(systemName: icon.symbol).font(.system(size: 20, weight: .semibold)).foregroundStyle(color)
            }
            .frame(width: 58, height: 58)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(value).font(.system(size: 21, weight: .bold)).foregroundStyle(p.text).minimumScaleFactor(0.7).lineLimit(1)
                Text(caption).font(.system(size: 11)).foregroundStyle(p.sub).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .card(p)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(caption) \(value)")
    }
}

struct PrimaryButton: View {
    let p: Palette
    var title: String
    var icon: String?
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon { Image(systemName: icon) }
                Text(title).font(.system(size: 17, weight: .bold))
            }
            .frame(maxWidth: .infinity, minHeight: 54)
            .foregroundStyle(p.onAccent)
            .background(p.accent, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

struct SecondaryButton: View {
    let p: Palette
    var title: String
    var icon: String?
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon { Image(systemName: icon) }
                Text(title).font(.system(size: 15, weight: .semibold))
            }
            .frame(maxWidth: .infinity, minHeight: 48)
            .foregroundStyle(p.text)
            .card(p, radius: 14)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

struct TireDiagram: View {
    let p: Palette
    var tires: TireSet
    var limits: Limits

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(spacing: 44) {
                cell(tires.frontLeft, front: true, label: "أمامي يسار")
                cell(tires.rearLeft, front: false, label: "خلفي يسار")
            }
            .frame(maxWidth: .infinity)
            truck.frame(width: 80, height: 170)
            VStack(spacing: 44) {
                cell(tires.frontRight, front: true, label: "أمامي يمين")
                cell(tires.rearRight, front: false, label: "خلفي يمين")
            }
            .frame(maxWidth: .infinity)
        }
        .environment(\.layoutDirection, .leftToRight)   // physical left stays on the left
    }

    private func cell(_ v: Double?, front: Bool, label: String) -> some View {
        let c = v == nil ? p.sub : p.color(limits.tireLevel(psi: v, front: front))
        return VStack(spacing: 2) {
            Text(v.map { String(Int($0.rounded())) } ?? "—").font(.system(size: 24, weight: .bold)).foregroundStyle(c)
            Text(label).font(.system(size: 11)).foregroundStyle(p.sub)
        }
        .accessibilityElement(children: .combine)
    }

    private func wheelColor(_ i: Int) -> Color {
        let all: [Double?] = [tires.frontLeft, tires.frontRight, tires.rearLeft, tires.rearRight]
        guard let v = all[i] else { return p.sub }
        return p.color(limits.tireLevel(psi: v, front: i < 2))
    }

    private var truck: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16).fill(p.track).frame(width: 44, height: 154)
            RoundedRectangle(cornerRadius: 6).fill(p.bg).frame(width: 32, height: 26).offset(y: -46)
            RoundedRectangle(cornerRadius: 4).fill(p.bg.opacity(0.6)).frame(width: 32, height: 60).offset(y: 29)
            ForEach(0..<4, id: \.self) { i in
                RoundedRectangle(cornerRadius: 4).fill(wheelColor(i))
                    .frame(width: 10, height: 26)
                    .offset(x: i % 2 == 0 ? -27 : 27, y: i < 2 ? -50 : 46)
            }
        }
        .accessibilityHidden(true)
    }
}

func fmt(_ v: Double?, _ f: String = "%.0f") -> String { v.map { String(format: f, $0) } ?? "—" }

let arabicLocale = Locale(identifier: "ar")

func arDate(_ d: Date, time: Bool = true) -> String {
    d.formatted(Date.FormatStyle(date: .abbreviated, time: time ? .shortened : .omitted).locale(arabicLocale))
}

/// Same back button, same place and size, on every pushed page.
struct ArabicBackButton: ViewModifier {
    @Environment(\.dismiss) private var dismiss
    func body(content: Content) -> some View {
        content
            .navigationBarBackButtonHidden(true)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: {
                        HStack(spacing: 4) { Image(systemName: "chevron.forward"); Text("رجوع") }
                            .font(.system(size: 17, weight: .semibold))
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityIdentifier("back")
                }
            }
    }
}

extension View {
    func arabicBackButton() -> some View { modifier(ArabicBackButton()) }
}
