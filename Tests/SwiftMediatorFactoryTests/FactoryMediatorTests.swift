import Testing
import FactoryTesting
import SwiftMediatorFactory

/// `.container` gives every test its own task-local `Container.shared`, so handlers
/// created inside `send` see this test's registrations and tests can run in parallel.
@Suite(.container) struct FactoryMediatorTests {

    @Test func discoversAnnotatedTypes() throws {
        let types = DiscoverySection.discoveredTypes().map { "\($0)" }
        #expect(types.contains("PingHandler"))
        #expect(types.contains("OuterTracer"))
        #expect(types.contains("InnerTracer"))
        #expect(types.contains("UserCreatedHandler"))
        #expect(types.contains("AuditUserEvents"))
        #expect(types.contains("ShoutHandler"))
        #expect(types.contains("OpenClassHandler"))
        #expect(!types.contains("EchoHandler"))
    }

    @Test func mediatorIsResolvableFromFactory() {
        let a = Container.shared.mediator()
        let b = Container.shared.mediator()
        #expect(a === b)
        #expect(a.handlerType(for: Ping.self) == PingHandler.self)
    }

    @Test func sendRunsHandlerThroughBehaviorsInOrder() async throws {
        let log = Container.shared.traceLog()
        let mediator = Container.shared.mediator()

        let response = try await mediator.send(Ping(text: "verden"))

        #expect(response == "Hei verden")
        #expect(await log.lines == [
            "outer before", "inner before", "handle verden", "inner after", "outer after",
        ])
        #expect(mediator.behaviorTypes.map { "\($0)" } == ["OuterTracer", "InnerTracer"])
    }

    @Test func handlersResolveOverridesFromTheCurrentContainer() async throws {
        Container.shared.greeting.register { Greeting(word: "Hallo") }
        let mediator = Container.shared.mediator()

        #expect(try await mediator.send(Ping(text: "verden")) == "Hallo verden")
    }

    @Test func missingHandlerThrows() async throws {
        let mediator = Container.shared.mediator()
        await #expect(throws: MediatorError.self) {
            _ = try await mediator.send(Unhandled())
        }
    }

    @Test func publishFansOutWithCovariance() async throws {
        let log = Container.shared.traceLog()
        let mediator = Container.shared.mediator()

        try await mediator.publish(UserCreated(userID: 1))
        try await mediator.publish(UserDeleted(userID: 2))
        try await mediator.publish(Unrelated())

        #expect(await log.lines == [
            "created 1", "audit UserCreated 1",
            "audit UserDeleted 2",
        ])
    }

    @Test func explicitRegistrationWithoutDiscovery() async throws {
        Container.shared.mediator.register {
            Mediator.failFast(resolver: FactoryResolver(Container.shared), discovery: false) { $0.register(EchoHandler.self) }
        }
        let mediator = Container.shared.mediator()

        #expect(try await mediator.send(Echo(text: "x")) == "x")
        #expect(mediator.behaviorTypes.isEmpty)
        await #expect(throws: MediatorError.self) {
            _ = try await mediator.send(Ping(text: "no handler without discovery"))
        }
    }

    @Test func plainStoredPropertiesResolveThroughFactoryResolving() async throws {
        Container.shared.register(Clock.self) { Clock(now: "12:00") }
        let mediator = Container.shared.mediator()
        #expect(try await mediator.send(WhatTime()) == "12:00")
    }

    @Test func unregisteredPlainPropertyThrowsResolverError() async throws {
        let mediator = Container.shared.mediator()
        await #expect(throws: ResolverError.self) { _ = try await mediator.send(WhatTime()) }
    }

    @Test func classHandlersGetRequiredInit() async throws {
        let mediator = Container.shared.mediator()
        #expect(try await mediator.send(Shout(text: "hei")) == "HEI!")
        #expect(mediator.eventHandlerTypes.contains { $0 == OpenClassHandler.self })
    }

    @Test func conflictingHandlersFailAtInit() throws {
        #expect(throws: MediatorError.self) {
            try Mediator(resolver: FactoryResolver(Container.shared), discovery: false) {
                $0.register(EchoHandler.self)
                $0.register(SecondEchoHandler.self)
            }
        }
    }
}
