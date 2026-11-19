import Foundation
import CoreBluetooth

/// The live connection to the OBD adapter: finds it, reconnects on its own when the truck starts (iOS keeps a
/// pending connection and wakes the app), polls readings, runs the full scan and feeds the alert engine.
@MainActor
final class OBDLink: NSObject, ObservableObject {
    static let shared = OBDLink()

    enum Status: Equatable {
        case bluetoothOff, searching, connecting, connected, paused
        var title: String {
            switch self {
            case .bluetoothOff: return "البلوتوث مطفأ"
            case .searching: return "بانتظار القطعة"
            case .connecting: return "جاري الاتصال"
            case .connected: return "متصل"
            case .paused: return "موقف مؤقتًا"
            }
        }
    }

    @Published private(set) var status: Status = .searching
    @Published private(set) var readings = Readings()
    @Published private(set) var streamActive = false
    @Published private(set) var scanning = false
    @Published private(set) var scanProgress: String = ""
    @Published private(set) var log: [String] = []

    let store: VehicleStore
    let alerts: AlertCenter

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var channel: CBCharacteristic?
    private var lineBuffer = ""
    private var replyBuffer = ""
    private var lastRxAt = Date.distantPast
    private var lastStreamAt = Date.distantPast
    private var lastTickAt: Date?
    private var loopTask: Task<Void, Never>?
    private var scanRequested = false
    private var paused = false

