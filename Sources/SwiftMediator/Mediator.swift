import Foundation
import SwiftDiscoveryCore
public enum MediatorError: Error, CustomStringConvertible {
    /// `send` was called for a request with no registered handler.
    case noHandler(request: Any.Type)
    /// Two or more handlers claim the same request. Thrown by `Mediator.init`.
    case conflictingHandlers(request: Any.Type, handlers: [Any.Type])
    /// A discovered type conforms to none of the handler protocols. Thrown by `Mediator.init`.
    case notAHandler(type: Any.Type)

    public var description: String {
        switch self {
        case .noHandler(let request):
            "No RequestHandler registered for \(request)"
        case .conflictingHandlers(let request, let handlers):
            "Multiple RequestHandlers registered for \(request): \(handlers)"
        case .notAHandler(let type):
            "\(type) is marked @Handler/@Behavior but conforms to none of RequestHandler, EventHandler, PipelineBehavior"
        }
    }
}

extension MediatorError: LocalizedError {
    public var errorDescription: String? { description }
}

/// Dispatches requests to their single handler through a pipeline of behaviors, and
/// broadcasts events to every matching event handler.
///
/// The registry is built once in `init` and is immutable afterwards, so the mediator is
/// `Sendable` without locking. Each `send` / `publish` opens one resolver scope and
/// instantiates the handler and every behavior through it, so `.scoped` registrations
/// are shared within a call and released afterwards.
///
/// Configuration mistakes fail fast: `init` throws if two handlers claim the same request
/// or if an annotated type is not actually a handler.
public final class Mediator: Sendable {

    // MARK: Configuration

    public struct Configuration: Sendable {
        struct RequestEntry: Sendable {
            let requestType: any Request.Type
            let handlerType: Any.Type
            let make: @Sendable (any Resolver) throws -> any Sendable
        }
        struct EventEntry: Sendable {
            let handlerType: Any.Type
            let matches: @Sendable (Any) -> Bool
            let make: @Sendable (any Resolver) throws -> @Sendable (Any) async throws -> Void
        }
        struct BehaviorEntry: Sendable {
            let behaviorType: Any.Type
            let order: Int
            let make: @Sendable (any Resolver) throws -> any PipelineBehavior
        }

        var requests: [ObjectIdentifier: [RequestEntry]] = [:]
        var stubbed: Set<ObjectIdentifier> = []
        var excluded: Set<ObjectIdentifier> = []
        var events: [EventEntry] = []
        var behaviors: [BehaviorEntry] = []
        var unrecognized: [Any.Type] = []

        public init() {}

        /// Scans the binary for `@Handler` / `@Behavior` records and registers those the
        /// policy admits.
        public mutating func discover(_ policy: Discovery = .all) {
            for type in Mediator.discoveredTypes(policy) {
                register(discovered: type)
            }
        }

        /// Registers a runtime-discovered type, dispatching on which protocol it conforms to.
        /// Returns `false` if the type conforms to none of the handler protocols.
        @discardableResult
        public mutating func register(discovered type: Any.Type) -> Bool {
            if let t = type as? any RequestHandler.Type { register(t); return true }
            if let t = type as? any EventHandler.Type { register(t); return true }
            if let t = type as? any PipelineBehavior.Type { register(t); return true }
            unrecognized.append(type)
            return false
        }

        public mutating func register<H: RequestHandler>(_ type: H.Type) {
            let key = ObjectIdentifier(H.Req.self)
            if stubbed.contains(key) || excluded.contains(ObjectIdentifier(H.self)) { return }
            if requests[key]?.contains(where: { $0.handlerType == H.self }) == true { return }
            requests[key, default: []].append(RequestEntry(requestType: H.Req.self, handlerType: H.self) { resolver in
                let handler = try H(resolver: resolver)
                return AnyRequestHandler<H.Req> { try await handler.handle($0) }
            })
        }

