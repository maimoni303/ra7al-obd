import Foundation
import CoreBluetooth

struct FoundDevice: Identifiable, Equatable {
    let id: UUID
    var name: String
    var rssi: Int
}

/// Scans, connects, maps every GATT service/characteristic, then sends
/// read-only ELM327/OBD2 requests to each writable characteristic and logs all replies.
@MainActor
final class BLEProbe: NSObject, ObservableObject {
    @Published var devices: [FoundDevice] = []
    @Published var log: [String] = []
    @Published var state: String = "جاهز"
    @Published var isScanning = false
    @Published var isRunning = false
    @Published var summary: [String] = []

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var writable: [CBCharacteristic] = []
    private var lastReplyAt = Date()
    private var replyBuffer = ""
    private var elmCharacteristics: Set<String> = []
    private var pendingServices = 0

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func add(_ s: String) {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"
        log.append("[\(f.string(from: Date()))] \(s)")
    }

    func startScan() {
        guard central.state == .poweredOn else { state = "البلوتوث غير مفعّل"; return }
        devices.removeAll(); peripherals.removeAll()
        isScanning = true; state = "جاري البحث…"
        add("SCAN start")
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        // Also surface adapters already connected to iOS (e.g. paired in Settings).
        let known = central.retrieveConnectedPeripherals(withServices: ProbeLogic.knownSerialServices.map { CBUUID(string: $0) })
        for p in known { register(p, rssi: 0) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in self?.stopScan() }
    }

    func stopScan() {
        guard isScanning else { return }
        central.stopScan(); isScanning = false
        state = devices.isEmpty ? "لم يُعثر على أجهزة" : "اختر القطعة"
        add("SCAN stop, \(devices.count) device(s)")
    }

    private func register(_ p: CBPeripheral, rssi: Int) {
        peripherals[p.identifier] = p
        let name = p.name ?? "(بدون اسم)"
        if let i = devices.firstIndex(where: { $0.id == p.identifier }) {
            devices[i].rssi = rssi; devices[i].name = name
        } else {
            devices.append(FoundDevice(id: p.identifier, name: name, rssi: rssi))
        }
        devices.sort { a, b in
            let ao = a.name.uppercased().contains("OBD"), bo = b.name.uppercased().contains("OBD")
            if ao != bo { return ao }
            return a.rssi > b.rssi
        }
    }

    func connect(_ d: FoundDevice) {
        guard let p = peripherals[d.id] else { return }
        stopScan()
        peripheral = p; p.delegate = self
        writable.removeAll(); elmCharacteristics.removeAll(); summary.removeAll()
        isRunning = true; state = "جاري الاتصال بـ \(d.name)…"
        add("CONNECT \(d.name) id=\(d.id)")
        central.connect(p)
    }

    func disconnect() {
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        isRunning = false
    }

    var reportText: String {
        var out = "RA7AL OBD Probe report\n"
        out += "Device: \(peripheral?.name ?? "-")\n\n== SUMMARY ==\n"
        out += summary.joined(separator: "\n")
        out += "\n\n== LOG ==\n" + log.joined(separator: "\n")
        return out
    }

    // MARK: probe sequence

