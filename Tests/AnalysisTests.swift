import XCTest
@testable import RA7ALOBD

final class AnalysisTests: XCTestCase {
    // MARK: Code library
    func testKnownAndNumberedCodes() {
        let i = DTCKnowledge.info("p0299")
        XCTAssertEqual(i.code, "P0299")
        XCTAssertEqual(i.drive, .caution)
        XCTAssertFalse(i.generic)
        XCTAssertEqual(DTCKnowledge.info("P0524").drive, .stop)
        XCTAssertEqual(DTCKnowledge.info("P0303").title, "تقطيع في السلندر 3")
        XCTAssertEqual(DTCKnowledge.info("P0675").drive, .safe)
        XCTAssertTrue(DTCKnowledge.all.count > 70)
        XCTAssertEqual(Set(DTCKnowledge.all.map(\.code)).count, DTCKnowledge.all.count)
    }
    func testGenericFallback() {
        let t = DTCKnowledge.info("P0761")
        XCTAssertTrue(t.generic)
        XCTAssertTrue(t.title.contains("القير"))
        XCTAssertTrue(DTCKnowledge.info("B0012").title.contains("الإيرباق"))
        XCTAssertEqual(DTCKnowledge.info("B1318").drive, .safe)
        XCTAssertTrue(DTCKnowledge.info("P1450").title.contains("فورد"))
        XCTAssertNil(DTCKnowledge.normalize("X1234"))
        XCTAssertEqual(DTCKnowledge.normalize(" p 0087 "), "P0087")
    }

    // MARK: UDS replies
    func testModuleDTCParsing() {
        // ABS with C0035 confirmed (status 0x08) and one history entry with status 0x00 (ignored).
        let r = UDS.parseDTCReply("ECU:1  CMD:19028F  CNT:1\r\n00B\r\n0: 59 02 FF 40 35 00\r\n1: 08 41 22 00 00 00 00\r\n")
        XCTAssertTrue(r.responded)
        XCTAssertTrue(r.readable)
        XCTAssertEqual(r.codes, ["C0035"])
        let none = UDS.parseDTCReply("59 02 FF\n")
        XCTAssertEqual(none.codes, [])
        XCTAssertTrue(none.readable)
        let refused = UDS.parseDTCReply("7F 19 11\n")
        XCTAssertTrue(refused.responded)
        XCTAssertFalse(refused.readable)
        let silent = UDS.parseDTCReply("CMD:19028F NULL\n")
        XCTAssertFalse(silent.responded)
    }
    func testOdometerHoursFreezeFrame() {
        XCTAssertEqual(UDS.fordOdometerKm("62 DD 01 01 83 75\n"), 99189)
        XCTAssertNil(UDS.fordOdometerKm("7F 22 31\n"))
        let h = UDS.engineHours("41 7F 07 00 5B 8D 80 00 1A 5E 00 00 00 00 00\n")
        XCTAssertEqual(h?.total ?? 0, Double(0x005B8D80) / 3600, accuracy: 0.01)
        XCTAssertEqual(h?.idle ?? 0, Double(0x001A5E00) / 3600, accuracy: 0.01)
        XCTAssertEqual(UDS.freezeFrame(0x0C, in: "42 0C 00 21 98\n"), [0x21, 0x98])
        XCTAssertEqual(UDS.dtcString(hi: 0x02, lo: 0x99), "P0299")
    }

    // MARK: VIN decoding
    func testDecodeRealVIN() {
        let id = VehicleIdentity.decode("1FT7W2BT4KEE14369")
        XCTAssertEqual(id?.make, "Ford")
        XCTAssertEqual(id?.model, "F-250 Super Duty")
        XCTAssertEqual(id?.year, 2019)
        XCTAssertEqual(id?.engine, "6.7L Power Stroke V8 ديزل")
        XCTAssertEqual(id?.plant, "Kentucky Truck")
        XCTAssertEqual(id?.displayName, "Ford F-250 Super Duty 2019")
    }

    // MARK: Verdict
    private func modules(_ abs: [String] = []) -> [ModuleResult] {
        FordModuleSpec.all.map { ModuleResult(key: $0.key, responded: $0.key != "ipc", readable: $0.key != "ipc", dtcs: $0.key == "abs" ? abs : []) }
    }
    func testHealthyVerdict() {
        var r = ScanReport()
        r.batteryV = 14.4; r.coolantC = 61; r.modules = modules()
        r.tires = TireSet(frontLeft: 62, frontRight: 62, rearLeft: 76, rearRight: 76)
        var d = AppData(); d.oil.recordChange()
        let v = ScanVerdict.evaluate(r, data: d)
        XCTAssertEqual(v.drive, .safe)
        XCTAssertEqual(v.urgency, .none)
        XCTAssertEqual(v.confidence, .high)
        XCTAssertEqual(v.sections.count, 9)
        XCTAssertEqual(v.sections.first { $0.kind == .cluster }?.status, .unavailable)
        XCTAssertEqual(v.headline, "تقدر تسوق بأمان")
    }
    func testCautionAndStop() {
        var r = ScanReport()
        r.storedDTCs = ["P0299"]; r.modules = modules(["C0035"])
        var v = ScanVerdict.evaluate(r, data: AppData())
        XCTAssertEqual(v.drive, .caution)
        XCTAssertEqual(v.urgency, .soon)
        XCTAssertEqual(v.sections.first { $0.kind == .abs }?.status, .warn)
        XCTAssertEqual(v.sections.first { $0.kind == .engine }?.codes, ["P0299"])
        XCTAssertEqual(Set(r.allDTCs), ["P0299", "C0035"])
        r.coolantC = 118
        v = ScanVerdict.evaluate(r, data: AppData())
        XCTAssertEqual(v.drive, .stop)
        XCTAssertEqual(v.urgency, .now)
        r.coolantC = 80; r.storedDTCs = ["P0868"]
        v = ScanVerdict.evaluate(r, data: AppData())
        XCTAssertEqual(v.drive, .stop)
        XCTAssertEqual(v.sections.first { $0.kind == .transmission }?.status, .danger)
    }
    func testNoModulesLowersConfidence() {
        let v = ScanVerdict.evaluate(ScanReport(), data: AppData())
        XCTAssertEqual(v.confidence, .low)
        XCTAssertEqual(v.drive, .safe)
    }
    func testOldSavedScansStillDecode() throws {
        // A 1.0.1 scan has none of the new keys.
        let old = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","date":0,"storedDTCs":[],"pendingDTCs":[],"permanentDTCs":[],"milOn":false,"tires":{},"notes":[]}"#
        let r = try JSONDecoder().decode(ScanReport.self, from: Data(old.utf8))
        XCTAssertNil(r.modules)
        XCTAssertTrue(r.allDTCs.isEmpty)
    }
}
