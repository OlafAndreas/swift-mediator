#if Factory
@_exported import FactoryKit
@_exported import SwiftMediator

public extension Container {
    /// The application-wide mediator. Discovery runs once, on first resolution.
    ///
    /// Fails fast: a configuration error (two handlers for one request, or an annotated
    /// type that is not a handler) terminates the process with the error message the
    /// first time the mediator is resolved. Factory closures cannot throw, and a mediator
    /// with a broken registry should never reach production.
    ///
    /// Handlers resolve their `@Injected` properties from the task-local
    /// `Container.shared` at the moment they are created inside `send` / `publish`,
    /// so Swift Testing's `.container` trait isolates them per test with no extra work.
    ///
    /// Override like any other Factory:
    ///
    ///     Container.shared.mediator.register {
    ///         Mediator.failFast(resolver: FactoryResolver(Container.shared), discovery: false) {
    ///             $0.register(MyHandler.self)
    ///         }
    ///     }
    var mediator: Factory<Mediator> {
        self { Mediator.failFast(resolver: FactoryResolver(self)) }.singleton
    }
}

public extension Mediator {
    /// Same as `init`, but terminates the process on a configuration error instead of
    /// throwing. For use inside Factory closures and other non-throwing composition roots.
    static func failFast(
        resolver: any Resolver,
        discovery: Bool = true,
        configure: (inout Configuration) -> Void = { _ in }
    ) -> Mediator {
        do {
            return try Mediator(resolver: resolver, discovery: discovery, configure: configure)
        } catch {
            fatalError("SwiftMediator configuration error: \(error)")
        }
    }
}

#endif
