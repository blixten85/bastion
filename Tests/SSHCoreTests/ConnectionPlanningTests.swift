import XCTest
@testable import SSHCore

/// Täcker den fail-closed-policy som `App/AuthResolver.resolveConnectionPlan`
/// (+ LinuxApp-motsvarigheten) delegerar till — cubic-fynd på PR #172 om att
/// policyn saknade automatiserad täckning eftersom App/ inte kan byggas/
/// testas lokalt. `ConnectionPlanning.plan` är ren (tar redan upplösta
/// `SSHAuth?`-värden), så den går att testa här utan Keychain/Xcode.
final class ConnectionPlanningTests: XCTestCase {
    private func makeHost(jumpHostID: UUID? = nil) -> SSHCore.Host {
        SSHCore.Host(alias: "t", hostName: "10.0.0.1", user: "u", jumpHostID: jumpHostID)
    }

    /// `Result<(auth: SSHAuth, jump: ...), ConnectionPlanFailure>` är inte
    /// `Equatable` (tupeln med `SSHAuth` i success-fallet gör det), så
    /// `XCTAssertEqual` mot hela `Result`-värdet fungerar bara för
    /// failure-sidan — därför denna lilla hjälpare i stället för att
    /// jämföra `Result` direkt.
    private func assertFailure(
        _ result: Result<(auth: SSHAuth, jump: (target: SSHTarget, auth: SSHAuth)?), ConnectionPlanFailure>,
        _ expected: ConnectionPlanFailure, file: StaticString = #filePath, line: UInt = #line
    ) {
        guard case .failure(let actual) = result else {
            return XCTFail("förväntade .failure(\(expected)), fick success", file: file, line: line)
        }
        XCTAssertEqual(actual, expected, file: file, line: line)
    }

    func testDirectSuccessWithoutJumpHost() {
        let result = ConnectionPlanning.plan(
            targetAuth: .password("p"), jumpHostID: nil, jumpHost: nil, jumpAuth: nil)
        guard case .success(let plan) = result else { return XCTFail("förväntade success") }
        XCTAssertNil(plan.jump)
    }

    func testTargetAuthFailedWithoutJumpHost() {
        let result = ConnectionPlanning.plan(
            targetAuth: nil, jumpHostID: nil, jumpHost: nil, jumpAuth: nil)
        assertFailure(result, .targetAuthFailed)
    }

    func testSuccessThroughJumpHost() {
        let jump = makeHost()
        let result = ConnectionPlanning.plan(
            targetAuth: .password("target"), jumpHostID: jump.id, jumpHost: jump, jumpAuth: .password("jump"))
        guard case .success(let plan) = result, let jumpPlan = plan.jump else {
            return XCTFail("förväntade success med jump")
        }
        XCTAssertEqual(jumpPlan.target.host, jump.hostName)
    }

    func testJumpHostMissingFromStore() {
        let result = ConnectionPlanning.plan(
            targetAuth: .password("target"), jumpHostID: UUID(), jumpHost: nil, jumpAuth: nil)
        assertFailure(result, .jumpHostMissing)
    }

    /// Jump-hosten hittades, men det UUID:t som skickades in matchar den
    /// inte (t.ex. anropsplatsen råkade slå upp fel host) — ska failas precis
    /// som om den saknades helt, inte tyst användas ändå.
    func testJumpHostIDMismatchTreatedAsMissing() {
        let wrongHost = makeHost()
        let result = ConnectionPlanning.plan(
            targetAuth: .password("target"), jumpHostID: UUID(), jumpHost: wrongHost, jumpAuth: .password("jump"))
        assertFailure(result, .jumpHostMissing)
    }

    func testJumpHostNestedIsRejected() {
        let nestedJump = makeHost(jumpHostID: UUID())
        let result = ConnectionPlanning.plan(
            targetAuth: .password("target"), jumpHostID: nestedJump.id, jumpHost: nestedJump, jumpAuth: .password("jump"))
        assertFailure(result, .jumpHostNested)
    }

    func testJumpAuthFailed() {
        let jump = makeHost()
        let result = ConnectionPlanning.plan(
            targetAuth: .password("target"), jumpHostID: jump.id, jumpHost: jump, jumpAuth: nil)
        assertFailure(result, .jumpAuthFailed)
    }
}
