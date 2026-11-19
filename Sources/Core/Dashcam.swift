import Foundation
import UIKit

/// AZDOME PG17 (Novatek) over its own Wi-Fi. AZDOME publishes no API, so the app probes the common Novatek
/// endpoints and reports exactly what works on this unit.
@MainActor
final class DashcamClient: ObservableObject {
    static let shared = DashcamClient()

    struct Clip: Identifiable, Equatable {
        var name: String
        var url: URL
        var time: String
        var isEvent: Bool
        var id: String { url.absoluteString }
    }

    enum State: Equatable { case idle, checking, notJoined, connected(String), unsupported }

    @Published private(set) var state: State = .idle
    @Published private(set) var clips: [Clip] = []
    @Published var frame: UIImage?

    static let candidateHosts = ["192.168.1.254", "192.168.169.1", "192.168.0.1", "192.72.1.1"]
    private var host: String?
    private var stream: MJPEGStream?

    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 2.5
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    func check(preferred: String?) async {
        state = .checking
        var hosts = DashcamClient.candidateHosts
        if let p = preferred { hosts.removeAll { $0 == p }; hosts.insert(p, at: 0) }
        for h in hosts {
            if let ok = try? await heartbeat(h), ok {
                host = h
                state = .connected(h)
                VehicleStore.shared.data.dashcamHost = h
                await loadClips()
                return
            }
        }
        // Reachable network but nothing Novatek-like answered vs. not on its Wi-Fi at all.
        state = await anyHostReachable(hosts) ? .unsupported : .notJoined
    }

    private func heartbeat(_ h: String) async throws -> Bool {
        let (data, resp) = try await session.data(from: URL(string: "http://\(h)/?custom=1&cmd=3016")!)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return false }
        return DashcamClient.isNovatekOK(String(decoding: data, as: UTF8.self))
    }

    private func anyHostReachable(_ hosts: [String]) async -> Bool {
        for h in hosts {
            if case let (_, r)? = try? await session.data(from: URL(string: "http://\(h)/")!), r is HTTPURLResponse { return true }
        }
        return false
    }

    func loadClips() async {
        guard let h = host,
              case let (data, _)? = try? await session.data(from: URL(string: "http://\(h)/?custom=1&cmd=3015")!) else { return }
        clips = DashcamClient.parseFileList(String(decoding: data, as: UTF8.self), host: h)
    }

    func startLive() {
        guard let h = host else { return }
        stream?.stop()
        // Novatek units need movie mode with live view on before the MJPEG port serves frames.
        Task {
            _ = try? await session.data(from: URL(string: "http://\(h)/?custom=1&cmd=3001&par=1")!)
            let s = MJPEGStream(url: URL(string: "http://\(h):8192")!) { [weak self] img in
                Task { @MainActor in self?.frame = img }
            }
            stream = s
            s.start()
        }
    }

    func stopLive() { stream?.stop(); stream = nil }

    // MARK: Pure helpers (tested)

    nonisolated static func isNovatekOK(_ xml: String) -> Bool {
        xml.contains("<Function>") && xml.range(of: #"<Status>\s*0\s*</Status>"#, options: .regularExpression) != nil
    }

    /// `<File><NAME>2026_1119_074200_F.MP4</NAME><FPATH>A:\CARDV\MOVIE\2026_1119_074200_F.MP4</FPATH>…<TIME>2026/11/19 07:42:00</TIME></File>`
    nonisolated static func parseFileList(_ xml: String, host: String) -> [Clip] {
        var out: [Clip] = []
        let files = xml.components(separatedBy: "<File>").dropFirst()
        for f in files {
            func tag(_ t: String) -> String? {
                guard let a = f.range(of: "<\(t)>"), let b = f.range(of: "</\(t)>", range: a.upperBound..<f.endIndex) else { return nil }
                return String(f[a.upperBound..<b.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard let name = tag("NAME"), let path = tag("FPATH") else { continue }
            var p = path.replacingOccurrences(of: "\\", with: "/")
            if let colon = p.firstIndex(of: ":") { p = String(p[p.index(after: colon)...]) }
            if !p.hasPrefix("/") { p = "/" + p }
            guard let enc = p.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                  let url = URL(string: "http://\(host)\(enc)") else { continue }
            let upper = p.uppercased()
            out.append(Clip(name: name, url: url, time: tag("TIME") ?? "",
                            isEvent: upper.contains("/EMR") || upper.contains("EVENT") || upper.contains("/RO/") || upper.contains("LOCK")))
        }
        return out.sorted { $0.time > $1.time }
    }
}

/// Minimal MJPEG reader: splits the byte stream on JPEG start/end markers.
final class MJPEGStream: NSObject, URLSessionDataDelegate {
    private let url: URL
    private let onFrame: (UIImage) -> Void
    private var buffer = Data()
    private var task: URLSessionDataTask?
    private var session: URLSession?

    init(url: URL, onFrame: @escaping (UIImage) -> Void) {
        self.url = url
        self.onFrame = onFrame
    }

    func start() {
        let s = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        session = s
        task = s.dataTask(with: url)
        task?.resume()
    }

    func stop() { task?.cancel(); session?.invalidateAndCancel(); buffer.removeAll() }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        buffer.append(data)
        while let start = buffer.firstRange(of: Data([0xFF, 0xD8])),
              let end = buffer.firstRange(of: Data([0xFF, 0xD9]), in: start.upperBound..<buffer.endIndex) {
            let jpeg = buffer.subdata(in: start.lowerBound..<end.upperBound)
            buffer.removeSubrange(buffer.startIndex..<end.upperBound)
            if let img = UIImage(data: jpeg) { onFrame(img) }
        }
        if buffer.count > 4_000_000 { buffer.removeAll() }
    }
}