        public mutating func register<H: EventHandler>(_ type: H.Type) {
            if excluded.contains(ObjectIdentifier(H.self)) { return }
            if events.contains(where: { $0.handlerType == H.self }) { return }
            events.append(EventEntry(
                handlerType: H.self,
                matches: { $0 is H.Note },
                make: { resolver in
                    let handler = try H(resolver: resolver)
                    return { event in try await handler.handle(event as! H.Note) }
                }
            ))
        }

        public mutating func register<B: PipelineBehavior>(_ type: B.Type) {
            if excluded.contains(ObjectIdentifier(B.self)) { return }
            if behaviors.contains(where: { $0.behaviorType == B.self }) { return }
            behaviors.append(BehaviorEntry(behaviorType: B.self, order: B.order) { try B(resolver: $0) })
        }

        /// Uses one specific behavior instance for every `send` instead of creating one per
        /// call. Handy for recorders and other stateful test doubles.
        public mutating func register<B: PipelineBehavior>(instance behavior: B) {
            behaviors.append(BehaviorEntry(behaviorType: B.self, order: B.order) { _ in behavior })
        }

        /// Removes a discovered or registered handler or behavior, and ignores any later
        /// registration of it. Typical use: `config.exclude(Validation.self)` to test a handler
        /// without the pipeline getting in the way.
        public mutating func exclude(_ type: Any.Type) {
            let id = ObjectIdentifier(type)
            excluded.insert(id)
            behaviors.removeAll { ObjectIdentifier($0.behaviorType) == id }
            events.removeAll { ObjectIdentifier($0.handlerType) == id }
            for (key, entries) in requests {
                let kept = entries.filter { ObjectIdentifier($0.handlerType) != id }
                if kept.isEmpty { requests[key] = nil } else { requests[key] = kept }
            }
        }

        /// Answers `R` with a closure instead of a handler type. Replaces any discovered or
        /// registered handler for `R`, and suppresses later registrations for it. This is
        /// the equivalent of mocking `IMediator.Send` for one request type.
        public mutating func stub<R: Request>(
            _ request: R.Type,
            _ handle: @escaping @Sendable (R) async throws -> R.Response
        ) {
            let key = ObjectIdentifier(R.self)
            stubbed.insert(key)
            requests[key] = [RequestEntry(requestType: R.self, handlerType: Stub<R>.self) { _ in
                AnyRequestHandler<R>(handle)
            }]
        }

        /// Observes every published event with a closure. Runs after type-registered handlers
        /// that were added before it, in registration order like any other event handler.
        public mutating func onEvent(_ observe: @escaping @Sendable (any Event) async throws -> Void) {
            events.append(EventEntry(
                handlerType: EventObserver.self,
                matches: { _ in true },
                make: { _ in { event in try await observe(event as! any Event) } }
            ))
        }

        /// Marker types so introspection can name stubs and observers.
        public enum Stub<R: Request> {}
        public enum EventObserver {}
    }

    // MARK: State

    private let resolver: any Resolver
    private let requests: [ObjectIdentifier: Configuration.RequestEntry]
    private let events: [Configuration.EventEntry]
    private let behaviors: [Configuration.BehaviorEntry]

    /// - Parameters:
    ///   - resolver: Supplies dependencies to handlers and behaviors. Defaults to the
    ///     task-local `SimpleResolver.shared`, the app's composition root.
    ///   - discovery: Which `@Handler` / `@Behavior` records to register. `.all` by default;
    ///     `.thisModule()` or `.modules([...])` when several independent modules share a binary.
    ///   - configure: Explicit registrations, stubs and observers, applied after discovery.
    /// - Throws: `MediatorError.conflictingHandlers` or `MediatorError.notAHandler`.
    public init(
        resolver: any Resolver = SimpleResolver.shared,
        discovery: Discovery = .all,
        configure: (inout Configuration) -> Void = { _ in }
    ) throws {
        var configuration = Configuration()
        configuration.discover(discovery)
        configure(&configuration)

        if let stray = configuration.unrecognized.first {
            throw MediatorError.notAHandler(type: stray)
        }

        var requests: [ObjectIdentifier: Configuration.RequestEntry] = [:]
        for (key, entries) in configuration.requests {
            guard entries.count == 1 else {
                throw MediatorError.conflictingHandlers(
                    request: entries[0].requestType,
                    handlers: entries.map(\.handlerType)
                )
            }
            requests[key] = entries[0]
        }

        self.resolver = resolver
        self.requests = requests
        self.events = configuration.events
        self.behaviors = configuration.behaviors.sorted { $0.order < $1.order }
    }

