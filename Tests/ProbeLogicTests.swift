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
}
