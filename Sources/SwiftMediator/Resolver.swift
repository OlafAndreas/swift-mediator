import Foundation

/// Anything that can produce an instance of a requested type.
///
/// This is the seam between the mediator and your dependency-injection container.
/// Handlers and behaviors receive a resolver in `init(resolver:)`, which the
/// `@Handler` / `@Behavior` macros synthesise from stored properties that have no
/// default value. The `SwiftMediatorFactory` product supplies a Factory-backed resolver.
///
/// Two types are always resolvable inside a `send` or `publish`, whatever the resolver:
/// `Mediator` (the mediator doing the dispatch) and `any Resolver` (the current scope).
public protocol Resolver: Sendable {
    func resolve<T>(_ type: T.Type) throws -> T

    /// Runs `body` inside a new resolution scope. The mediator calls this once per
    /// `send` and once per `publish`, and resolves the handler and every behavior
    /// through the resolver it is given, so scoped registrations are shared by all of
    /// them and released afterwards.
    ///
    /// The default implementation has no scoping and simply passes `self` through.
    func withScope<T: Sendable>(_ body: @Sendable (any Resolver) async throws -> T) async throws -> T
}

public extension Resolver {
    func withScope<T: Sendable>(_ body: @Sendable (any Resolver) async throws -> T) async throws -> T {
        try await body(self)
    }

    /// Resolves with the type inferred from context: `let api: OrderAPI = try resolver()`.
    func callAsFunction<T>() throws -> T { try resolve(T.self) }
}

/// A group of related registrations, so the composition root reads as a list of modules.
///
///     struct NetworkingModule: ResolverModule {
///         func register(into resolver: SimpleResolver) {
///             resolver.register(NetworkClient.self, lifetime: .singleton) { _ in NetworkClient() }
///         }
///     }
///
///     SimpleResolver.shared.install(NetworkingModule(), OrdersModule())
public protocol ResolverModule: Sendable {
    func register(into resolver: SimpleResolver)
}

public enum ResolverError: Error, CustomStringConvertible {
    case unregistered(Any.Type)

    public var description: String {
        switch self {
        case .unregistered(let type): "No registration for \(type)"
        }
    }
}

extension ResolverError: LocalizedError {
    public var errorDescription: String? { description }
}

/// How long an instance produced by `SimpleResolver` lives.
public enum Lifetime: Sendable {
    /// A new instance on every resolve.
    case unique
    /// One instance per `send` / `publish`, shared by the handler and all behaviors.
    /// Outside a scope this behaves like `unique`.
    case scoped
    /// One lazily created instance for the lifetime of the resolver.
    case singleton
}

/// A named registration layer. `SimpleResolver.processRoot.environment(.mock)` is a child
/// resolver that answers from its own registrations first and falls back to the root.
/// Registering there never changes the root.
public struct ResolverEnvironment: Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let name: String
    public init(_ name: String) { self.name = name }
    public init(stringLiteral value: String) { self.name = value }
    public var description: String { name }

    public static let mock = ResolverEnvironment("mock")
    public static let preview = ResolverEnvironment("preview")
}

/// A small thread-safe, type-keyed resolver with `unique`, `scoped` and `singleton`
/// lifetimes, and optional environment layers.
///
/// A resolver may have a parent. Lookups check the resolver's own registrations first and
/// fall back to the parent chain; registrations never flow upward. A singleton belongs to
/// the resolver it is registered on, so every child, environment layer and per-request
/// scope sees the same instance. For fresh instances use `copy()`, which flattens the
/// chain into a standalone resolver with no cached singletons.
///
/// `SimpleResolver.shared` is the app's default composition root: register long-lived
/// infrastructure (network clients, API providers) there as `.singleton`, services and
/// per-request state as `.scoped`, and `Mediator()` picks it up with no arguments. It is
/// task-local, so a test can swap in its own root without affecting other tests; the
/// `SwiftMediatorTesting` product's `.resolver` trait does exactly that.
public final class SimpleResolver: Resolver, @unchecked Sendable {
    /// The default composition root. Task-local: `SimpleResolver.$shared.withValue(...)`
    /// replaces it for the duration of a task, which is how the `.resolver` test trait
    /// gives every test its own root and lets tests run in parallel.
    @TaskLocal public static var shared = processRoot

