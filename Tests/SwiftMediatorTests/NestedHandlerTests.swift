import Testing
import SwiftMediator

/// Handlers nested in a namespace enum, two levels deep, and in an extension.
enum Orders {
    struct Count: Request { typealias Response = Int }

    @Handler
    struct CountHandler: RequestHandler {
        func handle(_ request: Count) async throws -> Int { 42 }
    }

    enum Deeper {
        struct Twice: Request { typealias Response = Int; let n: Int }

        @Handler
        struct TwiceHandler: RequestHandler {
            func handle(_ request: Twice) async throws -> Int { request.n * 2 }
        }
    }
}

extension Orders {
    struct Shouted: Event { let text: String }

    @Handler
    struct ShoutListener: EventHandler {
        let log: TraceLog
        func handle(_ event: Shouted) async throws { await log.append(event.text.uppercased()) }
    }
}

@Suite struct NestedHandlerTests {

    @Test func nestedTypesAreDiscovered() {
        // String(describing:) prints only the innermost name; the qualified form needs reflecting.
        let names = DiscoverySection.discoveredTypes(.thisModule()).map { String(reflecting: $0) }
        #expect(names.contains { $0.hasSuffix("Orders.CountHandler") })
        #expect(names.contains { $0.hasSuffix("Orders.Deeper.TwiceHandler") })
        #expect(names.contains { $0.hasSuffix("Orders.ShoutListener") })
    }

    @Test func nestedHandlersDispatch() async throws {
        let log = TraceLog()
        let resolver = SimpleResolver()
        resolver.register(TraceLog.self, instance: log)
        resolver.register(Greeting.self, instance: Greeting(word: "Hei"))
        resolver.register(UnitOfWork.self, lifetime: .scoped) { _ in UnitOfWork(id: 0) }
        let mediator = try Mediator(resolver: resolver, discovery: .thisModule())

        #expect(try await mediator.send(Orders.Count()) == 42)
        #expect(try await mediator.send(Orders.Deeper.Twice(n: 21)) == 42)
        try await mediator.publish(Orders.Shouted(text: "hei"))
        #expect(await log.lines.contains("HEI"))   // the log also holds the tracer behaviors' lines
    }
}
