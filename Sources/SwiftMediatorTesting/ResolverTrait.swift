import SwiftMediator
import Testing

/// Gives each test its own `SimpleResolver.shared`, so tests that rely on the default
/// composition root can register fakes freely and still run in parallel.
///
///     @Suite(.resolver) struct OrderTests {
///         @Test func placesOrder() async throws {
///             SimpleResolver.shared.register(PaymentGateway.self, instance: FakeGateway())
///             let mediator = try Mediator()
///             ...
///         }
///     }
///
/// `.resolver` starts from an empty root. `.resolver(inheriting: true)` starts from a
/// flattened copy of the enclosing root: same registrations, fresh singletons, and
/// anything registered on it stays local. `.resolver(environment: .mock)` copies the
/// enclosing root's mock layer instead, so mock registrations win and everything else is
/// the real wiring. Copies are standalone, so no instance is shared between tests.
public struct ResolverTrait: TestTrait, SuiteTrait, TestScoping {
    public typealias Setup = @Sendable (SimpleResolver) -> Void

    private enum Base: Sendable { case empty, inherit, environment(ResolverEnvironment) }

    private let base: Base
    private var setup: Setup?

    public let isRecursive = true

    private init(base: Base, setup: Setup? = nil) {
        self.base = base
        self.setup = setup
    }

    init(inheriting: Bool, setup: Setup? = nil) {
        self.init(base: inheriting ? .inherit : .empty, setup: setup)
    }

    init(environment: ResolverEnvironment, setup: Setup? = nil) {
        self.init(base: .environment(environment), setup: setup)
    }

    public func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: @Sendable () async throws -> Void
    ) async throws {
        Self.installProcessRootGuard()
        try await SimpleResolver.$shared.withValue(makeRoot()) {
            try await function()
        }
    }

    /// The root a test will run with: empty, a flattened copy of the enclosing root, or a
    /// flattened copy of one of its environment layers. Copies have no parent and no
    /// cached singletons, so tests never share an instance.
    func makeRoot() -> SimpleResolver {
        let root: SimpleResolver
        switch base {
        case .empty: root = SimpleResolver()
        case .inherit: root = SimpleResolver.shared.copy()
        case .environment(let env): root = SimpleResolver.shared.environment(env).copy()
        }
        setup?(root)
        return root
    }

    /// Flags registrations on `SimpleResolver.processRoot` made from inside a test. Those
    /// are shared with every other test in the process and race under parallel execution;
    /// the fix is to run the test under `.resolver`. Installed once, on first use of the
    /// trait, so a test target that never uses the trait is left alone.
    public static func installProcessRootGuard() {
        _ = guardInstalled
    }

    private static let guardInstalled: Bool = {
        SimpleResolver.processRootMutationGuard = {
            guard let test = Test.current else { return }
            Issue.record("""
                SimpleResolver.shared was modified inside test '\(test.name)' without the \
                .resolver trait. This mutates the process-wide root and races with tests \
                running in parallel. Add @Suite(.resolver) or @Test(.resolver).
                """)
        }
        return true
    }()

    /// Registers fakes on the fresh root before each test runs.
    public func callAsFunction(_ setup: @escaping Setup) -> ResolverTrait {
        var copy = self
        copy.setup = setup
        return copy
    }
}

public extension Trait where Self == ResolverTrait {
    /// A fresh, empty `SimpleResolver.shared` for each test.
    static var resolver: ResolverTrait { ResolverTrait(inheriting: false) }

    /// A fresh `SimpleResolver.shared` for each test with the enclosing root's registrations
    /// and fresh singletons.
    static func resolver(inheriting: Bool) -> ResolverTrait { ResolverTrait(inheriting: inheriting) }

    /// A fresh `SimpleResolver.shared` for each test with the enclosing root's named
    /// environment layer flattened over its registrations, and fresh singletons.
    static func resolver(environment: ResolverEnvironment) -> ResolverTrait { ResolverTrait(environment: environment) }
}
