import XCTest
final class OpenConfirmation: XCTestCase {
    func testExactPlanFlowOpen() {
        guard ProcessInfo.processInfo.environment["QA_OPEN_CONFIRMATION_GATE"] == "ci-owned-exact-open-v1" else {
            XCTFail("HOST_UI_FAIL_GATE"); return
        }
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        print("HOST_UI_READY")
        fflush(stdout)
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            let alerts = springboard.alerts
            if alerts.count > 0 {
                guard alerts.count == 1 else { XCTFail("HOST_UI_FAIL_MULTIPLE"); return }
                let alert = alerts.element(boundBy: 0)
                guard alert.staticTexts.matching(identifier: "Open in “PlanFlow”?").count == 1 else {
                    XCTFail("HOST_UI_FAIL_TITLE"); return
                }
                let buttons = alert.buttons.matching(identifier: "Open")
                guard buttons.count == 1, buttons.element(boundBy: 0).isHittable else {
                    XCTFail("HOST_UI_FAIL_BUTTON"); return
                }
                buttons.element(boundBy: 0).tap()
                print("HOST_UI_ACK"); fflush(stdout); return
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        print("HOST_UI_NO_ALERT"); fflush(stdout)
    }
}
