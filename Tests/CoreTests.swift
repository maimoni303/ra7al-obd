import XCTest
@testable import RA7ALOBD

final class CoreTests: XCTestCase {
    // MARK: VIN
    func testRealVINIsValid() {
        XCTAssertTrue(VIN.isValid("1FT7W2BT4KEE14369"))
        XCTAssertEqual(VIN.year("1FT7W2BT4KEE14369"), 2019)
    }
    func testBrokenVINRejected() {
        XCTAssertFalse(VIN.isValid("1FT7W2BT5KEE14369"))   // wrong check digit
        XCTAssertFalse(VIN.isValid("14KEE14369FT2FU2F"))   // the garbled read from probe v0.2
        XCTAssertFalse(VIN.isValid("1FT7W2BT4KEE1436"))
    }
    func testVINFromReplyNeedsCheckDigit() {
        let good = "ECU:1  CMD:0902  CNT:20\r\n0: 49 02 01 31 46 54\r\n1: 37 57 32 42 54 34 4B\r\n2: 45 45 31 34 33 36 39\r\n"
        XCTAssertEqual(OBDProtocol.validVIN(fromReply: good), "1FT7W2BT4KEE14369")
        let lost = "CNT:20\r\n49 02 01 31  34 4B 45 45 31 34 33 36 39 \r\n"
        XCTAssertNil(OBDProtocol.validVIN(fromReply: lost))
    }

