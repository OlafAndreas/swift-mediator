/// A message that expects exactly one handler and produces a `Response`.
///
/// Mirrors MediatR's `IRequest<TResponse>`.
public protocol Request<Response>: Sendable {
    associatedtype Response: Sendable
}

/// A message that is broadcast to zero or more handlers and produces nothing.
///
/// Mirrors MediatR's `INotification`. Named `Event` to avoid clashing with
/// `Foundation.Notification`.
public protocol Event: Sendable {}

/// Marks a request whose handler must run inside a unit of work. The core attaches no
/// behaviour to this; integrations do. `SwiftMediatorFluent` wraps `Transactional`
/// requests in a database transaction and rolls back when the handler throws.
public protocol Transactional {}
