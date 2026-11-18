import AxoMobileModel
import XCTest

final class ApprovalCopyTests: XCTestCase {
  func testDecisionLeadsAndEveryRestrictionRemainsAvailable() {
    let copy = ApprovalCopy("Deploy tested relay only? No mailbox, billing, or app changes.")
    XCTAssertEqual(copy.headline, "Deploy tested relay only?")
    XCTAssertEqual(copy.detail, "No mailbox, billing, or app changes.")
    XCTAssertFalse(copy.requiresReview)
  }

  func testLongScopeRequiresReviewAndIsNotSummarized() {
    let message = "Approve? " + String(repeating: "Do not change billing. ", count: 20)
    let copy = ApprovalCopy(message)
    XCTAssertTrue(copy.requiresReview)
    XCTAssertEqual(copy.headline + " " + (copy.detail ?? ""), message.trimmingCharacters(in: .whitespacesAndNewlines))
  }

  func testNoDelimiterPreservesFullQuestion() {
    let copy = ApprovalCopy("Publish the tested build")
    XCTAssertEqual(copy.headline, "Publish the tested build")
    XCTAssertNil(copy.detail)
  }
}
