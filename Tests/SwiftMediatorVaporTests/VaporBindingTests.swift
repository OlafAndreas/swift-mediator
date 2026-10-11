#if Vapor
import Testing
import Vapor
import VaporTesting
import SwiftMediatorVapor

// MARK: Fixtures

struct Echo: SwiftMediator.Request, Content {
    struct Response: Content { let text: String; let requestID: String; let scopeID: Int }
    let text: String
}

struct ScopeMarker: Sendable { let id: Int }

final class Counter: @unchecked Sendable {
    private var n = 0
    private let lock = NSLock()
    func next() -> Int { lock.withLock { n += 1; return n } }
}

/// Lazily created singleton on the app root; must be one instance for the whole app.
final class Tally: @unchecked Sendable {
    private var n = 0
    private let lock = NSLock()
    func bump() -> Int { lock.withLock { n += 1; return n } }
}
struct Bump: SwiftMediator.Request, Content { struct Response: Content { let count: Int } }

@Handler
struct BumpHandler: RequestHandler {
    let tally: Tally
    func handle(_ request: Bump) async throws -> Bump.Response { .init(count: tally.bump()) }
}

@Handler
struct EchoHandler: RequestHandler {
    let request: Vapor.Request      // pre-seeded by the binding
    let logger: Logger              // pre-seeded by the binding
    let marker: ScopeMarker         // seeded by the app
    func handle(_ request: Echo) async throws -> Echo.Response {
        logger.debug("echo")
        return .init(text: request.text, requestID: self.request.id, scopeID: marker.id)
    }
}

/// Builds an isolated app, runs `body`, and shuts the app down even if `body` throws.
func withTestApp(_ body: (Application) async throws -> Void) async throws {
    let app = try await Application.make(.testing)
    app.resolver = SimpleResolver()                          // isolated root per test
    app.mediatorDiscovery = .thisModule()
    let counter = Counter()
    app.resolver.register(Counter.self, instance: counter)
    app.seedRequests { _, scope in
        scope.register(ScopeMarker.self, instance: ScopeMarker(id: counter.next()))
    }
    app.resolver.register(Tally.self, lifetime: .singleton) { _ in Tally() }
    app.post("echo") { req in try await req.send(Echo.self) }
    app.post("bump") { req in try await req.send(Bump.self) }
    do {
        try await body(app)
    } catch {
        try? await app.asyncShutdown()
        throw error
    }
    try await app.asyncShutdown()
}

// MARK: Tests

@Suite struct VaporBindingTests {

    @Test func routeDecodesSendsAndEncodes() async throws {
        try await withTestApp { app in
            try await app.testing().test(.POST, "echo", beforeRequest: { req in
                try req.content.encode(Echo(text: "hei"))
            }) { res in
                #expect(res.status == .ok, "\(res.body.string)")
                let body = try res.content.decode(Echo.Response.self)
                #expect(body.text == "hei")
                #expect(!body.requestID.isEmpty)
            }
        }
    }

    @Test func eachRequestGetsItsOwnSeededValues() async throws {
        try await withTestApp { app in
            var seen: [Int] = []
            for _ in 0..<3 {
                try await app.testing().test(.POST, "echo", beforeRequest: { try $0.content.encode(Echo(text: "x")) }) { res in
                    seen.append(try res.content.decode(Echo.Response.self).scopeID)
                }
            }
            #expect(Set(seen).count == 3)
        }
    }

    @Test func appRootSingletonsAreSharedAcrossRequests() async throws {
        try await withTestApp { app in
            var counts: [Int] = []
            for _ in 0..<3 {
                try await app.testing().test(.POST, "bump", beforeRequest: { try $0.content.encode(Bump()) }) { res in
                    counts.append(try res.content.decode(Bump.Response.self).count)
                }
            }
            #expect(counts == [1, 2, 3], "one Tally for the app, not one per request")
        }
    }

    @Test func appMediatorIsBuiltOnceAndCanBeOverridden() async throws {
        try await withTestApp { app in
            #expect(app.mediator === app.mediator)
            app.mediator = try Mediator(resolver: app.resolver, discovery: .none) {
                $0.stub(Echo.self) { _ in .init(text: "stubbed", requestID: "-", scopeID: 0) }
            }
            try await app.testing().test(.POST, "echo", beforeRequest: { try $0.content.encode(Echo(text: "x")) }) { res in
                let body = try res.content.decode(Echo.Response.self)   // visible `try` so the closure infers `throws`
                #expect(body.text == "stubbed")
            }
        }
    }
}
#endif
