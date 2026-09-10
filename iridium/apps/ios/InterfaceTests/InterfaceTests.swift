import XCTest

final class InterfaceTests: XCTestCase {
    func testInterruptedCarouselAndSearchFocus() {
        let app = XCUIApplication()
        app.launchArguments = ["--controller", "--covers"]
        XCUIDevice.shared.orientation = .landscapeLeft
        app.launch()
        XCTAssertTrue(app.buttons["rapidDirections"].waitForExistence(timeout: 10))
        for _ in 0..<3 {
            app.buttons["rapidDirections"].tap()
            let selected = app.buttons["selectedGameCover"]
            XCTAssertEqual(selected.label, "Unreleased Project")
            XCTAssertEqual(selected.frame.minX, app.staticTexts["Iridium"].frame.minX, accuracy: 4)
        }
        pressPad(2, in: app) // Covers -> Play
        pressPad(1, in: app) // Play -> Game Options
        pressPad(2, in: app) // Game Options -> Search
        pressPad(4, in: app)
        XCTAssertTrue(app.textFields["Search games"].waitForExistence(timeout: 3))
        app.buttons["closeLibrarySearch"].tap()
        capture("rapid-carousel-search-focus")
    }

    func testSettingsLandscapeTransition() {
        let app = XCUIApplication()
        app.launchArguments = ["--covers", "--hints"]
        XCUIDevice.shared.orientation = .landscapeLeft
        app.launch()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 10))
        for _ in 0..<3 {
            app.buttons["Settings"].tap()
            let bar = app.navigationBars["Settings"]
            XCTAssertTrue(bar.waitForExistence(timeout: 3))
            XCTAssertGreaterThanOrEqual(bar.staticTexts["Settings"].frame.minY, 0)
            XCTAssertLessThan(bar.staticTexts["Settings"].frame.maxY, 70)
            bar.buttons.firstMatch.tap()
            XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 3))
        }
        app.buttons["Settings"].tap()
        app.swipeUp()
        capture("settings-library-rows-landscape")
    }

    func testPlayerSafeAreaPanels() {
        let app = XCUIApplication()
        app.launchArguments = ["--player"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        XCTAssertTrue(app.buttons["Resume"].waitForExistence(timeout: 10))
        XCTAssertGreaterThan(app.buttons["Player Menu"].frame.minY, 60)
        app.buttons["Resume"].tap()
        let launch = app.descendants(matching: .any)["playerLaunchPanel"]
        capture("player-panel-accessibility")
        XCTAssertTrue(launch.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(launch.frame.minY, 60)
        XCTAssertLessThan(launch.frame.maxX, app.frame.maxX - 8)
        capture("player-safe-portrait")
        XCUIDevice.shared.orientation = .landscapeLeft
        let rotated = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.frame.width > app.frame.height && launch.frame.minX > 55
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [rotated], timeout: 5), .completed)
        XCTAssertGreaterThan(launch.frame.minX, 55)
        XCTAssertGreaterThanOrEqual(launch.frame.minY, 10)
        capture("player-safe-landscape")
    }

    func testPresentedPlayerClose() {
        let app = XCUIApplication()
        app.launchArguments = ["--presented-player"]
        XCUIDevice.shared.orientation = .landscapeLeft
        app.launch()
        XCTAssertTrue(app.buttons["Close Game"].waitForExistence(timeout: 10))
        app.buttons["Close Game"].tap()
        XCTAssertTrue(app.alerts["Close game?"].waitForExistence(timeout: 3))
        app.alerts.buttons["Keep playing"].tap()
        XCTAssertTrue(app.buttons["Close Game"].exists)
        app.buttons["Close Game"].tap()
        app.alerts.buttons["Close game"].tap()
        XCTAssertTrue(app.staticTexts["returnedFromPlayer"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Player Menu"].exists)
        capture("player-dismissed-to-presenter")
    }

    func testCoversUseBottomSpace() {
        let app = XCUIApplication()
        app.launchArguments = ["--covers"]
        XCUIDevice.shared.orientation = .landscapeLeft
        app.launch()
        let cover = app.buttons["selectedGameCover"]
        XCTAssertTrue(cover.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(cover.frame.maxY, app.frame.maxY - 60)
        XCTAssertLessThan(cover.frame.maxY, app.frame.maxY - 10)
        capture("cover-bottom-clearance")
    }

    func testStorageAndChecksLayout() {
        let app = XCUIApplication()
        app.launchArguments = ["--settings"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        let storage = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Device capacity")).firstMatch
        XCTAssertTrue(storage.waitForExistence(timeout: 5))
        storage.tap()
        XCTAssertTrue(app.staticTexts["Total Capacity"].waitForExistence(timeout: 5))
        app.buttons["Refresh"].tap()
        capture("storage-actual-capacity")
        app.terminate()
        app.launchArguments = ["--checks"]
        XCUIDevice.shared.orientation = .landscapeLeft
        app.launch()
        XCTAssertTrue(app.buttons["Run Check Again"].waitForExistence(timeout: 5))
        XCTAssertLessThan(app.buttons["Run Check Again"].frame.height, 100)
        capture("launch-checks-landscape")
    }

    func testSharedControlContrast() {
        let app = XCUIApplication()
        app.launchArguments = ["--contrast"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        let toggle = app.switches["Enabled switch"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "0")
        capture("contrast-off-portrait")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertEqual(toggle.value as? String, "1")
        app.buttons["Second"].tap()
        capture("contrast-on-portrait")
        XCUIDevice.shared.orientation = .landscapeLeft
        capture("contrast-on-landscape")
    }

    func testIsolatedSettingsRoute() {
        let app = XCUIApplication()
        app.launchArguments = ["--controller", "--settings"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 3))
        let button = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Launch Support")).firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 3))
        button.tap()
        capture("settings-touch-route")
        XCTAssertTrue(app.navigationBars["Launch Support"].waitForExistence(timeout: 3))
    }

    func testSettingsTouchRoute() {
        let app = XCUIApplication()
        app.launchArguments = ["--controller"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 10))
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 3))
        let button = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Launch Support")).firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 3))
        button.tap()
        capture("settings-touch-route")
        XCTAssertTrue(app.navigationBars["Launch Support"].waitForExistence(timeout: 3))
    }

    func testControllerSubmenus() {
        let app = XCUIApplication()
        app.launchArguments = ["--controller"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        XCTAssertTrue(app.buttons["pad10"].waitForExistence(timeout: 10))
        pressPad(10, in: app)
        XCTAssertTrue(app.navigationBars["Game Options"].waitForExistence(timeout: 3))
        pressPad(3, in: app) // Rename
        pressPad(3, in: app) // Controls
        pressPad(4, in: app)
        XCTAssertTrue(app.navigationBars["Controls"].waitForExistence(timeout: 3))
        capture("controller-controls")
        pressPad(5, in: app)
        XCTAssertTrue(app.navigationBars["Game Options"].waitForExistence(timeout: 3))
        pressPad(3, in: app) // Files
        pressPad(4, in: app)
        XCTAssertTrue(app.navigationBars["Files & Saves"].waitForExistence(timeout: 3))
        pressPad(5, in: app)
        pressPad(5, in: app)
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 3))
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 3))
        capture("settings-before-controller")
        pressPad(4, in: app)
        capture("settings-after-controller")
        XCTAssertTrue(app.navigationBars["Launch Support"].waitForExistence(timeout: 3))
        pressPad(5, in: app)
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 3))
        pressPad(3, in: app)
        pressPad(4, in: app)
        XCTAssertTrue(app.navigationBars["Runtime"].waitForExistence(timeout: 3))
        capture("controller-runtime-settings")
        pressPad(5, in: app)
        pressPad(5, in: app)
        XCTAssertTrue(app.buttons["gameOptions"].waitForExistence(timeout: 3))
    }

    func testControllerAppearanceAndConfirmation() {
        let app = XCUIApplication()
        app.launchArguments = ["--controller"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        XCTAssertTrue(app.buttons["pad10"].waitForExistence(timeout: 10))
        pressPad(10, in: app)
        pressPad(3, in: app)
        pressPad(4, in: app)
        XCTAssertTrue(app.navigationBars["Game Appearance"].waitForExistence(timeout: 3))
        pressPad(4, in: app)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        pressPad(5, in: app)
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 3))
        XCTAssertTrue(app.navigationBars["Game Appearance"].exists)
        pressPad(5, in: app)
        XCTAssertTrue(app.navigationBars["Game Options"].waitForExistence(timeout: 3))
        for _ in 0..<14 {
            if app.buttons["Remove from Library"].exists && app.buttons["Remove from Library"].isSelected { break }
            pressPad(3, in: app)
        }
        XCTAssertTrue(app.buttons["Remove from Library"].isSelected)
        pressPad(4, in: app)
        XCTAssertTrue(app.navigationBars["Remove from Library?"].waitForExistence(timeout: 3))
        pressPad(4, in: app) // Safe default: Cancel
        XCTAssertTrue(app.navigationBars["Remove from Library?"].waitForNonExistence(timeout: 3))
        XCTAssertTrue(app.navigationBars["Game Options"].exists)
        pressPad(5, in: app)
        XCTAssertTrue(app.buttons["selectedGameCover"].exists)
    }

    func testDedicatedLibraryShortcuts() {
        let app = XCUIApplication()
        app.launchArguments = ["--controller", "--actions"]
        app.launch()
        XCTAssertTrue(app.buttons["pad6"].waitForExistence(timeout: 10))
        pressPad(6, in: app)
        XCTAssertEqual(app.staticTexts["actionCounts"].label, "Plays 1 Options 0")
        pressPad(10, in: app)
        XCTAssertEqual(app.staticTexts["actionCounts"].label, "Plays 1 Options 1")
        pressPad(7, in: app)
        XCTAssertFalse(app.textFields["Search games"].exists)
        app.buttons["Search"].tap()
        pressPad(6, in: app)
        XCTAssertEqual(app.staticTexts["actionCounts"].label, "Plays 1 Options 1")
        pressPad(5, in: app)
        pressPad(2, in: app) // Play focus
        capture("capsule-play-focus")
        pressPad(4, in: app)
        XCTAssertEqual(app.staticTexts["actionCounts"].label, "Plays 2 Options 1")
        pressPad(1, in: app) // Options focus
        pressPad(4, in: app)
        XCTAssertEqual(app.staticTexts["actionCounts"].label, "Plays 2 Options 2")
    }

    func testCarouselEdges() {
        let app = XCUIApplication()
        app.launchArguments = ["--controller"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        XCTAssertTrue(app.buttons["pad1"].waitForExistence(timeout: 10))
        let selected = app.buttons["selectedGameCover"]
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            XCTAssertTrue(selected.waitForExistence(timeout: 3))
            let start = selected.label
            let anchor = app.staticTexts["Iridium"].frame.minX
            for _ in 0..<3 { pressPad(1, in: app) }
            XCTAssertNotEqual(selected.label, start)
            XCTAssertEqual(selected.frame.minX, anchor, accuracy: 4)
            for _ in 0..<3 { pressPad(0, in: app) }
            XCTAssertEqual(selected.label, start)
            XCTAssertEqual(selected.frame.minX, anchor, accuracy: 4)
            let shelf = app.scrollViews["gameCarousel"]
            XCTAssertEqual(shelf.frame.width, app.frame.width, accuracy: 2)
            shelf.swipeLeft()
            XCTAssertNotEqual(selected.label, start)
            for _ in 0..<4 { shelf.swipeLeft() }
            XCTAssertTrue(selected.isHittable)
            XCTAssertGreaterThanOrEqual(selected.frame.minX, 12)
            XCTAssertLessThan(selected.frame.maxX, app.frame.maxX)
            XCTAssertLessThan(selected.frame.maxY, app.frame.maxY - 44)
            for _ in 0..<5 { shelf.swipeRight() }
            XCTAssertTrue(selected.isHittable)
            XCTAssertEqual(selected.frame.minX, anchor, accuracy: 4)
            capture("edge-carousel-\(orientation.rawValue)")
        }
    }

    func testControllerLibraryRouting() {
        let app = XCUIApplication()
        app.launchArguments = ["--controller"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        XCTAssertTrue(app.buttons["pad1"].waitForExistence(timeout: 10))
        let selected = app.buttons["selectedGameCover"]
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            pressPad(1, in: app)
            XCTAssertEqual(selected.label, "Mountain Walk")
            pressPad(0, in: app)
            XCTAssertEqual(selected.label, "Unreleased Project")
            app.buttons["stickRight"].tap()
            XCTAssertEqual(selected.label, "Mountain Walk")
            pressPad(0, in: app)
            pressPad(9, in: app)
            XCTAssertTrue(app.staticTexts["No Favorites Yet"].exists)
            pressPad(8, in: app)
            XCTAssertTrue(selected.exists)
            pressPad(10, in: app)
            XCTAssertTrue(app.navigationBars["Game Options"].waitForExistence(timeout: 3))
            pressPad(5, in: app)
            pressPad(2, in: app) // Covers -> Play
            pressPad(1, in: app) // Play -> Game Options
            capture("controller-options-focus-\(orientation.rawValue)")
            pressPad(4, in: app)
            XCTAssertTrue(app.navigationBars["Game Options"].waitForExistence(timeout: 3))
            pressPad(5, in: app)
            XCTAssertTrue(app.buttons["gameOptions"].waitForExistence(timeout: 3))
            pressPad(5, in: app) // Return focus to covers
            pressPad(7, in: app)
            XCTAssertFalse(app.textFields["Search games"].exists)
            app.buttons["Search"].tap()
            XCTAssertTrue(app.textFields["Search games"].waitForExistence(timeout: 3))
            pressPad(5, in: app)
            XCTAssertFalse(app.textFields["Search games"].exists)
            pressPad(2, in: app)
            pressPad(2, in: app)
            pressPad(1, in: app)
            XCTAssertTrue(app.staticTexts["No Favorites Yet"].exists)
            pressPad(0, in: app)
            XCTAssertTrue(selected.exists)
            pressPad(1, in: app)
            pressPad(1, in: app) // Favorites -> Search
            pressPad(4, in: app)
            XCTAssertTrue(app.textFields["Search games"].exists)
            pressPad(5, in: app)
            pressPad(2, in: app)
            pressPad(2, in: app)
            pressPad(0, in: app) // All Games
            pressPad(5, in: app)
        }
    }

    func testLibraryNavigationAndMenus() {
        let app = XCUIApplication()
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.tabBars.count, 0)
        XCTAssertFalse(app.buttons["More"].exists)
        XCTAssertFalse(app.buttons["Import"].exists)
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: app.buttons["Add Game"])
            waitForExpectations(timeout: 5)
            XCTAssertTrue(app.buttons["Search"].isHittable)
            app.buttons["Favorites"].tap()
            XCTAssertTrue(app.staticTexts["No Favorites Yet"].waitForExistence(timeout: 3))
            XCTAssertFalse(app.buttons["Show All Games"].exists)
            app.buttons["Favorites"].tap()
            XCTAssertTrue(app.staticTexts["No Favorites Yet"].exists)
            capture("favorites-\(orientation.rawValue)")
            app.buttons["All Games"].tap()
        }
        XCUIDevice.shared.orientation = .portrait
        expectation(for: NSPredicate { _, _ in app.buttons["Settings"].frame.minY < 150 && app.frame.width < app.frame.height }, evaluatedWith: app)
        waitForExpectations(timeout: 5)
        let headerY = app.buttons["Settings"].frame.minY
        app.swipeUp()
        XCTAssertEqual(app.buttons["Settings"].frame.minY, headerY, accuracy: 1)
        app.buttons["Search"].tap()
        let field = app.textFields["Search games"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.tap(); field.typeText("zzzznotagame")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", "No Results")).firstMatch.waitForExistence(timeout: 3))
        capture("search-no-results")
        app.buttons["closeLibrarySearch"].tap()
        XCTAssertFalse(field.exists)
        let shelf = app.scrollViews["gameCarousel"]
        XCTAssertEqual(shelf.frame.minX, app.frame.minX, accuracy: 1)
        XCTAssertEqual(shelf.frame.maxX, app.frame.maxX, accuracy: 1)
        for _ in 0..<5 { shelf.swipeLeft() }
        let last = app.buttons["selectedGameCover"]
        capture("touch-search-carousel-end")
        XCTAssertTrue(last.isHittable)
        XCTAssertGreaterThanOrEqual(last.frame.minX, 12)
        XCTAssertLessThan(last.frame.minX, 45)
        capture("portrait-library")
        last.tap()
        for _ in 0..<3 {
            app.buttons["gameOptions"].tap()
            XCTAssertTrue(app.navigationBars["Game Options"].waitForExistence(timeout: 3))
            XCTAssertTrue(app.buttons["Rename & Artwork"].exists)
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
        app.buttons["gameOptions"].tap()
        app.buttons["Rename & Artwork"].tap()
        XCTAssertTrue(app.navigationBars["Game Appearance"].waitForExistence(timeout: 3))
        app.navigationBars["Game Appearance"].buttons["Done"].tap()
        app.buttons["gameControlsLink"].tap()
        XCTAssertTrue(app.navigationBars["Controls"].waitForExistence(timeout: 3))
        capture("controls")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        for _ in 0..<3 { if app.buttons["Remove from Library"].isHittable { break }; app.swipeUp() }
        app.buttons["Remove from Library"].tap()
        XCTAssertTrue(app.navigationBars["Remove from Library?"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Game files and saves will not be deleted."].exists)
        app.buttons["Cancel"].tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCUIDevice.shared.orientation = .landscapeLeft
        expectation(for: NSPredicate { _, _ in
            app.frame.width > app.frame.height && app.buttons["gameOptions"].frame.maxY < app.frame.height / 2
        }, evaluatedWith: app)
        waitForExpectations(timeout: 5)
        XCTAssertLessThanOrEqual(app.scrollViews["gameCarousel"].frame.maxY, app.frame.height)
        XCTAssertLessThanOrEqual(last.frame.maxY, app.scrollViews["gameCarousel"].frame.maxY)
        capture("landscape-library")
        XCTAssertTrue(app.buttons["gameOptions"].isHittable)
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 3))
        app.navigationBars["Settings"].buttons.firstMatch.tap()
        XCTAssertTrue(app.buttons["Add Game"].isHittable)
    }
    func testSearchWithKeyboard() {
        let app = XCUIApplication(); app.launch()
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            expectation(for: NSPredicate { _, _ in
                orientation == .portrait ? app.frame.width < app.frame.height : app.frame.width > app.frame.height
            }, evaluatedWith: app)
            waitForExpectations(timeout: 5)
            if !app.textFields["Search games"].exists { app.buttons["Search"].tap() }
            app.textFields["Search games"].tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
            let result = app.buttons["selectedGameCover"]
            XCTAssertTrue(result.isHittable)
            expectation(for: NSPredicate { _, _ in result.frame.maxY + (orientation == .landscapeLeft ? 32 : 0) <= app.keyboards.firstMatch.frame.minY }, evaluatedWith: result)
            waitForExpectations(timeout: 5)
            capture("search-keyboard-\(orientation.rawValue)")
        }
        app.buttons["selectedGameCover"].tap()
        XCTAssertTrue(app.textFields["Search games"].waitForNonExistence(timeout: 3))
        XCTAssertTrue(app.buttons["gameOptions"].isHittable)
    }
    func testHardwareKeyboardNavigation() {
        let app = XCUIApplication(); app.launch()
        app.buttons["Search"].tap()
        let field = app.textFields["Search games"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.tap(); field.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(field.waitForNonExistence(timeout: 3))
        if field.exists { app.buttons["closeLibrarySearch"].tap() }
        app.buttons["selectedGameCover"].tap()
        app.typeKey(.rightArrow, modifierFlags: [])
        XCTAssertEqual(app.buttons["selectedGameCover"].label, "Mountain Walk")
        app.typeKey(.leftArrow, modifierFlags: [])
        XCTAssertEqual(app.buttons["selectedGameCover"].label, "Unreleased Project")
    }
    func testImportConfirmation() {
        let app = XCUIApplication()
        app.launchArguments = ["--import"]
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.navigationBars["Confirm Game"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.textFields["Game name"].exists)
        XCTAssertTrue(app.buttons["Custom.exe"].exists)
        app.buttons["Launcher.exe"].tap()
        XCTAssertEqual(app.buttons["Launcher.exe"].value as? String, "Selected")
        capture("confirm-custom-game")
        app.navigationBars["Confirm Game"].buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars["Confirm Game"].waitForNonExistence(timeout: 3))
        app.launch()
        app.buttons["Choose Another Folder"].tap()
        XCTAssertTrue(app.navigationBars["Confirm Game"].waitForNonExistence(timeout: 3))
        XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 15))
    }
    func testPlayerMenu() {
        let app = XCUIApplication()
        app.launchArguments = ["--player"]
        app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["Player Menu"].waitForExistence(timeout: 10))
        app.buttons["Resume"].tap()
        XCTAssertTrue(app.buttons["Resume"].waitForNonExistence(timeout: 3))
        for _ in 0..<3 {
            app.buttons["Player Menu"].tap()
            XCTAssertTrue(app.buttons["Resume"].waitForExistence(timeout: 3))
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.7)).tap()
            XCTAssertTrue(app.buttons["Resume"].waitForNonExistence(timeout: 3))
        }
        // The menu now clears the landscape display cutout and corner safe area.
        XCTAssertLessThan(app.frame.maxX - app.buttons["Player Menu"].frame.maxX, 90)
        XCTAssertGreaterThan(app.buttons["Player Menu"].frame.minX, app.frame.maxX - 150)
        app.buttons["Player Menu"].tap()
        capture("player-menu")
        app.buttons["Close Game"].tap()
        XCTAssertTrue(app.alerts["Close game?"].waitForExistence(timeout: 3))
        app.alerts.buttons["Keep playing"].tap()
        app.buttons["Controls"].tap()
        XCTAssertTrue(app.navigationBars["Controls"].waitForExistence(timeout: 3))
        app.navigationBars["Controls"].buttons["Done"].tap()
        app.buttons["Player Menu"].tap()
        app.buttons["View Log"].tap()
        XCTAssertTrue(app.navigationBars["View Log"].waitForExistence(timeout: 3))
        app.navigationBars["View Log"].buttons["Done"].tap()
    }
    func testEmptyLibrary() {
        let app = XCUIApplication()
        app.launchArguments = ["--empty"]
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.staticTexts["Add Your First Game"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons.matching(identifier: "Add Game").count, 1)
        XCTAssertEqual(app.tabBars.count, 0)
        capture("empty-library")
        app.buttons["Add Game"].tap()
        XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 15))
        capture("file-picker")
    }
    private func pressPad(_ button: Int, in app: XCUIApplication) {
        let target = app.buttons["pad\(button)"]
        if !target.exists { XCTAssertTrue(target.waitForExistence(timeout: 3)) }
        target.tap()
    }
    private func capture(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(name + ".png")
        try? screenshot.pngRepresentation.write(to: path)
        print("SCREENSHOT: \(path.path)")
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
