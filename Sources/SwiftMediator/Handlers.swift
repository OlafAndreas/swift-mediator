/// A handler or behavior the mediator can instantiate on demand.
///
/// The `@Handler` / `@Behavior` macros synthesise `init(resolver:)`: every stored
/// property without a default value is resolved by type from the `Resolver`. Properties
/// that already have a value (including property wrappers such as Factory's
/// `@Injected`) are left alone.
public protocol MediatorComponent: Sendable {
    init(resolver: any Resolver) throws
}

/// Handles exactly one `Request` type. Mirrors MediatR's `IRequestHandler<TRequest, TResponse>`.
public protocol RequestHandler<Req>: MediatorComponent {
    associatedtype Req: Request
    func handle(_ request: Req) async throws -> Req.Response
}

/// Handles an `Event`. Mirrors MediatR's `INotificationHandler<TNotification>`.
///
/// `Note` is deliberately unconstrained so a handler can subscribe to a protocol
/// existential (`typealias Note = any UserEvent`) and receive every conforming event.
public protocol EventHandler<Note>: MediatorComponent {
    associatedtype Note
    func handle(_ event: Note) async throws
}

/// The continuation passed to a `PipelineBehavior`.
public typealias Next<R: Request> = @Sendable (R) async throws -> R.Response

/// Wraps every `send` call. Mirrors MediatR's `IPipelineBehavior<TRequest, TResponse>`.
///
/// Because `handle` is a generic method, one behavior type covers all requests with no
/// open-generic machinery. Constrain at runtime with `request as? any SomeProtocol`.
public protocol PipelineBehavior: MediatorComponent {
    /// Lower values run first (outermost). Defaults to 0.
    static var order: Int { get }
    func handle<R: Request>(_ request: R, next: Next<R>) async throws -> R.Response
}

public extension PipelineBehavior {
    static var order: Int { 0 }
}
