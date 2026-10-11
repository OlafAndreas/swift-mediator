import Testing
import SwiftMediator
@testable import SwiftMediatorTesting

struct Say: Request { typealias Response = String }
struct Word: Sendable { let value: String }

struct SayHandler: RequestHandler {
    let word: Word
    init(resolver: any Resolver) throws { word = try resolver() }
    func handle(_ request: Say) async throws -> String { word.value }
}

/// Fifty parameterised cases, each registering a different value on "the" shared root.
/// Swift Testing runs them concurrently; the trait keeps them from seeing each other.
@Suite(.resolver) struct ParallelIsolationTests {

    @Test(arguments: 1...50)
    func eachCaseSeesOnlyItsOwnRoot(n: Int) async throws {
        SimpleResolver.shared.register(Word.self, instance: Word(value: "word-\(n)"))
        let mediator = try Mediator(discovery: false) { $0.register(SayHandler.self) }

        await Task.yield()                              // invite interleaving
        #expect(try await mediator.send(Say()) == "word-\(n)")
        #expect(try SimpleResolver.shared.resolve(Word.self).value == "word-\(n)")
    }

    @Test func hundredConcurrentRootsInsideOneTest() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for n in 0..<100 {
                group.addTask {
                    let root = SimpleResolver()
                    root.register(Word.self, instance: Word(value: "\(n)"))
                    try await SimpleResolver.$shared.withValue(root) {
                        let mediator = try Mediator(discovery: false) { $0.register(SayHandler.self) }
                        for _ in 0..<5 {
                            await Task.yield()
                            #expect(try await mediator.send(Say()) == "\(n)")
                        }
                    }
                }
            }
            try await group.waitForAll()
        }
    }

    @Test func discoveryIsScannedOnceAndSharedAcrossMediators() throws {
        let a = DiscoverySection.discoveredTypes()
        let b = DiscoverySection.discoveredTypes()
        #expect(a.count == b.count)
        #expect(a.count == DiscoverySection.rescan().count)
    }
}

/// Outer suite installs the app wiring plus a mock layer on a per-test root; inner tests
/// pick which layer they resolve through.
@Suite(.resolver { root in
    root.register(Word.self, lifetime: .singleton) { _ in Word(value: "real") }
    root.register(Word.self, in: .mock, instance: Word(value: "mock"))
})
struct EnvironmentTraitTests {

    @Test func defaultLayerByDefault() throws {
        #expect(try SimpleResolver.shared.resolve(Word.self).value == "real")
    }

    @Test(.resolver(environment: .mock))
    func mockLayerWhenAsked() async throws {
        #expect(try SimpleResolver.shared.resolve(Word.self).value == "mock")
        let mediator = try Mediator(discovery: false) { $0.register(SayHandler.self) }
        #expect(try await mediator.send(Say()) == "mock")
    }

    @Test(.resolver(environment: .mock))
    func registeringInsideTheTestStaysLocal() throws {
        #expect(SimpleResolver.shared.parent == nil, "the test root is a standalone copy")
        SimpleResolver.shared.register(Word.self, instance: Word(value: "local"))
        #expect(try SimpleResolver.shared.resolve(Word.self).value == "local")
    }
}

@Suite struct TraitSemanticsTests {

    @Test func inheritingSeesRegistrationsButOwnsItsSingletons() throws {
        final class Counter: @unchecked Sendable { var n = 0 }
        let counter = Counter()
        let appRoot = SimpleResolver()
        appRoot.register(Word.self, lifetime: .singleton) { _ in counter.n += 1; return Word(value: "app-\(counter.n)") }
        _ = try appRoot.resolve(Word.self)                                       // app-1 cached on appRoot

        try SimpleResolver.$shared.withValue(appRoot) { () throws in
            let inherited = ResolverTrait(inheriting: true).makeRoot()
            let fresh = ResolverTrait(inheriting: false).makeRoot()

            #expect(try inherited.resolve(Word.self).value == "app-2")          // registration kept, instance fresh
            #expect(try inherited.resolve(Word.self).value == "app-2")          // and then cached in the copy
            #expect(try appRoot.resolve(Word.self).value == "app-1")            // original untouched
            #expect(throws: ResolverError.self) { try fresh.resolve(Word.self) }
        }
    }

    @Test func mutatingTheProcessRootInsideATestIsFlagged() {
        ResolverTrait.installProcessRootGuard()
        withKnownIssue("the guard records an issue for process-root mutation inside a test") {
            SimpleResolver.processRoot.register(Word.self, instance: Word(value: "leaked"))
        }
    }

    @Test(.resolver) func mutatingAnIsolatedRootIsNotFlagged() {
        SimpleResolver.shared.register(Word.self, instance: Word(value: "fine"))
        #expect(SimpleResolver.shared !== SimpleResolver.processRoot)
    }
}
