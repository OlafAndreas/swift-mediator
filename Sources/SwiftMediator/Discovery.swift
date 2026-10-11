@_exported import SwiftDiscovery

/// The discovery key under which ``Handler()`` and ``Behavior()`` record their types.
///
/// Referenced from macro expansions, which is why it is public. You never name it yourself
/// unless you enumerate mediator components directly with `Discoverable.types(for:)`.
public enum MediatorComponents: DiscoveryKey {}

/// Which discovered types a mediator registers. See `DiscoveryScope` in SwiftDiscovery.
///
///     try Mediator(discovery: .thisModule())              // this test target only
///     try Mediator(discovery: .modules(["Orders", "Billing"]))
public typealias Discovery = DiscoveryScope

extension Mediator {
    /// Every `@Handler` / `@Behavior` type the policy admits, before any registration.
    public static func discoveredTypes(_ policy: Discovery = .all) -> [Any.Type] {
        Discoverable.types(for: MediatorComponents.self, in: policy)
    }
}