    /// Convenience: `discovery: false` registers nothing automatically.
    public convenience init(
        resolver: any Resolver = SimpleResolver.shared,
        discovery: Bool,
        configure: (inout Configuration) -> Void = { _ in }
    ) throws {
        try self.init(resolver: resolver, discovery: discovery ? .all : .none, configure: configure)
    }

    /// Same as `init`, but terminates the process on a configuration error instead of
    /// throwing. For a mediator kept for the whole process, and for Factory closures and
    /// other non-throwing composition roots:
    ///
    ///     static let shared = Mediator.failFast()
    public static func failFast(
        resolver: any Resolver = SimpleResolver.shared,
        discovery: Discovery = .all,
        configure: (inout Configuration) -> Void = { _ in }
    ) -> Mediator {
        do {
            return try Mediator(resolver: resolver, discovery: discovery, configure: configure)
        } catch {
            fatalError("SwiftMediator configuration error: \(error)")
        }
    }

    public static func failFast(
        resolver: any Resolver = SimpleResolver.shared,
        discovery: Bool,
        configure: (inout Configuration) -> Void = { _ in }
    ) -> Mediator {
        failFast(resolver: resolver, discovery: discovery ? .all : .none, configure: configure)
    }

    /// A view of `parent` that resolves through `scope`. Handed to handlers that inject
    /// `Mediator`, so nested `send` / `publish` calls share the outer call's scope.
    private init(parent: Mediator, scope: any Resolver) {
        self.resolver = scope
        self.requests = parent.requests
        self.events = parent.events
        self.behaviors = parent.behaviors
    }

    /// The same registry, resolving through `resolver` instead of this mediator's own.
    ///
    /// Used internally so that a `Mediator` injected into a handler shares the handler's
    /// scope, and by integrations that have per-request values to offer: build a child
    /// resolver, register the request's values on it, and bind. Cheap: no copying.
    public func bound(to resolver: any Resolver) -> Mediator {
        Mediator(parent: self, scope: resolver)
    }

    // MARK: Dispatch

    /// Sends a request to its handler through all registered behaviors.
    ///
    /// Everything is resolved inside one scope: the handler and all behaviors see the same
    /// `.scoped` instances, and can inject `Mediator` and `any Resolver` without registration.
    ///
    /// Components are constructed just in time, each inside the dynamic extent of the
    /// behaviors outside it. A behavior that sets a task-local around `next` (a transaction
    /// database, a correlation ID) therefore influences how everything inside it is built.
    public func send<R: Request>(_ request: R) async throws -> R.Response {
        guard let entry = requests[ObjectIdentifier(R.self)] else {
            throw MediatorError.noHandler(request: R.self)
        }
        let behaviors = self.behaviors
        return try await resolver.withScope { scope in
            let scoped = MediatorScope(inner: scope, mediator: self)

            var next: Next<R> = { request in
                let handler = try entry.make(scoped) as! AnyRequestHandler<R>
                return try await handler.handle(request)
            }
            for entry in behaviors.reversed() {
                let inner = next
                next = { request in
                    let behavior = try entry.make(scoped)
                    return try await behavior.handle(request, next: inner)
                }
            }
            return try await next(request)
        }
    }

