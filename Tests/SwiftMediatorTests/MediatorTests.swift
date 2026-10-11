import Testing
@testable import SwiftMediator

@Suite struct MediatorTests {

    func makeResolver() -> (SimpleResolver, TraceLog) {
        let log = TraceLog()
        let resolver = SimpleResolver()
        resolver.register(TraceLog.self, instance: log)
        resolver.register(Greeting.self, instance: Greeting(word: "Hei"))
        resolver.register(UnitOfWork.self, lifetime: .scoped) { _ in UnitOfWork(id: 0) }   // for discovered UnitObserver
        return (resolver, log)
    }

    @Test func discoversAnnotatedTypes() throws {
        let types = DiscoverySection.discoveredTypes(.thisModule()).map { "\($0)" }
        for expected in ["PingHandler", "OuterTracer", "InnerTracer", "UserCreatedHandler",
                         "AuditUserEvents", "CustomInitHandler", "OpenClassHandler",
                         "WhichUnitHandler", "UnitObserver", "ChainHandler", "ChainedHandler"] {
            #expect(types.contains(expected), "\(expected) missing")
        }
        #expect(!types.contains("EchoHandler"))
    }

    @Test func sendRunsHandlerThroughBehaviorsInOrder() async throws {
        let (resolver, log) = makeResolver()
        let mediator = try Mediator(resolver: resolver, discovery: .thisModule())

        let response = try await mediator.send(Ping(text: "verden"))

        #expect(response == "Hei verden")
        #expect(await log.lines == [
            "outer before", "inner before", "handle verden", "inner after", "outer after",
        ])
        #expect(mediator.behaviorTypes.map { "\($0)" } == ["OuterTracer", "UnitObserver", "InnerTracer"])
    }

    @Test func missingHandlerThrows() async throws {
        let (resolver, _) = makeResolver()
        let mediator = try Mediator(resolver: resolver, discovery: .thisModule())
        await #expect(throws: MediatorError.self) { _ = try await mediator.send(Unhandled()) }
    }

    @Test func publishFansOutWithCovariance() async throws {
        let (resolver, log) = makeResolver()
        let mediator = try Mediator(resolver: resolver, discovery: .thisModule())

        try await mediator.publish(UserCreated(userID: 1))
        try await mediator.publish(UserDeleted(userID: 2))
        try await mediator.publish(Unrelated())

        #expect(await log.lines == [
            "created 1", "audit UserCreated 1",
            "audit UserDeleted 2",
            "unrelated",
        ])
    }

    @Test func explicitRegistrationWithoutDiscovery() async throws {
        let (resolver, _) = makeResolver()
        let mediator = try Mediator(resolver: resolver, discovery: false) { $0.register(EchoHandler.self) }

        #expect(try await mediator.send(Echo(text: "x")) == "x")
        #expect(mediator.behaviorTypes.isEmpty)
        await #expect(throws: MediatorError.self) { _ = try await mediator.send(Ping(text: "x")) }
    }

    @Test func macroRespectsExistingResolverInit() async throws {
        let (resolver, _) = makeResolver()
        let mediator = try Mediator(resolver: resolver, discovery: .thisModule())
        #expect(try await mediator.send(Shout(text: "hei")) == "HEI!")
    }

    @Test func conflictingHandlersFailAtInit() throws {
        let (resolver, _) = makeResolver()
        #expect(throws: MediatorError.self) {
            try Mediator(resolver: resolver, discovery: false) {
                $0.register(EchoHandler.self)
                $0.register(SecondEchoHandler.self)
            }
        }
    }

    @Test func annotatedNonHandlerFailsAtInit() throws {
        struct NotAHandler {}
        let (resolver, _) = makeResolver()
        #expect(throws: MediatorError.self) {
            try Mediator(resolver: resolver, discovery: false) {
                $0.register(discovered: NotAHandler.self)
            }
        }
    }

    @Test func unresolvedDependencySurfacesResolverError() async throws {
        let mediator = try Mediator(resolver: SimpleResolver(), discovery: .thisModule())   // nothing registered
        await #expect(throws: ResolverError.self) { _ = try await mediator.send(Ping(text: "x")) }
    }
}
