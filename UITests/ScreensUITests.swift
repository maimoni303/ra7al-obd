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

        tap("الوقود");          shot("02-fuel-dark")
        tap("الزيت والكفرات");  shot("03-oil-tires-dark")
        tap("الداشكام");        shot("04-dashcam-dark")
        tap("الرئيسية")

        tap("مظهر نهاري");      shot("05-home-light")
        tap("الوقود");          shot("06-fuel-light")
        tap("الرئيسية")
        tap("مظهر شبابي");      shot("07-home-youth")
        tap("الزيت والكفرات");  shot("08-oil-youth")

        tap("غيّرت الزيت اليوم")
        let confirm = app.buttons["نعم، غيّرت الزيت اليوم"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        shot("09-oil-confirm")
        confirm.tap()

        tap("الإعدادات");       shot("10-settings")
        app.swipeUp();          shot("11-settings-more")
        app.swipeUp();          shot("12-settings-end")
        app.navigationBars.buttons.firstMatch.tap()

        tap("الرئيسية")
        tap("مظهر ليلي")
        app.buttons.matching(NSPredicate(format: "label CONTAINS 'صحة السيارة'")).firstMatch.tap()
        XCTAssertTrue(app.navigationBars["تقرير الفحص"].waitForExistence(timeout: 5))
        shot("13-scan-report")
        app.buttons["تم"].tap()
    }
}
