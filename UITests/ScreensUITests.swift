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

        app.swipeUp()
        XCTAssertTrue(app.buttons["read-tires"].waitForExistence(timeout: 5))
        tap("read-tires")
        shot("09a-tires-card")
        tap("tires-details")
        XCTAssertTrue(app.navigationBars["تفاصيل قراءة الكفرات"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["ATSH726 → OK"].waitForExistence(timeout: 5))
        shot("09b-tires-details")
        tap("إغلاق")
        XCTAssertTrue(app.buttons["tab-home"].waitForExistence(timeout: 5))

        tap("settings");       shot("10-settings")
        app.swipeUp();          shot("11-settings-more")
        app.swipeUp();          shot("12-settings-end")
        tap("back")
        XCTAssertTrue(app.buttons["tab-home"].waitForExistence(timeout: 5))

        tap("tab-home")
        tap("theme-dark")
        tap("health")
        XCTAssertTrue(app.navigationBars["نتيجة الفحص الشامل"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["تقدر تسوق بأمان"].waitForExistence(timeout: 5))
        shot("13-scan-results")
        app.swipeUp();          shot("14-scan-results-more")

        tap("vehicle-info")
        XCTAssertTrue(app.staticTexts["Ford F-250 Super Duty 2019"].waitForExistence(timeout: 5))
        shot("15-vehicle-info")
        tap("back")

        tap("dtc-library")
        XCTAssertTrue(app.navigationBars["دليل أكواد الأعطال"].waitForExistence(timeout: 5))
        shot("16-dtc-library")
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 5))
        let row = app.staticTexts["حساس سرعة الكفر الأمامي اليسار"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(app.navigationBars["شرح الكود"].waitForExistence(timeout: 5))
        shot("17-dtc-detail")
        tap("back")
        tap("back")
        tap("back")
        XCTAssertTrue(app.buttons["tab-home"].waitForExistence(timeout: 5))
    }
}
