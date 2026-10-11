import Testing
import SwiftMediator

@Suite struct ExcludeTests {

    func makeResolver() -> (SimpleResolver, TraceLog) {
        let log = TraceLog()
        let resolver = SimpleResolver()
        resolver.register(TraceLog.self, instance: log)
        resolver.register(Greeting.self, instance: Greeting(word: "Hei"))
        resolver.register(UnitOfWork.self, lifetime: .scoped) { _ in UnitOfWork(id: 0) }
        return (resolver, log)
    }

    @Test func excludedBehaviorIsNotRun() async throws {
        let (resolver, log) = makeResolver()
        let mediator = try Mediator(resolver: resolver) { config in
            config.exclude(OuterTracer.self)
            config.exclude(UnitObserver.self)
        }

        _ = try await mediator.send(Ping(text: "x"))

        #expect(mediator.behaviorTypes.map { "\($0)" } == ["InnerTracer"])
        #expect(await log.lines == ["inner before", "handle x", "inner after"])
    }

    @Test func excludedRequestHandlerLeavesTheRequestUnhandled() async throws {
        let (resolver, _) = makeResolver()
        let mediator = try Mediator(resolver: resolver) { $0.exclude(PingHandler.self) }

        #expect(mediator.handlerType(for: Ping.self) == nil)
        await #expect(throws: MediatorError.self) { _ = try await mediator.send(Ping(text: "x")) }
    }

    @Test func excludedEventHandlerIsSkipped() async throws {
        let (resolver, log) = makeResolver()
        let mediator = try Mediator(resolver: resolver) { $0.exclude(AuditUserEvents.self) }

        try await mediator.publish(UserCreated(userID: 7))

        #expect(await log.lines == ["created 7"])
    }

    @Test func excludeAlsoIgnoresLaterRegistration() async throws {
        let (resolver, _) = makeResolver()
        let mediator = try Mediator(resolver: resolver, discovery: false) { config in
            config.exclude(InnerTracer.self)
            config.register(InnerTracer.self)        // ignored
            config.register(OuterTracer.self)
        }
        #expect(mediator.behaviorTypes.map { "\($0)" } == ["OuterTracer"])
    }

    @Test func excludeResolvesAConflict() throws {
        struct A: RequestHandler {
            init(resolver: any Resolver) throws {}
            func handle(_ request: Echo) async throws -> String { "a" }
        }
        let (resolver, _) = makeResolver()
        let mediator = try Mediator(resolver: resolver, discovery: false) { config in
            config.register(EchoHandler.self)
            config.register(A.self)
            config.exclude(A.self)
        }
        #expect(mediator.handlerType(for: Echo.self) == EchoHandler.self)
    }
}