    private func runProbe() async {
        guard let p = peripheral else { return }
        if writable.isEmpty {
            summary.append("لا توجد قنوات قابلة للكتابة — القطعة تستخدم طريقة خاصة غير معيارية.")
            finish(); return
        }
        // Prefer well-known serial characteristics first.
        let ordered = writable.sorted { a, b in
            let ak = ProbeLogic.knownSerialServices.contains(a.service?.uuid.uuidString ?? "")
            let bk = ProbeLogic.knownSerialServices.contains(b.service?.uuid.uuidString ?? "")
            return ak && !bk
        }
        for ch in ordered {
            let id = "\(ch.service?.uuid.uuidString ?? "?")/\(ch.uuid.uuidString)"
            state = "تجربة القناة \(ch.uuid.uuidString)…"
            add("== PROBE char \(id) props=\(ch.properties.rawValue)")
            var gotELM = false
            for cmd in ProbeLogic.probeCommands {
                let reply = await send(cmd, to: ch, on: p, timeout: cmd == "ATZ" || cmd.hasPrefix("01") || cmd.hasPrefix("09") ? 6 : 2.5)
                if ProbeLogic.looksLikeELM(reply) { gotELM = true }
                if let ft = ProbeLogic.fuelType(fromReply: reply) { summary.append("نوع الوقود: \(ft)") }
                if cmd == "0902", let v = ProbeLogic.vin(fromReply: reply) { summary.append("رقم الهيكل: \(v)") }
                record(cmd: cmd, reply: reply)
                // If reset and echo-off get nothing at all, this char is not an ELM pipe.
                if !gotELM && cmd == "ATE0" && reply.isEmpty { add("no reply on \(id), skipping"); break }
            }
            if gotELM { elmCharacteristics.insert(id) }
        }
        if elmCharacteristics.isEmpty {
            summary.insert("النتيجة: القطعة لم ترد بأوامر ELM327 المعيارية على أي قناة.", at: 0)
        } else {
            summary.insert("النتيجة: القطعة تفهم أوامر ELM327 على: \(elmCharacteristics.sorted().joined(separator: ", "))", at: 0)
        }
        finish()
    }

    /// Turns each reply into readable summary lines.
    private func record(cmd: String, reply: String) {
        let c = cmd.uppercased()
        if c == "ATRV", !reply.isEmpty { summary.append("جهد البطارية: \(reply.trimmingCharacters(in: .whitespacesAndNewlines))") }
        if c == "ATDP", !reply.isEmpty { summary.append("البروتوكول: \(ProbeLogic.stripChatter(reply).trimmingCharacters(in: .whitespacesAndNewlines))") }
        if c.hasPrefix("01"), c.count == 4, let pid = UInt8(c.suffix(2), radix: 16) {
            if pid % 0x20 == 0 {
                let list = ProbeLogic.supportedPIDs(base: pid, in: reply)
                if !list.isEmpty { summary.append("مدعوم \(c): " + list.map { String(format: "%02X", $0) }.joined(separator: " ")) }
            } else if pid != 0x51, let d = ProbeLogic.mode01(pid, in: reply), let txt = ProbeLogic.describe(pid: pid, data: d) {
                summary.append(txt)
            }
        }
        let dtcServices: [String: (UInt8, String)] = ["03": (0x03, "أكواد مخزنة"), "07": (0x07, "أكواد معلقة"), "0A": (0x0A, "أكواد دائمة")]
        if let entry = dtcServices[c] {
            let (svc, label) = entry
            let codes = ProbeLogic.troubleCodes(service: svc, in: reply)
            summary.append("\(label): " + (codes.isEmpty ? "لا يوجد" : codes.joined(separator: ", ")))
        }
    }

    private func finish() {
        state = "انتهى الفحص — شارك التقرير"
        isRunning = false
        add("PROBE done")
    }

    private func send(_ cmd: String, to ch: CBCharacteristic, on p: CBPeripheral, timeout: Double) async -> String {
        replyBuffer = ""
        let data = Data((cmd + "\r").utf8)
        let type: CBCharacteristicWriteType = ch.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        add("TX \(cmd)")
        p.writeValue(data, for: ch, type: type)
        let start = Date(); lastReplyAt = start
        // Wait until prompt '>' arrives, or silence after some data, or timeout.
        while Date().timeIntervalSince(start) < timeout {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if replyBuffer.contains(">") { break }
            // This adapter sends no '>' prompt; wait for silence so every ECU's answer is in.
            if !replyBuffer.isEmpty && Date().timeIntervalSince(lastReplyAt) > 1.2 { break }
        }
        add("RX[\(cmd)] \(replyBuffer.isEmpty ? "(لا رد)" : replyBuffer)")
        return replyBuffer
    }
}