    init(store: VehicleStore = .shared, alerts: AlertCenter = .shared) {
        self.store = store
        self.alerts = alerts
        super.init()
        if OBDLink.isUITesting { loadDemo(); return }
        central = CBCentralManager(delegate: self, queue: .main, options: [
            CBCentralManagerOptionRestoreIdentifierKey: "ra7al.obd.central",
            CBCentralManagerOptionShowPowerAlertKey: true,
        ])
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    static var isUITesting: Bool { ProcessInfo.processInfo.arguments.contains("-uiTesting") }

    /// Screenshot/test mode: real values captured from the F-250 on 19 Nov 2026.
    private func loadDemo() {
        status = .connected
        streamActive = true
        readings = Readings(rpm: 600, speedKmh: 0, coolantC: 61, oilC: 60, loadPercent: 14, mapKPa: 79, intakeC: 20, ambientC: 16,
                            baroKPa: 81, railKPa: 26820, mafGs: 23.86, fuelRateLh: 1.25, fuelLevelPercent: 46.6, batteryV: 14.5,
                            ecuV: 14.44, runTimeS: 815, milOn: false, dtcCount: 0,
                            tires: TireSet(frontLeft: 46, frontRight: 46, rearLeft: 59, rearRight: 55), updatedAt: Date())
        if store.lastScan == nil {
            var r = ScanReport()
            r.vin = "1FT7W2BT4KEE14369"; r.batteryV = 14.5; r.coolantC = 61; r.oilC = 60; r.railKPa = 26820; r.fuelPercent = 46.6
            r.tires = readings.tires
            r.tireSource = "من السيارة"
            r.fuelType = "ديزل Diesel"
            r.modules = FordModuleSpec.all.map { ModuleResult(key: $0.key, responded: $0.key != "ipc", readable: $0.key != "ipc") }
            store.addScan(r)
        }
        if store.data.oil.lastChangeOdometerKm == nil {
            store.data.oil.lastChangeOdometerKm = store.data.oil.odometerKm - 5200
            store.data.oil.lastChangeDate = Date().addingTimeInterval(-86400 * 70)
            store.data.oil.engineHoursSinceChange = 140
            store.data.oil.idleHoursSinceChange = 38
        }
        alerts.evaluate(readings: readings, store: store)
    }

    // MARK: Public controls

    func requestScan() {
        scanRequested = true
        if status != .connected { scanProgress = "يبدأ الفحص أول ما تتصل القطعة" }
    }

    /// Frees the adapter for the probe tool (only one app/connection can talk to it at a time).
    func pause() {
        paused = true
        loopTask?.cancel()
        if let p = peripheral { central?.cancelPeripheralConnection(p) }
        central?.stopScan()
        status = .paused
    }

    func resume() {
        paused = false
        start()
    }

    func forgetAdapter() {
        store.data.peripheralID = nil
        pause()
        resume()
    }

    // MARK: Connection

    private func start() {
        guard central != nil else { return }
        guard !paused, central.state == .poweredOn else {
            if central.state != .poweredOn && central.state != .unknown { status = .bluetoothOff }
            return
        }
        if let p = peripheral, p.state == .connected { return }
        if let id = store.data.peripheralID.flatMap(UUID.init(uuidString:)),
           let known = central.retrievePeripherals(withIdentifiers: [id]).first {
            connect(known)
            return
        }
        let connected = central.retrieveConnectedPeripherals(withServices: [CBUUID(string: OBDProtocol.serviceUUID)])
        if let p = connected.first { connect(p); return }
        status = .searching
        central.scanForPeripherals(withServices: [CBUUID(string: OBDProtocol.serviceUUID)], options: nil)
    }

    private func connect(_ p: CBPeripheral) {
        central.stopScan()
        peripheral = p
        p.delegate = self
        status = .connecting
        // No timeout: iOS keeps this pending and completes it when the truck (adapter) powers up, even in background.
        central.connect(p, options: [CBConnectPeripheralOptionNotifyOnDisconnectionKey: false])
    }

    private func didBecomeReady() {
        status = .connected
        store.data.peripheralID = peripheral?.identifier.uuidString
        add("READY")
        loopTask?.cancel()
        loopTask = Task { [weak self] in await self?.runLoop() }
    }

    // MARK: Command I/O

    private func write(_ cmd: String) {
        guard let p = peripheral, let ch = channel else { return }
        let type: CBCharacteristicWriteType = ch.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        p.writeValue(Data((cmd + "\r").utf8), for: ch, type: type)
    }

    /// Sends one command and waits for its reply. The adapter sends no '>' prompt, so the reply is complete
    /// once data has arrived and the line has been quiet for a moment (each ECU answers within ~30 ms).
    private func send(_ cmd: String, timeout: Double = 2.2) async -> String {
        replyBuffer = ""
        let start = Date()
        write(cmd)
        while Date().timeIntervalSince(start) < timeout {
            try? await Task.sleep(nanoseconds: 60_000_000)
            if Task.isCancelled { return replyBuffer }
            let quiet = Date().timeIntervalSince(lastRxAt)
            let t = replyBuffer.uppercased()
            if t.contains("NULL") && quiet > 0.15 { break }
            if !ProbeLogic.dataLines(replyBuffer).isEmpty && quiet > 0.3 { break }
            if cmd.hasPrefix("AT") && !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && quiet > 0.2 { break }
        }
        return replyBuffer
    }

    private func runLoop() async {
        for c in OBDProtocol.initCommands { _ = await send(c, timeout: c == "ATZ" ? 2.5 : 1.2) }
        await readBattery()
        if store.data.autoScanOnConnect {
            let last = store.lastScan?.date ?? .distantPast
            if Date().timeIntervalSince(last) > 15 * 60 { scanRequested = true }
        }
        var lastSlow = Date.distantPast
        var lastBattery = Date()
        while !Task.isCancelled && status == .connected {
            if scanRequested { scanRequested = false; await runScan() }
            for pid in OBDProtocol.fastPIDs { await poll(pid) }
            if !streamActive { for pid in OBDProtocol.streamFallbackPIDs { await poll(pid) } }
            if Date().timeIntervalSince(lastSlow) > 15 {
                for pid in OBDProtocol.slowPIDs { await poll(pid) }
                lastSlow = Date()
            }
            if Date().timeIntervalSince(lastBattery) > 10 { await readBattery(); lastBattery = Date() }
            alerts.evaluate(readings: readings, store: store)
        }
    }

    private func poll(_ pid: UInt8) async {
        let reply = await send(String(format: "01%02X", pid))
        var r = readings
        if OBDProtocol.apply(pid: pid, reply: reply, to: &r) {
            r.updatedAt = Date()
            readings = r
        }
    }

    private func readBattery() async {
        if let v = OBDProtocol.batteryVolts(fromATRV: await send("ATRV", timeout: 1.2)) { readings.batteryV = v }
    }

    // MARK: Full scan

    private func runScan() async {
        scanning = true
        defer { scanning = false; scanProgress = "" }
        var report = ScanReport()
        func step(_ s: String) { scanProgress = s }

        step("حالة لمبة الأعطال")
        await poll(0x01)
        report.milOn = readings.milOn ?? false
        step("الأكواد المخزنة")
        report.storedDTCs = ProbeLogic.troubleCodes(service: 0x03, in: await send("03"))
        step("الأكواد المعلقة")
        report.pendingDTCs = ProbeLogic.troubleCodes(service: 0x07, in: await send("07"))
        step("الأكواد الدائمة")
        report.permanentDTCs = ProbeLogic.troubleCodes(service: 0x0A, in: await send("0A"))

        step("رقم الهيكل")
        if let v = store.data.vin, VIN.isValid(v) {
            report.vin = v
        } else {
            for _ in 0..<3 {
                if let v = OBDProtocol.validVIN(fromReply: await send("0902", timeout: 3)) { report.vin = v; break }
            }
        }

        step("الحرارة والضغط")
        for pid: UInt8 in [0x05, 0x5C, 0x23, 0x2F] { await poll(pid) }
        await readBattery()

        step("ضغط الكفرات")
        await readTires(into: &report)

        step("كمبيوترات فورد")
        await readModules(into: &report)

        step("العداد وساعات المحرك")
        await readOdometer(into: &report)
        report.fuelType = ProbeLogic.fuelType(fromReply: await send("0151"))

        if !(report.storedDTCs + report.pendingDTCs).isEmpty {
            step("لحظة تسجيل العطل")
            report.freezeFrame = await readFreezeFrame()
        }

        report.batteryV = readings.batteryV
        report.coolantC = readings.coolantC
        report.oilC = readings.oilC
        report.railKPa = readings.railKPa
        report.fuelPercent = readings.fuelLevelPercent
        store.addScan(report)
        alerts.scanFinished(report, store: store)
        add("SCAN done dtc=\(report.allDTCs.count)")
    }

    /// Reads stored/active trouble codes from each Ford module (read-only UDS 0x19), then restores normal addressing.
    private func readModules(into report: inout ScanReport) async {
        var results: [ModuleResult] = []
        for m in FordModuleSpec.all {
            let hdr = await send("ATSH" + m.header, timeout: 1.2)
            guard hdr.uppercased().contains("OK") else {
                results.append(ModuleResult(key: m.key, responded: false, readable: false))
                continue
            }
            let parsed = UDS.parseDTCReply(await send(UDS.readDTCRequest, timeout: 2.5))
            results.append(ModuleResult(key: m.key, responded: parsed.responded, readable: parsed.readable, dtcs: parsed.codes))
            add("MODULE \(m.key) responded=\(parsed.responded) codes=\(parsed.codes.joined(separator: ","))")
        }
        _ = await send("ATSH7DF", timeout: 1.2)
        report.modules = results
    }

    /// Real odometer from the PCM and total engine/idle hours from PID 7F.
    private func readOdometer(into report: inout ScanReport) async {
        if (await send("ATSH7E0", timeout: 1.2)).uppercased().contains("OK") {
            let odo = UDS.fordOdometerKm(await send("22DD01", timeout: 2))
            _ = await send("ATSH7DF", timeout: 1.2)
            if let odo, odo > 1000 {
                report.fordOdometerKm = odo
                let current = store.data.oil.odometerKm
                if odo > current * 0.5 && odo < current * 2 {
                    store.data.oil.odometerKm = odo
                } else {
                    report.notes.append("العداد من كمبيوتر فورد \(Int(odo)) كم يختلف كثير عن المسجل — ما تم اعتماده")
                }
            }
        }
        if let h = UDS.engineHours(await send("017F", timeout: 2)) {
            report.engineHours = h.total
            report.idleHours = h.idle
        }
    }

    private func readFreezeFrame() async -> FreezeFrame? {
        var ff = FreezeFrame()
        if let d = UDS.freezeFrame(0x02, in: await send("020200")), d.count >= 2, (d[0] | d[1]) != 0 { ff.dtc = UDS.dtcString(hi: d[0], lo: d[1]) }
        if let d = UDS.freezeFrame(0x0C, in: await send("020C00")), d.count >= 2 { ff.rpm = Double(Int(d[0]) * 256 + Int(d[1])) / 4 }
        if let d = UDS.freezeFrame(0x0D, in: await send("020D00")) { ff.speedKmh = Double(d[0]) }
        if let d = UDS.freezeFrame(0x05, in: await send("020500")) { ff.coolantC = Double(d[0]) - 40 }
        return ff == FreezeFrame() ? nil : ff
    }

    /// Asks the body module directly (read-only service 0x22), then puts the adapter back to normal addressing.
    private func readTires(into report: inout ScanReport) async {
        let hdr = await send("ATSH" + OBDProtocol.fordBCMHeader, timeout: 1.2)
        guard hdr.uppercased().contains("OK") else { report.notes.append("القطعة ما تدعم توجيه الطلب لوحدة الكفرات"); return }
        var raw: [String: Int] = [:]
        for (did, pos) in OBDProtocol.fordTPMSDIDs {
            if let v = OBDProtocol.fordDIDRaw(did: did, reply: await send("22" + did, timeout: 1.8)) { raw[pos] = v }
        }
        _ = await send("ATSH7DF", timeout: 1.2)
        store.data.lastTPMSRaw = raw
        guard !raw.isEmpty else { report.notes.append("وحدة الكفرات ما ردت"); return }
        let cal = store.data.tpms
        guard cal.confirmed else { report.tireSource = "بانتظار المعايرة"; return }
        func p(_ k: String) -> Double? { raw[k].map { OBDProtocol.psi(raw: $0, scale: cal.scale, offset: cal.offset) } }
        report.tires = TireSet(frontLeft: p("FL"), frontRight: p("FR"), rearLeft: p("RL"), rearRight: p("RR"))
        report.tireSource = "من السيارة"
        readings.tires = report.tires
    }

    // MARK: Per-second bookkeeping

    private func tick() {
        streamActive = Date().timeIntervalSince(lastStreamAt) < 3
        let now = Date()
        defer { lastTickAt = now }
        guard status == .connected, let last = lastTickAt else { return }
        let dt = now.timeIntervalSince(last)
        let speed = readings.speedKmh ?? 0
        store.data.oil.tick(speedKmh: speed, rpm: readings.rpm ?? 0, seconds: dt)
        if let rate = readings.fuelRateLh { store.data.fuel.learn(fuelRateLh: rate, speedKmh: speed, seconds: dt) }
        if let lvl = readings.fuelLevelPercent, let refuel = store.data.fuel.observe(levelPercent: lvl, speedKmh: speed) {
            alerts.refuelDetected(refuel)
        }
    }

    // MARK: Incoming data

    fileprivate func receive(_ data: Data) {
        lastRxAt = Date()
        lineBuffer += String(decoding: data, as: UTF8.self)
        let (lines, rest) = OBDProtocol.takeLines(lineBuffer)
        lineBuffer = rest
        // A stream frame can sit unterminated in the remainder; take it now so readings stay live.
        if let r = lineBuffer.range(of: OBDProtocol.streamPattern, options: .regularExpression) {
            let frame = String(lineBuffer[r]); lineBuffer.removeSubrange(r)
            if let f = OBDProtocol.parseStream(frame) { apply(f) }
        }
        for line in lines {
            let (frames, remainder) = OBDProtocol.extractStream(from: line)
            frames.forEach(apply)
            let t = remainder.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty && !t.hasPrefix(";") { replyBuffer += t + "\n" }
        }
    }

    private func apply(_ f: OBDProtocol.StreamFrame) {
        lastStreamAt = Date()
        var r = readings
        if let v = f.volts { r.batteryV = v }
        if let v = f.rpm { r.rpm = v }
        if let v = f.speedKmh { r.speedKmh = v }
        if let v = f.loadPercent { r.loadPercent = v }
        if let v = f.coolantC { r.coolantC = v }
        if let v = f.fuelLevelPercent, v > 0 { r.fuelLevelPercent = v }
        r.updatedAt = Date()
        readings = r
    }

    private func add(_ s: String) {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        log.append("[\(f.string(from: Date()))] \(s)")
        if log.count > 300 { log.removeFirst(log.count - 300) }
    }

    fileprivate func lost() {
        loopTask?.cancel()
        channel = nil
        streamActive = false
        add("DISCONNECTED")
        if paused { status = .paused; return }
        if let p = peripheral { connect(p) } else { start() }   // re-arm the pending connection
    }

    fileprivate func setChannel(_ ch: CBCharacteristic) { channel = ch }
    fileprivate func noteState() { if central.state == .poweredOn { start() } else if central.state != .unknown { status = .bluetoothOff } }
    fileprivate func restored(_ p: CBPeripheral) { peripheral = p; p.delegate = self }
    fileprivate func discovered(_ p: CBPeripheral) { if !paused { connect(p) } }
}

extension OBDLink: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ c: CBCentralManager) {
        Task { @MainActor in self.noteState() }
    }
    nonisolated func centralManager(_ c: CBCentralManager, willRestoreState dict: [String: Any]) {
        guard let p = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral])?.first else { return }
        Task { @MainActor in self.restored(p) }
    }
    nonisolated func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String: Any], rssi: NSNumber) {
        Task { @MainActor in self.discovered(p) }
    }
    nonisolated func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        p.discoverServices([CBUUID(string: OBDProtocol.serviceUUID)])
    }
    nonisolated func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        Task { @MainActor in self.lost() }
    }
    nonisolated func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        Task { @MainActor in self.lost() }
    }
}

extension OBDLink: CBPeripheralDelegate {
    nonisolated func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard let s = p.services?.first(where: { $0.uuid == CBUUID(string: OBDProtocol.serviceUUID) }) else { return }
        p.discoverCharacteristics([CBUUID(string: OBDProtocol.characteristicUUID)], for: s)
    }
    nonisolated func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        guard let ch = s.characteristics?.first(where: { $0.uuid == CBUUID(string: OBDProtocol.characteristicUUID) }) else { return }
        p.setNotifyValue(true, for: ch)
        Task { @MainActor in self.setChannel(ch) }
    }
    nonisolated func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor ch: CBCharacteristic, error: Error?) {
        guard ch.isNotifying else { return }
        Task { @MainActor in self.didBecomeReady() }
    }
    nonisolated func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        guard let v = ch.value.map({ Data($0) }) else { return }   // copy now: the next packet overwrites it
        Task { @MainActor in self.receive(v) }
    }
}
