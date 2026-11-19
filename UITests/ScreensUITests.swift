import XCTest

/// Opens every screen and button group in demo mode and saves a screenshot of each for review.
final class ScreensUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-uiTesting"]
        app.launch()
    }

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    private func tap(_ label: String, file: StaticString = #file, line: UInt = #line) {
        let b = app.buttons[label].firstMatch
        XCTAssertTrue(b.waitForExistence(timeout: 8), "button \(label) missing", file: file, line: line)
        b.tap()
    }

    func testEveryScreenAndTheme() {
        XCTAssertTrue(app.staticTexts["RA7AL OBD"].waitForExistence(timeout: 10))
        shot("01-home-dark")

        tap("tab-fuel");          shot("02-fuel-dark")
        tap("tab-oil");  shot("03-oil-tires-dark")
        tap("tab-cam");        shot("04-dashcam-dark")
        tap("tab-home")

        tap("theme-light");      shot("05-home-light")
        tap("tab-fuel");          shot("06-fuel-light")
        tap("tab-home")
        tap("theme-youth");      shot("07-home-youth")
        tap("tab-oil");  shot("08-oil-youth")

        tap("غيّرت الزيت اليوم")
        let confirm = app.buttons["نعم، غيّرت الزيت اليوم"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        shot("09-oil-confirm")
        confirm.tap()

        tap("settings");       shot("10-settings")
        app.swipeUp();          shot("11-settings-more")
        app.swipeUp();          shot("12-settings-end")
        tap("back")
        XCTAssertTrue(app.buttons["tab-home"].waitForExistence(timeout: 5))

        tap("tab-home")
        tap("theme-dark")
        tap("health")
        XCTAssertTrue(app.navigationBars["تقرير الفحص"].waitForExistence(timeout: 5))
        shot("13-scan-report")
        app.buttons["تم"].tap()
    }
}
