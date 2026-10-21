import Testing
@testable import SwiftMediator

@Suite struct SendWithTests {

    @Test func perCallValuesReachTheHandler() async throws {
        let base = SimpleResolver()
        base.register(TraceLog.self, instance: TraceLog())          // only Greeting is missing
        base.register(UnitOfWork.self, lifetime: .scoped) { _ in UnitOfWork(id: 0) }
        let mediator = try Mediator(resolver: base, discovery: .thisModule())

        let response = try await mediator.send(Ping(text: "verden")) {
            $0.register(Greeting.self, instance: Greeting(word: "Hallo"))
        }

        #expect(response == "Hallo verden")
        #expect(throws: ResolverError.self) { try base.resolve(Greeting.self) }
    }

    @Test func perCallValuesWinOverTheBase() async throws {
        let base = SimpleResolver()
        base.register(TraceLog.self, instance: TraceLog())
        base.register(Greeting.self, instance: Greeting(word: "Hei"))
        base.register(UnitOfWork.self, lifetime: .scoped) { _ in UnitOfWork(id: 0) }
        let mediator = try Mediator(resolver: base, discovery: .thisModule())

        let response = try await mediator.send(Ping(text: "verden")) {
            $0.register(Greeting.self, instance: Greeting(word: "Hallo"))
        }

        #expect(response == "Hallo verden")
        #expect(try await mediator.send(Ping(text: "verden")) == "Hei verden")
    }

    @Test func baseScopesStillApply() async throws {
        let counter = Counter()
        let base = SimpleResolver()
        base.register(TraceLog.self, instance: TraceLog())
        base.register(UnitOfWork.self, lifetime: .scoped) { _ in UnitOfWork(id: counter.take()) }
        let mediator = try Mediator(resolver: base, discovery: .thisModule())

        let ids = try await mediator.send(WhichUnit()) {
            $0.register(Clock.self, instance: Clock(id: 100))
            $0.register(Stamp.self, instance: Stamp(id: 200))
        }

        #expect(ids == [1, 100, 200, 1])        // handler and UnitObserver share one UnitOfWork
    }

    @Test func nestedCallsSeePerCallValues() async throws {
        let base = SimpleResolver()
        base.register(TraceLog.self, instance: TraceLog())
        let mediator = try Mediator(resolver: base, discovery: .thisModule())

        let result = try await mediator.send(Chain()) {
            $0.register(UnitOfWork.self, instance: UnitOfWork(id: 7))
        }

        #expect(result.outer == 7)
        #expect(result.inner == 7)                  // ChainedHandler, reached through a nested publish
    }

    @Test func perCallScopedValuesAreSharedWithinTheCall() async throws {
        let counter = Counter()
        let base = SimpleResolver()
        base.register(TraceLog.self, instance: TraceLog())
        base.register(Clock.self, instance: Clock(id: 100))
        base.register(Stamp.self, instance: Stamp(id: 200))
        let mediator = try Mediator(resolver: base, discovery: .thisModule())

        let ids = try await mediator.send(WhichUnit()) {
            $0.register(UnitOfWork.self, lifetime: .scoped) { _ in UnitOfWork(id: counter.take()) }
        }

        #expect(ids == [1, 100, 200, 1])
    }
}
