import XCTest

/// Not a test of the app: a headless way to answer the Photos permission
/// alert on a simulator so screenshots can be taken with simctl afterwards.
final class GrantPhotosTests: XCTestCase {
    func testGrantPhotosAccess() {
        let app = XCUIApplication()
        app.launch()

        let allow = app.buttons["Allow access to Photos"]
        if allow.waitForExistence(timeout: 8) {
            allow.tap()
        }

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let full = springboard.buttons["Allow Full Access"]
        if full.waitForExistence(timeout: 8) {
            full.tap()
        }

        // The grid should now be up.
        _ = app.wait(for: .runningForeground, timeout: 10)
    }
}