    // MARK: Stream
    func testParseStreamFrame() {
        let f = OBDProtocol.parseStream("BD$V14.5;R00600;S000;P000.0;O014.1;C060;L046.6;XH008.072;M000000;F001.524;T0000680;A00;B00;D00;U32.5;GX-3;GY-27;GZ-65;@2")
        XCTAssertEqual(f?.volts, 14.5); XCTAssertEqual(f?.rpm, 600); XCTAssertEqual(f?.speedKmh, 0)
        XCTAssertEqual(f?.loadPercent, 14.1); XCTAssertEqual(f?.coolantC, 60); XCTAssertEqual(f?.fuelLevelPercent, 46.6)
        XCTAssertEqual(f?.tripSeconds, 680)
        XCTAssertEqual(f?.accel?.z ?? 0, -65.0 / 64, accuracy: 0.001)
    }
    func testExtractStreamLeavesReply() {
        let line = "BD$V14.5;R00597;S000;P000.0;O014.1;C061;L046.6;XH008.099;M000000;F001.759;T0000784;A00;B00;D00;U32.5;GX-4;GY-15;GZ-63;@2011F"
        let (frames, rest) = OBDProtocol.extractStream(from: line)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames.first?.rpm, 597)
        XCTAssertEqual(rest, "011F")
    }
    func testTakeLinesKeepsRemainder() {
        let (lines, rest) = OBDProtocol.takeLines("41 05 65 \r\n\r\nECU:2  CMD:0105  CNT:")
        XCTAssertEqual(lines, ["41 05 65 "])
        XCTAssertEqual(rest, "ECU:2  CMD:0105  CNT:")
    }

    // MARK: PIDs (replies captured from the truck)
    func testApplyPIDs() {
        var r = Readings()
        XCTAssertTrue(OBDProtocol.apply(pid: 0x5E, reply: "ECU:1  CMD:015e  CNT:4\n41 5E 00 19\n", to: &r))
        XCTAssertEqual(r.fuelRateLh ?? 0, 1.25, accuracy: 0.001)
        OBDProtocol.apply(pid: 0x23, reply: "41 23 0A 7A\n", to: &r); XCTAssertEqual(r.railKPa, 26820)
        OBDProtocol.apply(pid: 0x5C, reply: "41 5C 64\n", to: &r); XCTAssertEqual(r.oilC, 60)
        OBDProtocol.apply(pid: 0x0C, reply: "41 0C 09 5C\n", to: &r); XCTAssertEqual(r.rpm, 599)
        OBDProtocol.apply(pid: 0x01, reply: "41 01 00 0E 00 00\n", to: &r); XCTAssertEqual(r.milOn, false); XCTAssertEqual(r.dtcCount, 0)
        OBDProtocol.apply(pid: 0x42, reply: "41 42 38 68\n", to: &r); XCTAssertEqual(r.ecuV ?? 0, 14.44, accuracy: 0.001)
        XCTAssertFalse(OBDProtocol.apply(pid: 0x05, reply: "CMD:0105 NULL\n", to: &r))
    }
    func testBatteryFromATRV() {
        XCTAssertEqual(OBDProtocol.batteryVolts(fromATRV: "14.5V\n"), 14.5)
        XCTAssertNil(OBDProtocol.batteryVolts(fromATRV: "OK"))
    }
    func testFordDIDRaw() {
        XCTAssertEqual(OBDProtocol.fordDIDRaw(did: "2813", reply: "62 28 13 03 98\n"), 0x0398)
        XCTAssertNil(OBDProtocol.fordDIDRaw(did: "2813", reply: "7F 22 31\n"))
    }
    func testTPMSCalibrationFindsScale() {
        // Dash showed 46/46/59/55 psi; raw values as a 1/20-psi encoding would be 920/920/1180/1100.
        let cal = TPMSCalibration.fit(raw: [920, 920, 1180, 1100], dash: [46, 46, 59, 55])
        XCTAssertEqual(cal?.scale ?? 0, 0.05, accuracy: 0.0001)
        XCTAssertEqual(cal?.confirmed, true)
        XCTAssertEqual(TPMSCalibration.fit(raw: [1, 2], dash: [46, 46])?.confirmed, false)
    }

    func testTiresDecodeWithoutCalibration() {
        // Common Ford encoding ((A*256+B)/3 + 22/3) kPa: 930 ≈ 46 psi, 1200 ≈ 59 psi.
        let a = OBDProtocol.decodeTires(raw: ["FL": 930, "FR": 930, "RL": 1200, "RR": 1118], calibration: TPMSCalibration())
        XCTAssertEqual(a?.method, "kPa/3")
        XCTAssertEqual(a?.tires.frontLeft ?? 0, 46, accuracy: 1)
        XCTAssertEqual(a?.tires.rearLeft ?? 0, 59, accuracy: 1)
        // Plain kPa values must not be read as the /3 encoding.
        let b = OBDProtocol.decodeTires(raw: ["FL": 317, "FR": 317, "RL": 407, "RR": 379], calibration: TPMSCalibration())
        XCTAssertEqual(b?.method, "kPa")
        XCTAssertEqual(b?.tires.frontRight ?? 0, 46, accuracy: 1)
        // One flat tyre still decodes and shows near zero.
        let c = OBDProtocol.decodeTires(raw: ["FL": 930, "FR": 0, "RL": 1200, "RR": 1118], calibration: TPMSCalibration())
        XCTAssertEqual(c?.method, "kPa/3")
        XCTAssertEqual(c?.tires.frontRight ?? -1, 1.1, accuracy: 0.2)
        // A learned calibration wins.
        let cal = TPMSCalibration(scale: 0.1, offset: 0, confirmed: true)
        XCTAssertEqual(OBDProtocol.decodeTires(raw: ["FL": 460], calibration: cal)?.tires.frontLeft, 46)
        // Garbage gives nothing.
        XCTAssertNil(OBDProtocol.decodeTires(raw: ["FL": 65535, "FR": 65535], calibration: TPMSCalibration()))
        XCTAssertNil(OBDProtocol.decodeTires(raw: [:], calibration: TPMSCalibration()))
    }

    func testTireReplyInAdapterFormat() {
        // This adapter prints a header line per ECU before the data.
        let reply = "ECU:1  CMD:222813  CNT:1\r\n62 28 13 03 A2\r\n"
        XCTAssertEqual(OBDProtocol.fordDIDRaw(did: "2813", reply: reply), 0x03A2)
        XCTAssertNil(OBDProtocol.fordDIDRaw(did: "2813", reply: "CMD:222813 NULL\r\n"))
    }

    func testDIDRequestFormatsAndRefusals() {
        let f = OBDProtocol.didRequestFormats.map { $0.make("2813") }
        XCTAssertEqual(f, ["222813", "22 28 13", "03222813", "22281300", "2228130000"])
        // Real reply from the F-250 through the ZUS adapter: two ECUs said "wrong length".
        let reply = "7F 22 13\r\n7F 22 13\r\n"
        XCTAssertEqual(OBDProtocol.negativeCodes(service: 0x22, in: reply), [0x13, 0x13])
        XCTAssertNil(OBDProtocol.fordDIDRaw(did: "2813", reply: reply))
        XCTAssertEqual(OBDProtocol.negativeText(0x13), "طول الطلب غير مقبول")
        XCTAssertEqual(OBDProtocol.negativeCodes(service: 0x22, in: "62 28 13 03 A2"), [])
    }

    func testAdapterRefusalDetection() {
        XCTAssertTrue(OBDProtocol.refused("?\r\n"))
        XCTAssertTrue(OBDProtocol.refused("ERROR"))
        XCTAssertFalse(OBDProtocol.refused("OK\r\n"))
        XCTAssertFalse(OBDProtocol.refused(""))          // silence is not a refusal on this adapter
        XCTAssertFalse(OBDProtocol.refused("BD$V14.5;R00600;S000;@1"))
    }

    // MARK: Models
    func testLimits() {
        let l = Limits()
        XCTAssertEqual(l.coolantLevel(92), .ok); XCTAssertEqual(l.coolantLevel(110), .warn); XCTAssertEqual(l.coolantLevel(118), .danger)
        XCTAssertEqual(l.tireLevel(psi: 46, front: true), .warn)      // 46 of 60 → 77 %
        XCTAssertEqual(l.tireLevel(psi: 40, front: true), .danger)
        XCTAssertEqual(l.tireLevel(psi: 59, front: false), .warn)     // 59 of 75
        XCTAssertEqual(l.tireLevel(psi: 74, front: false), .ok)
        XCTAssertEqual(l.voltageLevel(14.5, engineRunning: true), .ok)
        XCTAssertEqual(l.voltageLevel(12.6, engineRunning: true), .warn)
    }
    func testFuelRangeAndLearning() {
        var f = FuelModel()
        XCTAssertEqual(f.litersLeft(levelPercent: 46.6), 60.1, accuracy: 0.1)
        XCTAssertEqual(f.rangeKm(levelPercent: 46.6) ?? 0, 60.114 / 14 * 100, accuracy: 0.5)
        for _ in 0..<20000 { f.learn(fuelRateLh: 12, speedKmh: 100, seconds: 1) }   // ~555 km at 12 L/100 km
        XCTAssertEqual(f.avgLper100, 12, accuracy: 0.3)
        f.learn(fuelRateLh: 1.25, speedKmh: 0, seconds: 1)                       // idling doesn't change the average
        XCTAssertEqual(f.avgLper100, 12, accuracy: 0.3)
    }
    func testRefuelDetection() {
        var f = FuelModel()
        XCTAssertNil(f.observe(levelPercent: 20, speedKmh: 0))
        XCTAssertNil(f.observe(levelPercent: 21, speedKmh: 0))
        let r = f.observe(levelPercent: 95, speedKmh: 0)
        XCTAssertNotNil(r)
        XCTAssertEqual(r?.liters ?? 0, 74 / 100 * 129, accuracy: 0.5)
    }
    func testOilLife() {
        var o = OilModel()
        XCTAssertNil(o.lifePercent())
        o.recordChange()
        XCTAssertEqual(o.lifePercent() ?? 0, 100, accuracy: 0.01)
        for _ in 0..<3600 { o.tick(speedKmh: 100, rpm: 1600, seconds: 1) }        // 100 km, 1 h
        XCTAssertEqual(o.kmSinceChange ?? 0, 100, accuracy: 0.1)
        XCTAssertEqual(o.lifePercent() ?? 0, 98.75, accuracy: 0.1)
        for _ in 0..<3600 { o.tick(speedKmh: 0, rpm: 650, seconds: 1) }          // 1 h idling = +50 km wear
        XCTAssertEqual(o.lifePercent() ?? 0, 100 - 150.0 / 8000 * 100, accuracy: 0.1)
        o.fordOilLifePercent = 40
        XCTAssertEqual(o.lifePercent(), 40)
    }
    func testAlertsFromRealTires() {
        var d = AppData()
        d.fuel.tankLiters = 129
        var r = Readings()
        r.tires = TireSet(frontLeft: 46, frontRight: 46, rearLeft: 59, rearRight: 55)
        r.fuelLevelPercent = 46.6
        r.coolantC = 61
        let a = AlertCenter.alerts(for: r, data: d)
        XCTAssertEqual(a.map(\.kind), [.tires])
        r.coolantC = 116
        XCTAssertEqual(AlertCenter.alerts(for: r, data: d).first?.kind, .coolant)
        XCTAssertEqual(AlertCenter.alerts(for: r, data: d).first?.level, .danger)
    }
    func testScanScore() {
        var s = ScanReport()
        XCTAssertEqual(s.score(limits: Limits()), 100)
        s.storedDTCs = ["P0087"]; s.milOn = true
        XCTAssertEqual(s.score(limits: Limits()), 65)
        XCTAssertFalse(s.healthy)
        XCTAssertEqual(DTCText.describe("P0087"), "ضغط سكة الديزل منخفض")
    }

    // MARK: Dashcam
    func testNovatekParsing() {
        XCTAssertTrue(DashcamClient.isNovatekOK("<?xml version=\"1.0\"?><Function><Cmd>3016</Cmd><Status>0</Status></Function>"))
        XCTAssertFalse(DashcamClient.isNovatekOK("<html>hello</html>"))
        let xml = """
        <LIST><ALLFile><File><NAME>2026_1119_074200_F.MP4</NAME><FPATH>A:\\CARDV\\MOVIE\\2026_1119_074200_F.MP4</FPATH><SIZE>1</SIZE><TIME>2026/11/19 07:42:00</TIME></File></ALLFile>
        <ALLFile><File><NAME>2026_1119_080000_F.MP4</NAME><FPATH>A:\\CARDV\\EMR\\2026_1119_080000_F.MP4</FPATH><TIME>2026/11/19 08:00:00</TIME></File></ALLFile></LIST>
        """
        let clips = DashcamClient.parseFileList(xml, host: "192.168.1.254")
        XCTAssertEqual(clips.count, 2)
        XCTAssertEqual(clips.first?.url.absoluteString, "http://192.168.1.254/CARDV/EMR/2026_1119_080000_F.MP4")
        XCTAssertEqual(clips.first?.isEvent, true)
        XCTAssertEqual(clips.last?.isEvent, false)
    }

    // MARK: CarPlay drawing
    func testGaugeImageRenders() {
        let img = GaugeImage.render(icon: .coolant, value: "92°", fraction: 0.6, level: .ok, dark: true)
        XCTAssertEqual(img.size, CGSize(width: 90, height: 90))
        XCTAssertNotEqual(CarIcon.coolant.symbol, "")
    }

    // MARK: Persistence
    @MainActor
    func testStoreRoundTrip() {
        let suite = UserDefaults(suiteName: "ra7al.tests.\(UUID().uuidString)")!
        let s1 = VehicleStore(defaults: suite)
        s1.data.fuel.tankLiters = 182
        s1.data.theme = .youth
        let s2 = VehicleStore(defaults: suite)
        XCTAssertEqual(s2.data.fuel.tankLiters, 182)
        XCTAssertEqual(s2.data.theme, .youth)
    }
}
