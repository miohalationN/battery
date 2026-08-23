import Testing
@testable import TelemetryCore

@Suite struct HelperAuthorizationTests {
    @Test func requiresIdentifierAndExactInstalledClientHash() {
        #expect(HelperAuthorization.allows(
            identifier: "com.batterybar.app",
            actualCDHash: "A1B2",
            expectedCDHash: "a1b2"
        ))
        #expect(!HelperAuthorization.allows(
            identifier: "com.batterybar.app",
            actualCDHash: "attacker",
            expectedCDHash: "trusted"
        ))
        #expect(!HelperAuthorization.allows(
            identifier: "com.example.copy",
            actualCDHash: "trusted",
            expectedCDHash: "trusted"
        ))
        #expect(!HelperAuthorization.allows(
            identifier: "com.batterybar.app",
            actualCDHash: "trusted",
            expectedCDHash: nil
        ))
    }
}
