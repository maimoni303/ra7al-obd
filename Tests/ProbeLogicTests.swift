import XCTest
@testable import RA7ALOBDProbe

final class ProbeLogicTests: XCTestCase {
    func testHexAndAscii() {
        let d = Data([0x41, 0x0D, 0x3E, 0x01])
        XCTAssertEqual(ProbeLogic.hex(d), "41 0D 3E 01")
        XCTAssertEqual(ProbeLogic.ascii(d), "A\\r>·")
    }

    func testLooksLikeELM() {
        XCTAssertTrue(ProbeLogic.looksLikeELM("ELM327 v1.5\r\r>"))
        XCTAssertTrue(ProbeLogic.looksLikeELM("41 00 BE 3F A8 13\r>"))
        XCTAssertTrue(ProbeLogic.looksLikeELM("SEARCHING...\rUNABLE TO CONNECT"))
        XCTAssertFalse(ProbeLogic.looksLikeELM(""))
        XCTAssertFalse(ProbeLogic.looksLikeELM("\u{01}\u{02}"))
    }

    func testFuelTypeDiesel() {
        XCTAssertEqual(ProbeLogic.fuelType(fromReply: "41 51 04\r>"), "ديزل Diesel")
        XCTAssertEqual(ProbeLogic.fuelType(fromReply: "415101"), "بنزين Gasoline")
        XCTAssertNil(ProbeLogic.fuelType(fromReply: "NO DATA"))
    }

    func testVINFromCANMultiFrame() {
        let reply = "014\r0: 49 02 01 31 46 54\r1: 37 57 32 42 54 34 4B\r2: 45 44 31 32 33 34 35\r>"
        XCTAssertEqual(ProbeLogic.vin(fromReply: reply), "1FT7W2BT4KED12345")
    }

    func testVINAbsent() {
        XCTAssertNil(ProbeLogic.vin(fromReply: "NO DATA\r>"))
    }

    func testProbeCommandsAreReadOnly() {
        // No clear-DTC (04) or any write/actuation service may ever be sent by the probe.
        for c in ProbeLogic.probeCommands {
            XCTAssertFalse(c == "04" || c.hasPrefix("04"), "probe must not clear codes")
            XCTAssertFalse(c.hasPrefix("2E") || c.hasPrefix("2F") || c.hasPrefix("31") || c.hasPrefix("3B"))
        }
    }

    // Real replies captured from the ZUS/NONDA "OBDBLE" adapter on the F-250 (19/11/2026).
    func testNondaFormatRPMCoolantSpeed() {
        let rpm = "\r\nECU:1  CMD:010c  CNT:4\r\n41 0C 0A 08 \r\n"
        XCTAssertEqual(ProbeLogic.mode01(0x0C, in: rpm), [0x0A, 0x08])
        XCTAssertEqual(ProbeLogic.describe(pid: 0x0C, data: [0x0A, 0x08]), "دورات المحرك: 642 rpm")
        let ect = "\r\nECU:1  CMD:0105  CNT:3\r\n41 05 45 \r\n"
        XCTAssertEqual(ProbeLogic.describe(pid: 0x05, data: ProbeLogic.mode01(0x05, in: ect)!), "حرارة الماء: 29°C")
        let fuel = "\r\nECU:1  CMD:0151  CNT:3\r\n41 51 04 \r\n"
        XCTAssertEqual(ProbeLogic.fuelType(fromReply: fuel), "ديزل Diesel")
        XCTAssertEqual(ProbeLogic.mode01(0x0D, in: "Connected 2ECU@6Z\r\n\r\nECU:1  CMD:010d  CNT:3\r\n41 0D 00 \r\n"), [0x00])
    }

    func testHeaderLineIsNotData() {
        XCTAssertTrue(ProbeLogic.dataLines("ECU:1  CMD:0100  CNT:6\r\nConnected 2ECU@6Z\r\n").isEmpty)
        XCTAssertTrue(ProbeLogic.dataLines("ELM327 v1.5\r\nOK\r\n14.5V\r\n").isEmpty)
    }

    func testSupportedPIDsUnionOfTwoECUs() {
        let r = "ECU:1  CMD:0100  CNT:6\r\n41 00 98 1B 80 13\r\nECU:2  CMD:0100  CNT:6\r\n41 00 80 00 00 01\r\n"
        let pids = ProbeLogic.supportedPIDs(base: 0x00, in: r)
        XCTAssertTrue(pids.contains(0x01)); XCTAssertTrue(pids.contains(0x04)); XCTAssertTrue(pids.contains(0x05))
        XCTAssertTrue(pids.contains(0x0C)); XCTAssertTrue(pids.contains(0x0D)); XCTAssertTrue(pids.contains(0x20))
        XCTAssertFalse(pids.contains(0x02))
    }

    func testMILStatus() {
        XCTAssertEqual(ProbeLogic.describe(pid: 0x01, data: [0x82, 0x07, 0x65, 0x00]), "لمبة الأعطال: مضاءة — عدد الأكواد: 2")
        XCTAssertEqual(ProbeLogic.describe(pid: 0x01, data: [0x00, 0x04, 0x00, 0x00]), "لمبة الأعطال: مطفأة — عدد الأكواد: 0")
    }

    func testTroubleCodesCANAndNone() {
        let r = "ECU:1  CMD:03  CNT:6\r\n43 02 03 01 24 01\r\n"
        XCTAssertEqual(ProbeLogic.troubleCodes(service: 0x03, in: r), ["P0301", "P2401"])
        XCTAssertEqual(ProbeLogic.troubleCodes(service: 0x03, in: "ECU:1  CMD:03  CNT:2\r\n43 00\r\n"), [])
        XCTAssertEqual(ProbeLogic.troubleCodes(service: 0x07, in: "47 01 C1 23\r\n>"), ["U0123"])
    }

    func testVINWithNondaHeader() {
        let r = "ECU:1  CMD:0902  CNT:20\r\n0: 49 02 01 31 46 54\r\n1: 37 57 32 42 54 34 4B\r\n2: 45 44 31 32 33 34 35\r\n"
        XCTAssertEqual(ProbeLogic.vin(fromReply: r), "1FT7W2BT4KED12345")
    }
}
