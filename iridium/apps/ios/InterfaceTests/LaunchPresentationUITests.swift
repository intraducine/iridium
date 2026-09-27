import XCTest

final class LaunchPresentationUITests: XCTestCase {
    private func launch(_ arguments: [String] = ["--covers"]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--launch-presentation"] + arguments
        app.launch()
        XCTAssertTrue(app.staticTexts["launchFixtureReady"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Play"].isHittable)
        return app
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testTitleContinuityAndCancellationInMenu() {
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            let app = launch()
            let source = app.staticTexts["libraryGameTitle"].frame
            capture("launch-library-\(orientation.rawValue)")
            app.buttons["Play"].tap()
            let title = app.staticTexts["playerLaunchTitle"]
            XCTAssertTrue(title.waitForExistence(timeout: 5))
            let moved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                orientation == .portrait
                    ? title.frame.minY < source.minY - 20 && title.frame.minX < app.frame.width / 4
                    : title.frame.minX > source.minX + 80 && title.frame.minY < app.frame.height / 2
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [moved], timeout: 4), .completed)
            XCTAssertFalse(app.buttons["Cancel Launch"].exists)
            capture("launch-artwork-\(orientation.rawValue)")
            app.buttons["Player Menu"].tap()
            XCTAssertTrue(app.buttons["Cancel Launch"].waitForExistence(timeout: 3))
            app.buttons["View Log"].tap()
            XCTAssertTrue(app.navigationBars["View Log"].waitForExistence(timeout: 3))
            app.navigationBars["View Log"].buttons["Done"].tap()
            XCTAssertTrue(title.waitForExistence(timeout: 3)) // No frame: logs must not reveal the game.
            app.buttons["Player Menu"].tap()
            app.buttons["Cancel Launch"].tap()
            XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["Player Menu"].waitForNonExistence(timeout: 5))
            app.terminate()
        }
    }

    func testFirstFramebufferRevealsGameWithoutMinimumHold() {
        XCUIDevice.shared.orientation = .landscapeLeft
        for mode in ["--launch-frame-immediate", "--launch-frame-delayed"] {
            let app = launch(["--covers", mode])
            app.buttons["Play"].tap()
            XCTAssertTrue(app.buttons["Player Menu"].waitForExistence(timeout: 5))
            let artwork = app.descendants(matching: .any)["playerLaunchArtwork"]
            XCTAssertTrue(artwork.waitForNonExistence(timeout: 6))
            XCTAssertFalse(app.staticTexts["playerLaunchTitle"].exists)
            app.buttons["Player Menu"].tap()
            XCTAssertTrue(app.buttons["Close Game"].waitForExistence(timeout: 3))
            XCTAssertFalse(app.buttons["Cancel Launch"].exists)
            capture("launch-first-frame-\(mode)")
            app.terminate()
        }
    }

    func testMissingArtworkFailureAndRotationRemainUsable() {
        for arguments in [[], ["--covers", "--launch-cover-only"], ["--covers", "--launch-failed"]] {
            XCUIDevice.shared.orientation = .portrait
            let app = launch(arguments)
            app.buttons["Play"].tap()
            let title = app.staticTexts["playerLaunchTitle"]
            XCTAssertTrue(title.waitForExistence(timeout: 5))
            XCUIDevice.shared.orientation = .landscapeLeft
            let rotated = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                app.frame.width > app.frame.height && title.frame.maxY < app.frame.height
                    && title.frame.minX >= 0
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [rotated], timeout: 5), .completed)
            XCTAssertTrue(app.buttons["Player Menu"].isHittable)
            if arguments.contains("--launch-failed") {
                XCTAssertTrue(app.buttons["View Logs"].exists)
                XCTAssertTrue(app.buttons["Back to Library"].isHittable)
            }
            capture("launch-fallback-\(arguments.joined(separator: "-"))")
            app.terminate()
        }
    }
}
