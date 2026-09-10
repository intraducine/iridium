import XCTest

final class LibraryUITests: XCTestCase {
    func testTouchLibraryAndCustomName() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        let first = app.buttons["Play"].firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        app.buttons["Play"].tap()
        XCTAssertTrue(app.alerts["Launch action received"].waitForExistence(timeout: 3))
        app.alerts.buttons["OK"].tap()
        app.buttons["Game options"].tap()
        app.buttons["Edit Name and Artwork"].tap()
        let name = app.textFields["Game name"]
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        name.tap()
        let length = (name.value as? String)?.count ?? 0
        name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: length) + "My Custom Build")
        app.buttons["Save Name"].tap()
        app.buttons["Done"].tap()
        XCTAssertTrue(app.staticTexts["My Custom Build"].firstMatch.waitForExistence(timeout: 3))
        let portrait = XCTAttachment(screenshot: app.screenshot()); portrait.name = "Portrait library"; portrait.lifetime = .keepAlways; add(portrait)
        app.buttons["Search games"].tap()
        let search = app.textFields["Search games"]
        search.tap(); search.typeText("NoSuchTitle")
        XCTAssertTrue(app.buttons["Show All Games"].waitForExistence(timeout: 3))
        app.buttons["Show All Games"].tap()
        XCUIDevice.shared.orientation = .landscapeLeft
        Thread.sleep(forTimeInterval: 1) // Let the system rotation finish before capturing.
        let landscape = XCTAttachment(screenshot: app.screenshot()); landscape.name = "Landscape library"; landscape.lifetime = .keepAlways; add(landscape)
        app.terminate(); app.launch()
        XCTAssertTrue(app.staticTexts["My Custom Build"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["Game options"].tap(); app.buttons["Edit Name and Artwork"].tap()
        app.buttons["Use Original Name"].tap(); app.buttons["Done"].tap()
        XCTAssertTrue(app.staticTexts["Unreleased Project"].firstMatch.waitForExistence(timeout: 3))
    }
}