    /// The root used when no task-local override is in effect: the app's real wiring.
    public static let processRoot = SimpleResolver(parent: nil, processOwned: true)

    /// Debug-only hook called before any registration on `processRoot`. The testing
    /// product installs one that flags mutations made inside a test without the
    /// `.resolver` trait, since those race with other tests running in parallel.
    public static var processRootMutationGuard: (@Sendable () -> Void)? {
        get { guardLock.withLock { _guard } }
        set { guardLock.withLock { _guard = newValue } }
    }
    nonisolated(unsafe) private static var _guard: (@Sendable () -> Void)?
    private static let guardLock = NSLock()

    struct Registration {
        let lifetime: Lifetime
        let make: @Sendable (any Resolver) throws -> Any
    }

    private var registrations: [ObjectIdentifier: Registration] = [:]
    private var singletons: [ObjectIdentifier: Any] = [:]
    private var environments: [ResolverEnvironment: SimpleResolver] = [:]
    private let lock = NSRecursiveLock()

    /// The resolver consulted when this one has no registration for a type.
    public let parent: SimpleResolver?

    /// True for `processRoot` and every environment layer created from it. Mutating these
    /// from inside a test affects every other test; the testing product's guard watches them.
    let isProcessOwned: Bool

    public init() {
        parent = nil
        isProcessOwned = false
    }

    /// A child resolver that falls back to `parent`. Use for environments, feature scopes
    /// or test isolation. `parent` is never modified through the child.
    public init(parent: SimpleResolver) {
        self.parent = parent
        isProcessOwned = false
    }

    private init(parent: SimpleResolver?, processOwned: Bool) {
        self.parent = parent
        isProcessOwned = processOwned
    }

    /// The child layer named `environment`, created on first use and reused afterwards.
    ///
    ///     SimpleResolver.processRoot.environment(.mock)
    ///         .register((any PaymentGateway).self, instance: FakeGateway())
    ///
    /// Lookups through the layer see its registrations first, then this resolver's.
    public func environment(_ environment: ResolverEnvironment) -> SimpleResolver {
        lock.withLock {
            if let existing = environments[environment] { return existing }
            let layer = SimpleResolver(parent: self, processOwned: isProcessOwned)
            environments[environment] = layer
            return layer
        }
    }

    /// Registers on the named environment layer instead of on this resolver.
    public func register<T>(
        _ type: T.Type,
        in environment: ResolverEnvironment,
        lifetime: Lifetime = .unique,
        _ factory: @escaping @Sendable (any Resolver) throws -> T
    ) {
        self.environment(environment).register(type, lifetime: lifetime, factory)
    }

    public func register<T: Sendable>(_ type: T.Type, in environment: ResolverEnvironment, instance: T) {
        self.environment(environment).register(type, instance: instance)
    }

    /// Runs `body` with `SimpleResolver.shared` switched to the named environment layer of
    /// the current shared resolver. Lookups inside want the mock; everything else is unchanged.
    ///
    ///     try await SimpleResolver.using(.mock) {
    ///         let mediator = try Mediator()          // resolves through the mock layer
    ///     }
    public static func using<T: Sendable>(
        _ environment: ResolverEnvironment,
        _ body: @Sendable () async throws -> T
    ) async throws -> T {
        try await $shared.withValue(shared.environment(environment)) { try await body() }
    }