    /// Sends `request` with registrations that only this call sees. Lookups check them
    /// first and fall back to this mediator's resolver. Use it for values the resolver
    /// cannot build synchronously: await them first, then hand them in.
    ///
    ///     let session = try await sessions.current()
    ///     let orders = try await mediator.send(ListOrders()) {
    ///         $0.register(Session.self, instance: session)
    ///     }
    ///
    /// A `.singleton` registered here lives for this call.
    public func send<R: Request>(_ request: R, with register: (SimpleResolver) -> Void) async throws -> R.Response {
        let own = SimpleResolver()
        register(own)
        return try await bound(to: Overlay(own: own, base: resolver)).send(request)
    }

    /// Publishes an event to every handler whose `Note` type matches, in registration order.
    /// Handlers run sequentially inside one scope; the first error stops the sequence and is rethrown.
    public func publish<E: Event>(_ event: E) async throws {
        let matching = events.filter { $0.matches(event) }
        guard !matching.isEmpty else { return }          // no listeners: no scope, no work
        try await resolver.withScope { scope in
            let scoped = MediatorScope(inner: scope, mediator: self)
            for entry in matching {
                let handle = try entry.make(scoped)
                try await handle(event)
            }
        }
    }

    // MARK: Introspection

    /// The handler type registered for a request type, if any.
    public func handlerType<R: Request>(for request: R.Type) -> Any.Type? {
        requests[ObjectIdentifier(R.self)]?.handlerType
    }

    /// Every request type this mediator dispatches, after discovery, registration, stubs and
    /// exclusions, sorted by qualified name. A transport builds its route table from this.
    public var requestTypes: [any Request.Type] {
        requests.values.map(\.requestType).sorted { String(reflecting: $0) < String(reflecting: $1) }
    }

    public var behaviorTypes: [Any.Type] { behaviors.map(\.behaviorType) }
    public var eventHandlerTypes: [Any.Type] { events.map(\.handlerType) }
}

/// The resolver handed to handlers and behaviors. Answers `Mediator` and `any Resolver`
/// itself so components can publish events or resolve lazily without any registration,
/// and delegates everything else to the current scope. The `Mediator` it hands out is
/// bound to this scope, so a nested `send` / `publish` from a handler shares it.
struct MediatorScope: Resolver {
    let inner: any Resolver
    let mediator: Mediator

    func resolve<T>(_ type: T.Type) throws -> T {
        if type == Mediator.self { return mediator.bound(to: inner) as! T }
        if type == (any Resolver).self { return self as! T }
        return try inner.resolve(type)
    }

    func withScope<T: Sendable>(_ body: @Sendable (any Resolver) async throws -> T) async throws -> T {
        try await inner.withScope { try await body(MediatorScope(inner: $0, mediator: mediator)) }
    }
}

/// Per-call registrations over a mediator's resolver. Answers from `own` first and
/// delegates everything else to `base`, so the base resolver's scopes still apply. Inside a
/// scope, `own`'s `.scoped` registrations are shared for the duration of that scope.
struct Overlay: Resolver {
    let own: SimpleResolver
    let base: any Resolver
    var scope: SimpleResolver.Scope? = nil

    func resolve<T>(_ type: T.Type) throws -> T {
        guard own.registration(for: type) != nil else { return try base.resolve(type) }
        return try own.resolve(type, scope: scope, via: self)
    }

    func withScope<T: Sendable>(_ body: @Sendable (any Resolver) async throws -> T) async throws -> T {
        if scope != nil { return try await body(self) }      // nested: reuse, like SimpleResolver.Scope
        return try await base.withScope {
            try await body(Overlay(own: own, base: $0, scope: SimpleResolver.Scope(root: own)))
        }
    }
}

/// Type-erased handler stored in the registry and recovered with a generic cast in `send`.
struct AnyRequestHandler<R: Request>: Sendable {
    let handle: Next<R>
    init(_ handle: @escaping Next<R>) { self.handle = handle }
}
