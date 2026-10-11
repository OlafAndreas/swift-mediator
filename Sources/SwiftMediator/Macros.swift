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
