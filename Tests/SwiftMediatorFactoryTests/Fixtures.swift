import SwiftMediatorFactory   // re-exports FactoryKit and SwiftMediator

// MARK: Dependencies, registered with Factory

actor TraceLog {
    private(set) var lines: [String] = []
    func append(_ line: String) { lines.append(line) }
}

struct Greeting: Sendable { let word: String }

extension Container {
    var traceLog: Factory<TraceLog> { self { TraceLog() }.cached }
    var greeting: Factory<Greeting> { self { Greeting(word: "Hei") } }
}

// MARK: Requests

struct Ping: Request {
    typealias Response = String
    let text: String
}

struct Unhandled: Request {
    typealias Response = Int
}

@Handler
struct PingHandler: RequestHandler {
    @Injected(\.greeting) private var greeting
    @Injected(\.traceLog) private var log

    func handle(_ request: Ping) async throws -> String {
        await log.append("handle \(request.text)")
        return "\(greeting.word) \(request.text)"
    }
}

// MARK: Behaviors

@Behavior
struct OuterTracer: PipelineBehavior {
    @Injected(\.traceLog) private var log
    static var order: Int { -10 }

    func handle<R: Request>(_ request: R, next: Next<R>) async throws -> R.Response {
        await log.append("outer before")
        let response = try await next(request)
        await log.append("outer after")
        return response
    }
}

@Behavior
struct InnerTracer: PipelineBehavior {
    @Injected(\.traceLog) private var log
    static var order: Int { 10 }

    func handle<R: Request>(_ request: R, next: Next<R>) async throws -> R.Response {
        await log.append("inner before")
        let response = try await next(request)
        await log.append("inner after")
        return response
    }
}

// MARK: Events

protocol UserEvent: Event { var userID: Int { get } }
struct UserCreated: UserEvent { let userID: Int }
struct UserDeleted: UserEvent { let userID: Int }
struct Unrelated: Event {}

@Handler
struct UserCreatedHandler: EventHandler {
    @Injected(\.traceLog) private var log
    func handle(_ event: UserCreated) async throws {
        await log.append("created \(event.userID)")
    }
}

/// Subscribes to a protocol existential: receives every `UserEvent`.
@Handler
struct AuditUserEvents: EventHandler {
    @Injected(\.traceLog) private var log
    func handle(_ event: any UserEvent) async throws {
        await log.append("audit \(type(of: event)) \(event.userID)")
    }
}

// MARK: Explicit registration only (not annotated)

struct Echo: Request {
    typealias Response = String
    let text: String
}

struct EchoHandler: RequestHandler {
    init(resolver: any Resolver) throws {}
    func handle(_ request: Echo) async throws -> String { request.text }
}

struct SecondEchoHandler: RequestHandler {
    init(resolver: any Resolver) throws {}
    func handle(_ request: Echo) async throws -> String { "other" }
}

// MARK: Plain stored property, resolved by type through Factory's `Resolving`

extension Container: @retroactive Resolving {}

struct Clock: Sendable { let now: String }

struct WhatTime: Request { typealias Response = String }

@Handler
struct WhatTimeHandler: RequestHandler {
    let clock: Clock                      // not @Injected: goes through FactoryResolver
    func handle(_ request: WhatTime) async throws -> String { clock.now }
}

// MARK: Class handler: macro must add `required init(resolver:)`

struct Shout: Request {
    typealias Response = String
    let text: String
}

@Handler
final class ShoutHandler: RequestHandler {
    func handle(_ request: Shout) async throws -> String { request.text.uppercased() + "!" }
}

@Handler
class OpenClassHandler: EventHandler, @unchecked Sendable {
    func handle(_ event: Unrelated) async throws {}
}