extension BLEProbe: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ c: CBCentralManager) {
        Task { @MainActor in
            add("BT state=\(c.state.rawValue)")
            state = c.state == .poweredOn ? "جاهز — اضغط بحث" : "فعّل البلوتوث واسمح للتطبيق"
        }
    }
    nonisolated func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData ad: [String: Any], rssi: NSNumber) {
        Task { @MainActor in
            let svcs = (ad[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?.map(\.uuidString).joined(separator: ",") ?? ""
            let local = ad[CBAdvertisementDataLocalNameKey] as? String ?? ""
            if p.name?.uppercased().contains("OBD") == true || local.uppercased().contains("OBD") {
                add("FOUND \(p.name ?? local) rssi=\(rssi) adv=[\(svcs)]")
            }
            register(p, rssi: rssi.intValue)
        }
    }
    nonisolated func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        Task { @MainActor in
            add("CONNECTED"); state = "متصل — قراءة القنوات…"
            p.discoverServices(nil)
        }
    }
    nonisolated func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        Task { @MainActor in
            add("CONNECT FAILED \(error?.localizedDescription ?? "")")
            state = "فشل الاتصال — أغلق أي تطبيق آخر متصل بالقطعة"; isRunning = false
        }
    }
    nonisolated func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        Task { @MainActor in add("DISCONNECTED \(error?.localizedDescription ?? "")"); if isRunning { finish() } }
    }
}

extension BLEProbe: CBPeripheralDelegate {
    nonisolated func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            let services = p.services ?? []
            add("SERVICES \(services.count): " + services.map(\.uuid.uuidString).joined(separator: ", "))
            summary.append("الخدمات: " + services.map(\.uuid.uuidString).joined(separator: ", "))
            pendingServices = services.count
            if services.isEmpty { await runProbe() }
            for s in services { p.discoverCharacteristics(nil, for: s) }
        }
    }
    nonisolated func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        Task { @MainActor in
            for ch in s.characteristics ?? [] {
                let props = describe(ch.properties)
                add("CHAR \(s.uuid.uuidString)/\(ch.uuid.uuidString) [\(props)]")
                summary.append("قناة \(s.uuid.uuidString)/\(ch.uuid.uuidString) [\(props)]")
                if ch.properties.contains(.notify) || ch.properties.contains(.indicate) { p.setNotifyValue(true, for: ch) }
                if ch.properties.contains(.read) { p.readValue(for: ch) }
                if ch.properties.contains(.write) || ch.properties.contains(.writeWithoutResponse) { writable.append(ch) }
            }
            pendingServices -= 1
            if pendingServices == 0 {
                // Give notifications a moment to subscribe and capture any unsolicited stream.
                state = "استماع لأي بث تلقائي من القطعة…"
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                await runProbe()
            }
        }
    }
    nonisolated func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        // Copy the bytes now: ch.value is overwritten by the next notification before the Task runs.
        guard let v = ch.value.map({ Data($0) }) else { return }
        Task { @MainActor in
            let text = String(decoding: v, as: UTF8.self)
            replyBuffer += text; lastReplyAt = Date()
            add("VAL \(ch.uuid.uuidString) hex=\(ProbeLogic.hex(v)) ascii=\(ProbeLogic.ascii(v))")
        }
    }
    nonisolated func peripheral(_ p: CBPeripheral, didWriteValueFor ch: CBCharacteristic, error: Error?) {
        Task { @MainActor in if let e = error { add("WRITE ERR \(ch.uuid.uuidString): \(e.localizedDescription)") } }
    }
}

extension BLEProbe {
    fileprivate func describe(_ p: CBCharacteristicProperties) -> String {
        var a: [String] = []
        if p.contains(.read) { a.append("read") }
        if p.contains(.write) { a.append("write") }
        if p.contains(.writeWithoutResponse) { a.append("writeNR") }
        if p.contains(.notify) { a.append("notify") }
        if p.contains(.indicate) { a.append("indicate") }
        return a.joined(separator: ",")
    }
}
