import SwiftMediator

actor TraceLog {
    private(set) var lines: [String] = []
    func append(_ line: String) { lines.append(line) }
}

struct Greeting: Sendable { let word: String }

// MARK: Requests

struct Ping: Request {
    typealias Response = String
    let text: String
}

struct Unhandled: Request { typealias Response = Int }

@Handler
struct PingHandler: RequestHandler {
    let greeting: Greeting      // resolved by type via init(resolver:)
    let log: TraceLog

    func handle(_ request: Ping) async throws -> String {
        await log.append("handle \(request.text)")
        return "\(greeting.word) \(request.text)"
    }
}

// MARK: Behaviors

@Behavior
struct OuterTracer: PipelineBehavior {
    let log: TraceLog
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
    let log: TraceLog
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
    let log: TraceLog
    func handle(_ event: UserCreated) async throws { await log.append("created \(event.userID)") }
}

/// Subscribes to a protocol existential: receives every `UserEvent`.
@Handler
struct AuditUserEvents: EventHandler {
    let log: TraceLog
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

// MARK: Hand-written init(resolver:) and class handlers

struct Shout: Request {
    typealias Response = String
    let text: String
}

@Handler
struct CustomInitHandler: RequestHandler {
    let suffix: String
    init(resolver: any Resolver) throws { suffix = "!" }
    func handle(_ request: Shout) async throws -> String { request.text.uppercased() + suffix }
}

@Handler
class OpenClassHandler: EventHandler, @unchecked Sendable {
    let log: TraceLog
    func handle(_ event: Unrelated) async throws { await log.append("unrelated") }
}
