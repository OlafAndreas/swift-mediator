import SwiftMediator
import Foundation

/// Captures every event a mediator publishes.
///
///     let events = EventRecorder()
///     let mediator = try Mediator { $0.record(events) }
///     try await mediator.send(PlaceOrder(...))
///     #expect(events.published(OrderPlaced.self).count == 1)
public final class EventRecorder: @unchecked Sendable {
    private var storage: [any Event] = []
    private let lock = NSLock()

    public init() {}

    func record(_ event: any Event) { lock.withLock { storage.append(event) } }

    /// Everything published so far, in order.
    public var events: [any Event] { lock.withLock { storage } }

    /// Published events of one type, in order.
    public func published<E: Event>(_ type: E.Type) -> [E] { events.compactMap { $0 as? E } }

    /// The single published event of a type. Fails the cast when there are zero or several.
    public func only<E: Event>(_ type: E.Type) -> E? {
        let matches = published(type)
        return matches.count == 1 ? matches[0] : nil
    }

    public func reset() { lock.withLock { storage.removeAll() } }
}

/// Logs every request that passes through the pipeline, as a behavior.
///
///     let requests = RequestRecorder()
///     let mediator = try Mediator { $0.register(instance: requests) }
///     ...
///     #expect(requests.names == ["PlaceOrder", "GetOrder"])
public final class RequestRecorder: PipelineBehavior, @unchecked Sendable {
    private var storage: [any Request] = []
    private let lock = NSLock()

    public static var order: Int { Int.min }   // outermost, sees everything including rejections

    public init() {}
    public convenience init(resolver: any Resolver) throws { self.init() }

    public func handle<R: Request>(_ request: R, next: Next<R>) async throws -> R.Response {
        lock.withLock { storage.append(request) }
        return try await next(request)
    }

    public var requests: [any Request] { lock.withLock { storage } }
    public var names: [String] { requests.map { "\(type(of: $0))" } }
    public func sent<R: Request>(_ type: R.Type) -> [R] { requests.compactMap { $0 as? R } }
    public func reset() { lock.withLock { storage.removeAll() } }
}

public extension Mediator.Configuration {
    /// Routes every published event into `recorder`.
    mutating func record(_ recorder: EventRecorder) {
        onEvent { recorder.record($0) }
    }
}
