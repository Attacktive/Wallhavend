import XCTest

final class WallhavendUITests: XCTestCase {
	var app: XCUIApplication!

	override func setUpWithError() throws {
		continueAfterFailure = false
		app = XCUIApplication()
		app.launch()
	}

	override func tearDownWithError() throws {
		app = nil
	}

	func testBasicUIElements() throws {
		// Check title
		XCTAssertTrue(app.staticTexts["Wallhavend"].exists)

		// Check search field
		XCTAssertTrue(app.textFields["Search query (optional; delimit with a comma)"].exists)

		// Check content filter toggles
		XCTAssertTrue(app.checkBoxes["SFW"].exists)
		XCTAssertTrue(app.checkBoxes["Sketchy"].exists)
		XCTAssertTrue(app.checkBoxes["NSFW"].exists)

		// Check category toggles
		XCTAssertTrue(app.checkBoxes["General"].exists)
		XCTAssertTrue(app.checkBoxes["Anime"].exists)
		XCTAssertTrue(app.checkBoxes["People"].exists)

		// Check advanced options
		XCTAssertTrue(app.textFields["Aspect Ratio (e.g. 16x9)"].exists)
		XCTAssertTrue(app.secureTextFields["API Key (optional)"].exists)

		// Check buttons
		XCTAssertTrue(app.buttons["Update Now"].exists)
		XCTAssertTrue(app.buttons["Start  Auto Update"].exists)
	}

	func testUpdateInterval() throws {
		// Open update interval picker
		let picker = app.popUpButtons.firstMatch
		XCTAssertTrue(picker.exists)
		picker.click()

		// Check interval options exist
		XCTAssertTrue(app.menuItems["1 minute"].exists)
		XCTAssertTrue(app.menuItems["5 minutes"].exists)
		XCTAssertTrue(app.menuItems["15 minutes"].exists)
		XCTAssertTrue(app.menuItems["30 minutes"].exists)
		XCTAssertTrue(app.menuItems["1 hour"].exists)

		// Select an interval
		app.menuItems["5 minutes"].click()
	}

	func testStartStopAutoUpdate() throws {
		// Start auto-update
		let startButton = app.buttons["Start Auto Update"]
		XCTAssertTrue(startButton.exists)
		startButton.click()

		// Button should change to "Stop Auto Update"
		let stopButton = app.buttons["Stop Auto Update"]
		XCTAssertTrue(stopButton.exists)

		// Stop auto-update
		stopButton.click()

		// Button should change back to "Start Auto Update"
		XCTAssertTrue(app.buttons["Start Auto Update"].exists)
	}

	func testSearchQuery() throws {
		// Find search field
		let searchField = app.textFields["Search query (optional; delimit with a comma)"]
		XCTAssertTrue(searchField.exists)

		// Type a search query
		searchField.click()
		searchField.typeText("nature landscape")

		// Update wallpaper
		app.buttons["Update Now"].click()
	}

	func testExample() throws {
		// UI tests must launch the application that they test.
		let app = XCUIApplication()
		app.launch()

		// Use XCTAssert and related functions to verify your tests produce the correct results.
	}

	func testLaunchPerformance() throws {
		if #available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 7.0, *) {
			// This measures how long it takes to launch your application.
			measure(metrics: [XCTApplicationLaunchMetric()]) {
				XCUIApplication().launch()
			}
		}
	}
}
