import XCTest

/// Presentation regression for the member-management, create, and detail views.
final class MemberViewsPresentationUITests: XCTestCase {
    func test_memberManagementCanCreateAndOpenMemberDetail() {
        let app = UITestSupport.makeSeededApp()
        UITestSupport.openTab("我的", in: app)

        let membersEntry = app.descendants(matching: .any)["SP-25.settings.members"].firstMatch
        UITestSupport.scrollToHittable(membersEntry, in: app, maxSwipes: 10)
        XCTAssertTrue(membersEntry.waitForExistence(timeout: 5))
        membersEntry.tap()

        let addMember = app.buttons["FR3.7.member.add"]
        XCTAssertTrue(addMember.waitForExistence(timeout: 10))
        // TD（2026-10-29）：创建 sheet 段「出现≠可点」——点走可点性门控；
        // run 40812706085 首轮在此段 5s 预算内失败、二轮同环境零代码差通过
        // =模拟器转场抖动，本段为加固面（预算 5→10s + tapWhenHittable）。
        UITestSupport.tapWhenHittable(addMember)

        let name = app.textFields["FR3.7.create.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        UITestSupport.tapWhenHittable(name)
        name.typeText("Atomicity Test Member")
        app.buttons["FR3.7.create.save"].tap()

        let addedAlert = app.alerts.firstMatch
        XCTAssertTrue(addedAlert.waitForExistence(timeout: 5))
        addedAlert.buttons.element(boundBy: 0).tap()

        let memberName = app.staticTexts["Atomicity Test Member"].firstMatch
        XCTAssertTrue(memberName.waitForExistence(timeout: 5))
        memberName.tap()
        XCTAssertTrue(app.buttons["FR3.1.member.update"].waitForExistence(timeout: 5),
                      "A member row must still open its editable detail view")
    }
}
