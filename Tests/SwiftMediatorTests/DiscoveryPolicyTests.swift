import Testing
import SwiftMediator

@Suite struct DiscoveryPolicyTests {

    @Test func moduleNameComesFromTheQualifiedName() {
        #expect(Discovery.moduleName(of: PingHandler.self) == "SwiftMediatorTests")
        #expect(Discovery.moduleName(of: Orders.Deeper.TwiceHandler.self) == "SwiftMediatorTests")
        #expect(Discovery.moduleName(of: Mediator.self) == "SwiftMediator")
    }

    @Test func thisModuleAdmitsOnlyLocalTypes() {
        let policy = Discovery.thisModule()
        #expect(policy(PingHandler.self))
        #expect(!policy(Mediator.self))
        #expect(DiscoverySection.discoveredTypes(policy).allSatisfy { Discovery.moduleName(of: $0) == "SwiftMediatorTests" })
    }

    @Test func noneRegistersNothing() throws {
        let mediator = try Mediator(resolver: SimpleResolver(), discovery: .none)
        #expect(mediator.behaviorTypes.isEmpty && mediator.eventHandlerTypes.isEmpty)
        #expect(mediator.handlerType(for: Ping.self) == nil)
    }

    @Test func boolConvenienceStillWorks() throws {
        let off = try Mediator(resolver: SimpleResolver(), discovery: false)
        #expect(off.handlerType(for: Ping.self) == nil)
    }
}
