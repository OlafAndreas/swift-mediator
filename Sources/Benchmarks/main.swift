// Run with: swift run -c release Benchmarks
import SwiftMediator

struct Add: Request { typealias Response = Int; let a: Int; let b: Int }
struct Added: Event { let sum: Int }
struct Ignored: Event {}

final class Sink: @unchecked Sendable { var total = 0 }

@Handler
struct AddHandler: RequestHandler {
    func handle(_ request: Add) async throws -> Int { request.a &+ request.b }
}

@Handler
struct SumListener: EventHandler {
    let sink: Sink
    func handle(_ event: Added) async throws { sink.total &+= event.sum }
}

struct PassThrough: PipelineBehavior {
    init(resolver: any Resolver) throws {}
    func handle<R: Request>(_ request: R, next: Next<R>) async throws -> R.Response { try await next(request) }
}
struct PassThrough2: PipelineBehavior {
    init(resolver: any Resolver) throws {}
    func handle<R: Request>(_ request: R, next: Next<R>) async throws -> R.Response { try await next(request) }
}
struct PassThrough3: PipelineBehavior {
    init(resolver: any Resolver) throws {}
    func handle<R: Request>(_ request: R, next: Next<R>) async throws -> R.Response { try await next(request) }
}

struct Scoped: Sendable { let n: Int }
struct AddScoped: Request { typealias Response = Int; let a: Int }
struct AddScopedHandler: RequestHandler {
    let scoped: Scoped
    init(resolver: any Resolver) throws { scoped = try resolver() }
    func handle(_ request: AddScoped) async throws -> Int { request.a &+ scoped.n }
}

func measure(_ name: String, iterations: Int, _ body: () async throws -> Void) async throws {
    for _ in 0..<min(iterations / 10, 10_000) { try await body() }          // warm up
    let start = ContinuousClock.now
    for _ in 0..<iterations { try await body() }
    let elapsed = ContinuousClock.now - start
    let ns = Double(elapsed.components.attoseconds) / 1e9 + Double(elapsed.components.seconds) * 1e9
    print("\(name.padding(toLength: 44, withPad: " ", startingAt: 0)) \(String(format: "%8.0f", ns / Double(iterations))) ns/op")
}

// Top-level code in main.swift is main-actor isolated, so every `await` would hop executors
// and the harness would measure the hop, not the mediator. Run off the main actor.
try await Task.detached {
    let iterations = 1_000_000
    let resolver = SimpleResolver()
    resolver.register(Sink.self, instance: Sink())
    resolver.register(Scoped.self, lifetime: .scoped) { _ in Scoped(n: 1) }

    let bare = try Mediator(resolver: resolver, discovery: false) { $0.register(AddHandler.self) }
    let three = try Mediator(resolver: resolver, discovery: false) {
        $0.register(AddHandler.self); $0.register(PassThrough.self); $0.register(PassThrough2.self); $0.register(PassThrough3.self)
    }
    let scopedMediator = try Mediator(resolver: resolver, discovery: false) { $0.register(AddScopedHandler.self) }
    let events = try Mediator(resolver: resolver, discovery: false) { $0.register(SumListener.self) }
    let handler = try AddHandler(resolver: resolver)

    print("SwiftMediator micro-benchmarks, \(iterations) iterations each, release build\n")
    var sink = 0
    try await measure("direct handler call (baseline)", iterations: iterations) { sink &+= try await handler.handle(Add(a: 1, b: 2)) }
    try await measure("send, no behaviors", iterations: iterations) { sink &+= try await bare.send(Add(a: 1, b: 2)) }
    try await measure("send, 3 pass-through behaviors", iterations: iterations) { sink &+= try await three.send(Add(a: 1, b: 2)) }
    try await measure("send, handler with 1 scoped dependency", iterations: iterations) { sink &+= try await scopedMediator.send(AddScoped(a: 1)) }
    try await measure("publish, 1 matching handler", iterations: iterations) { try await events.publish(Added(sum: 1)) }
    try await measure("publish, 0 matching handlers", iterations: iterations) { try await events.publish(Ignored()) }
    print("\n(checksum \(sink))")
}.value
