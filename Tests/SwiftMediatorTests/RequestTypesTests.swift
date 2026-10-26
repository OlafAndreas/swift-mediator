import Testing
import SwiftMediator

@Suite struct RequestTypesTests {

    func names(_ mediator: Mediator) -> [String] {
        mediator.requestTypes.map { "\($0)" }
    }

    @Test func listsDiscoveredRequests() throws {
        let mediator = try Mediator(resolver: SimpleResolver(), discovery: .thisModule())

        #expect(names(mediator).contains("Ping"))
        #expect(!names(mediator).contains("Unhandled"))
        #expect(!names(mediator).contains("Echo"))
    }

    @Test func omitsRequestsWhoseHandlerIsExcluded() throws {
        let mediator = try Mediator(resolver: SimpleResolver(), discovery: .thisModule()) {
            $0.exclude(PingHandler.self)
        }

        #expect(!names(mediator).contains("Ping"))
    }

    @Test func listsExplicitRegistrationsAndStubs() throws {
        let mediator = try Mediator(resolver: SimpleResolver(), discovery: false) { config in
            config.register(EchoHandler.self)
            config.stub(Unhandled.self) { _ in 1 }
        }

        #expect(names(mediator) == ["Echo", "Unhandled"])
    }

    @Test func listsEachRequestOnceInNameOrder() throws {
        let mediator = try Mediator(resolver: SimpleResolver(), discovery: false) { config in
            config.stub(Unhandled.self) { _ in 1 }
            config.register(EchoHandler.self)
            config.stub(Unhandled.self) { _ in 2 }
        }

        #expect(names(mediator) == ["Echo", "Unhandled"])
    }

    @Test func boundMediatorListsTheSameRequests() throws {
        let mediator = try Mediator(resolver: SimpleResolver(), discovery: false) { $0.register(EchoHandler.self) }

        #expect(names(mediator.bound(to: SimpleResolver())) == ["Echo"])
    }
}