    /// A standalone resolver with this chain's registrations flattened (child overrides
    /// parent), no parent, and no instances yet. Singletons are created afresh in the copy.
    /// Tests use this to start from the app's real wiring, or from one of its environment
    /// layers, while staying fully isolated from other tests.
    public func copy() -> SimpleResolver {
        var chain: [SimpleResolver] = []
        var current: SimpleResolver? = self
        while let resolver = current { chain.append(resolver); current = resolver.parent }
        let other = SimpleResolver()
        for resolver in chain.reversed() {                       // root first, leaf last wins
            let own = resolver.lock.withLock { resolver.registrations }
            other.registrations.merge(own) { _, leaf in leaf }
        }
        return other
    }

    /// Applies each module's registrations in order.
    public func install(_ modules: any ResolverModule...) {
        for module in modules { module.register(into: self) }
    }

    /// Registers a factory. The factory receives the resolver of the current scope, so
    /// its own dependencies are resolved with the same lifetimes.
    public func register<T>(
        _ type: T.Type,
        lifetime: Lifetime = .unique,
        _ factory: @escaping @Sendable (any Resolver) throws -> T
    ) {
        #if DEBUG
        if isProcessOwned { Self.processRootMutationGuard?() }
        #endif
        lock.withLock {
            registrations[ObjectIdentifier(type)] = Registration(lifetime: lifetime, make: factory)
            singletons[ObjectIdentifier(type)] = nil
        }
    }

    /// Registers an already built instance. Equivalent to an eager singleton.
    public func register<T: Sendable>(_ type: T.Type, instance: T) {
        register(type, lifetime: .singleton) { _ in instance }
    }

    public func resolve<T>(_ type: T.Type) throws -> T {
        try resolve(type, scope: nil, via: self)
    }

    public func withScope<T: Sendable>(_ body: @Sendable (any Resolver) async throws -> T) async throws -> T {
        try await body(Scope(root: self))
    }

    // MARK: Internals

    /// Own registration first, then the parent chain. Returns the resolver that owns it.
    func registration(for type: Any.Type) -> (Registration, owner: SimpleResolver)? {
        if let own = lock.withLock({ registrations[ObjectIdentifier(type)] }) { return (own, self) }
        return parent?.registration(for: type)
    }

    /// Resolves `type`, caching scoped instances in `scope` (when present) and singletons
    /// on the resolver that owns the registration. `via` is the resolver handed to factories.
    func resolve<T>(_ type: T.Type, scope: Scope?, via: any Resolver) throws -> T {
        guard let (registration, owner) = registration(for: type) else {
            throw ResolverError.unregistered(type)
        }
        switch registration.lifetime {
        case .unique:
            return try registration.make(via) as! T
        case .scoped:
            guard let scope else { return try registration.make(via) as! T }
            return try scope.cached(type) { try registration.make(via) as! T }
        case .singleton:
            return try owner.lock.withLock {
                if let existing = owner.singletons[ObjectIdentifier(type)] { return existing as! T }
                // Built by its owner, so it never captures child-only or scoped state.
                let created = try registration.make(owner) as! T
                owner.singletons[ObjectIdentifier(type)] = created
                return created
            }
        }
    }

    /// One `send` / `publish` worth of scoped instances.
    final class Scope: Resolver, @unchecked Sendable {
        private let root: SimpleResolver
        private var cache: [ObjectIdentifier: Any] = [:]
        private let lock = NSRecursiveLock()

        init(root: SimpleResolver) { self.root = root }

        func resolve<T>(_ type: T.Type) throws -> T {
            try root.resolve(type, scope: self, via: self)
        }

        func cached<T>(_ type: T.Type, _ make: () throws -> T) throws -> T {
            try lock.withLock {
                if let existing = cache[ObjectIdentifier(type)] { return existing as! T }
                let created = try make()
                cache[ObjectIdentifier(type)] = created
                return created
            }
        }

        /// Nested scopes are not supported; the current scope is reused.
        func withScope<T: Sendable>(_ body: @Sendable (any Resolver) async throws -> T) async throws -> T {
            try await body(self)
        }
    }
}
