/// Marks a `RequestHandler` or `EventHandler` for automatic discovery.
///
/// Expands to:
/// 1. A metadata record placed in a dedicated binary section so `Mediator` can find the
///    type at startup without any registration code.
/// 2. An `init(resolver:)` that resolves each stored property lacking a default value,
///    unless the type already declares `init(resolver:)`. Properties with defaults,
///    including `@Injected` wrappers, are untouched.
@attached(peer, names: prefixed(__mediator_record_))
@attached(member, names: named(init(resolver:)))
public macro Handler() = #externalMacro(module: "SwiftMediatorMacros", type: "DiscoverableMacro")

/// Marks a `PipelineBehavior` for automatic discovery. Identical expansion to `@Handler`.
@attached(peer, names: prefixed(__mediator_record_))
@attached(member, names: named(init(resolver:)))
public macro Behavior() = #externalMacro(module: "SwiftMediatorMacros", type: "DiscoverableMacro")

/// Marks a request handler and, in addition to the discovery record, defines a link-time symbol
/// unique to the request it serves.
///
/// Two handlers for the same request in one image then fail to link with a duplicate-symbol
/// error, before the mediator ever starts, and ``RequiresHandler()`` on the request can demand
/// that one exists. Within a single process the run-time check in `Mediator.init` still applies
/// to handlers that arrive in images loaded later.
///
/// Proof of concept for the "uniqueness and existence constraints" future direction of the
/// custom-metadata pitch. The symbol is derived from the request type as spelled, so spell the
/// request the same way at every handler and at its `@RequiresHandler`.
///
///     @Handler(for: CreateOrder.self)
///     struct CreateOrderHandler: RequestHandler { ... }
@attached(peer, names: prefixed(__mediator_record_), prefixed(__mediator_handler_for_))
@attached(member, names: named(init(resolver:)))
public macro Handler(for request: any Request.Type) = #externalMacro(module: "SwiftMediatorMacros", type: "DiscoverableMacro")

/// Demands that a handler for this request is linked into the image.
///
/// Emits an undefined reference to the symbol that ``Handler(for:)`` defines, so an image that
/// provides no handler for the request fails to link instead of failing at run time with
/// ``MediatorError/noHandler(request:)``. The reference also pulls the handler's object file out
/// of a static archive that nothing else references.
///
///     @RequiresHandler
///     struct CreateOrder: Request { typealias Response = OrderID }
@attached(peer, names: prefixed(__mediator_demand_), prefixed(__mediator_requires_))
public macro RequiresHandler() = #externalMacro(module: "SwiftMediatorMacros", type: "RequiresHandlerMacro")
