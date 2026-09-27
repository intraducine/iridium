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

    func testQueuedStatusDoesNotReflowTheOutgoingLibrary() {
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            let app = launch(["--covers", "--launch-queued-phase"])
            let title = app.staticTexts["libraryGameTitle"]
            let cover = app.buttons["selectedGameCover"]
            let titleFrame = title.frame
            let coverFrame = cover.frame
            let buttonFrame = app.buttons["Play"].frame
            app.buttons["Play"].tap()
            XCTAssertTrue(app.buttons["continueQueuedLaunch"].waitForExistence(timeout: 3))
            XCTAssertTrue(app.buttons["Play"].exists)
            XCTAssertFalse(app.buttons["Play"].isEnabled)
            XCTAssertFalse(app.buttons["Play queued"].exists)
            XCTAssertEqual(title.frame.minX, titleFrame.minX, accuracy: 1)
            XCTAssertEqual(title.frame.minY, titleFrame.minY, accuracy: 1)
            XCTAssertEqual(cover.frame.minY, coverFrame.minY, accuracy: 1)
            XCTAssertEqual(cover.frame.height, coverFrame.height, accuracy: 1)
            XCTAssertEqual(app.buttons["Play"].frame.width, buttonFrame.width, accuracy: 1)
            capture("launch-queued-stable-\(orientation.rawValue)")
            app.buttons["cancelQueuedLaunch"].tap()
            XCTAssertTrue(app.buttons["Play"].isEnabled)
            app.buttons["Play"].tap()
            app.buttons["continueQueuedLaunch"].tap()
            XCTAssertTrue(app.staticTexts["playerLaunchTitle"].waitForExistence(timeout: 5))
            app.terminate()
        }
    }

    func testPosterTitleLayoutAndCancellationInMenu() {
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            let app = launch()
            capture("launch-library-\(orientation.rawValue)")
            app.buttons["Play"].tap()
            let title = app.staticTexts["playerLaunchTitle"]
            let cover = app.descendants(matching: .any)["playerLaunchCover"]
            XCTAssertTrue(title.waitForExistence(timeout: 5))
            XCTAssertTrue(cover.waitForExistence(timeout: 5))
            let placed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                if orientation == .landscapeLeft {
                    return title.frame.minX > cover.frame.maxX && abs(title.frame.minY - cover.frame.minY) < 2
                }
                return abs(title.frame.minX - cover.frame.minX) < 2 && title.frame.maxY < cover.frame.minY
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [placed], timeout: 5), .completed)
            XCTAssertLessThan(cover.frame.width, cover.frame.height)
            XCTAssertLessThan(cover.frame.minX, app.frame.width / 4)
            XCTAssertFalse(app.buttons["Cancel Launch"].exists)
            let settledTitle = title.frame
            let settledCover = cover.frame
            capture("launch-poster-layout-\(orientation.rawValue)")
            app.buttons["Player Menu"].tap()
            XCTAssertTrue(app.buttons["Cancel Launch"].waitForExistence(timeout: 3))
            app.buttons["View Log"].tap()
            XCTAssertTrue(app.navigationBars["View Log"].waitForExistence(timeout: 3))
            app.navigationBars["View Log"].buttons["Done"].tap()
            XCTAssertTrue(title.waitForExistence(timeout: 3))
            XCTAssertEqual(title.frame.minX, settledTitle.minX, accuracy: 2)
            XCTAssertEqual(title.frame.minY, settledTitle.minY, accuracy: 2)
            XCTAssertEqual(cover.frame.width, settledCover.width, accuracy: 2)
            XCTAssertEqual(cover.frame.minY, settledCover.minY, accuracy: 2)
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
