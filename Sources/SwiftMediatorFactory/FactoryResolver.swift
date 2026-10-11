#if Factory
import FactoryKit
import SwiftMediator

/// A `Resolver` backed by a Factory container.
///
/// Most handlers will not touch it: with Factory you declare dependencies as
/// `@Injected(\.keyPath)` properties, which have default values, so the macro-generated
/// `init(resolver:)` has nothing to resolve. It exists for handlers that keep plain
/// stored properties, which are resolved by type through Factory's opt-in `Resolving`
/// protocol. Enable that with `extension Container: Resolving {}` and
/// `container.register(MyService.self) { ... }`.
public struct FactoryResolver: Resolver {
    private let container: any ManagedContainer

    public init(_ container: any ManagedContainer) {
        self.container = container
    }

    public func resolve<T>(_ type: T.Type) throws -> T {
        guard let resolving = container as? any Resolving,
              let value = resolving.resolve(type)
        else { throw ResolverError.unregistered(type) }
        return value
    }
}

#endif
