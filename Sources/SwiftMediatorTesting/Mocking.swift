import SwiftMediator

public extension SimpleResolver {
    /// Registers `instance` for `type`, replacing whatever was registered. Reads naturally
    /// with protocols: `SimpleResolver.shared.mock(PaymentGateway.self, with: FakeGateway())`.
    func mock<T: Sendable>(_ type: T.Type, with instance: T) {
        register(type, instance: instance)
    }

    /// Registers a factory for `type` with the given lifetime, replacing whatever was registered.
    func mock<T>(_ type: T.Type, lifetime: Lifetime = .unique, _ factory: @escaping @Sendable (any Resolver) throws -> T) {
        register(type, lifetime: lifetime, factory)
    }

    /// Registers `instance` on the named environment layer, leaving this resolver unchanged.
    func mock<T: Sendable>(_ type: T.Type, in environment: ResolverEnvironment, with instance: T) {
        register(type, in: environment, instance: instance)
    }
}
