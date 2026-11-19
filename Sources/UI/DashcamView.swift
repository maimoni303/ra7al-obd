import SwiftUI
import AVKit

struct DashcamView: View {
    let p: Palette
    @ObservedObject var cam = DashcamClient.shared
    @ObservedObject var store = VehicleStore.shared
    @Environment(\.openURL) private var openURL
    @State private var playing: DashcamClient.Clip?

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                liveCard
                statusCard
                if !cam.clips.isEmpty { clipsCard }
            }
            .padding(.bottom, 8)
        }
        .scrollIndicators(.hidden)
        .task { if case .idle = cam.state { await cam.check(preferred: store.data.dashcamHost) } }
        .onDisappear { cam.stopLive() }
        .sheet(item: $playing) { c in
            VideoPlayer(player: AVPlayer(url: c.url)).ignoresSafeArea()
        }
    }

    private var liveCard: some View {
        ZStack {
            if let img = cam.frame {
                Image(uiImage: img).resizable().scaledToFit()
            } else {
                VStack(spacing: 8) {
                    Image(systemName: CarIcon.camera.symbol).font(.system(size: 34)).foregroundStyle(p.sub)
                    Text("البث المباشر").font(.system(size: 14, weight: .semibold)).foregroundStyle(p.text)
                    Text("يشتغل بعد الاتصال بواي فاي الداشكام").font(.system(size: 12)).foregroundStyle(p.sub)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 200)
        .background(p.track.opacity(0.5))
        .card(p, radius: 22)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("AZDOME PG17").font(.system(size: 14, weight: .semibold)).foregroundStyle(p.text)
                Spacer()
                Text(statusText).font(.system(size: 12, weight: .semibold)).foregroundStyle(statusColor)
            }
            Text(help).font(.system(size: 12)).foregroundStyle(p.sub)
            HStack(spacing: 10) {
                if case .connected = cam.state {
                    SecondaryButton(p: p, title: cam.frame == nil ? "شغّل البث" : "أوقف البث", icon: "play.rectangle") {
                        if cam.frame == nil { cam.startLive() } else { cam.stopLive(); cam.frame = nil }
                    }
                } else {
                    SecondaryButton(p: p, title: "إعدادات الواي فاي", icon: "wifi") {
                        if let u = URL(string: UIApplication.openSettingsURLString) { openURL(u) }
                    }
                }
                SecondaryButton(p: p, title: "تحقق الآن", icon: "arrow.clockwise") {
                    Task { await cam.check(preferred: store.data.dashcamHost) }
                }
            }
        }
        .padding(16)
        .card(p, radius: 22)
    }

    private var statusText: String {
        switch cam.state {
        case .idle: return ""
        case .checking: return "جاري التحقق…"
        case .notJoined: return "غير متصل"
        case .connected: return "● متصل"
        case .unsupported: return "طريقة اتصال غير معروفة"
        }
    }

    private var statusColor: Color {
        if case .connected = cam.state { return p.ok }
        if case .unsupported = cam.state { return p.warn }
        return p.sub
    }

    private var help: String {
        switch cam.state {
        case .connected: return "متصل بالداشكام. المقاطع تحت، والعرض على الجوال فقط (أبل تمنع الفيديو على CarPlay)."
        case .unsupported:
            return "الجوال متصل بشبكة الداشكام لكنها ما ردت بطريقة Novatek المعروفة. شغّل «أداة الفحص» من الإعدادات وأرسل التقرير للتحديث الجاي."
        default:
            return "من إعدادات الجوال ← Wi-Fi اختر شبكة AZDOME-PG17 ثم ارجع هنا. شاشة CarPlay ما تتأثر لأنها بالسلك."
        }
    }

    private var clipsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("المقاطع").font(.system(size: 14, weight: .semibold)).foregroundStyle(p.text).padding(.bottom, 6)
            ForEach(cam.clips.prefix(40)) { c in
                Button { playing = c } label: {
                    HStack(spacing: 12) {
                        Image(systemName: c.isEvent ? CarIcon.brake.symbol : "film").foregroundStyle(c.isEvent ? p.warn : p.sub)
                            .frame(width: 26)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.isEvent ? "مقطع حدث (مقفل)" : c.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(p.text).lineLimit(1)
                            Text(c.time).font(.system(size: 12)).foregroundStyle(p.sub)
                        }
                        Spacer()
                        Image(systemName: "play.fill").foregroundStyle(p.text)
                            .frame(width: 44, height: 44).background(p.track, in: Circle())
                    }
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                Divider().overlay(p.border)
            }
        }
        .padding(16)
        .card(p, radius: 22)
    }
}
