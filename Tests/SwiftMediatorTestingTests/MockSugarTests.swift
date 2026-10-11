import Testing
import SwiftMediator
import SwiftMediatorTesting

protocol Gateway: Sendable { var name: String { get } }
struct RealGateway: Gateway { let name = "real" }
struct FakeGateway: Gateway { let name = "fake" }

@Suite(.resolver { root in
    root.register(Gateway.self, lifetime: .singleton) { _ in RealGateway() }
})
struct MockSugarTests {

    @Test func mockWithInstanceReadsLikeFactory() throws {
        SimpleResolver.shared.mock(Gateway.self, with: FakeGateway())
        #expect(try SimpleResolver.shared.resolve(Gateway.self).name == "fake")
    }

    @Test func mockWithFactoryAndLifetime() throws {
        SimpleResolver.shared.mock(Gateway.self, lifetime: .singleton) { _ in FakeGateway() }
        let a: any Gateway = try SimpleResolver.shared()
        #expect(a.name == "fake")
    }

    @Test func mockIntoAnEnvironmentLeavesTheDefaultAlone() throws {
        SimpleResolver.shared.mock(Gateway.self, in: .mock, with: FakeGateway())
        #expect(try SimpleResolver.shared.resolve(Gateway.self).name == "real")
        #expect(try SimpleResolver.shared.environment(.mock).resolve(Gateway.self).name == "fake")
    }

    @Test func untouchedTestsStillSeeTheReal() throws {
        #expect(try SimpleResolver.shared.resolve(Gateway.self).name == "real")
    }
}
