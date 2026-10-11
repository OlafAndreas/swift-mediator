import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import XCTest
import SwiftMediatorMacros

final class DiscoverableMacroTests: XCTestCase {
    let macros: [String: Macro.Type] = [
        "Handler": DiscoverableMacro.self,
        "Behavior": DiscoverableMacro.self,
    ]

    func testSynthesisesInitFromStoredPropertiesWithoutDefaults() {
        assertMacroExpansion(
            """
            @Handler
            public struct CreateUserHandler: RequestHandler {
                let repo: any UserRepository
                var cache: Cache
                @Injected(\\.mailer) private var mailer
                @Injected(\\.clock) private var clock: Clock
                var computed: Int { 1 }
                static let shared = 1
                let configured = "x"
                func handle(_ request: CreateUser) async throws -> User { fatalError() }
            }
            """,
            expandedSource: """
            public struct CreateUserHandler: RequestHandler {
                let repo: any UserRepository
                var cache: Cache
                @Injected(\\.mailer) private var mailer
                @Injected(\\.clock) private var clock: Clock
                var computed: Int { 1 }
                static let shared = 1
                let configured = "x"
                func handle(_ request: CreateUser) async throws -> User { fatalError() }

                public init(resolver: any Resolver) throws {
                    self.repo = try resolver.resolve((any UserRepository).self)
                    self.cache = try resolver.resolve((Cache).self)
                }
            }

            #if canImport(Darwin)
            @section("__DATA_CONST,__swift5_mediatr") @used
            private let __mediator_record_CreateUserHandler: DiscoveryRecord = (
                kind: 1,
                reserved: 0,
                accessor: {
                    Mediator.__erase(CreateUserHandler.self)
                }
            )
            #elseif os(Linux) || os(Android) || os(FreeBSD)
            @section("swift5_mediatr") @used
            private let __mediator_record_CreateUserHandler: DiscoveryRecord = (
                kind: 1,
                reserved: 0,
                accessor: {
                    Mediator.__erase(CreateUserHandler.self)
                }
            )
            #endif
            """,
            macros: macros
        )
    }

    func testInjectedOnlyStructGetsEmptyInit() {
        assertMacroExpansion(
            """
            @Behavior
            struct Logging: PipelineBehavior {
                @Injected(\\.logger) private var logger
            }
            """,
            expandedSource: """
            struct Logging: PipelineBehavior {
                @Injected(\\.logger) private var logger

                init(resolver: any Resolver) throws {
                }
            }

            #if canImport(Darwin)
            @section("__DATA_CONST,__swift5_mediatr") @used
            private let __mediator_record_Logging: DiscoveryRecord = (
                kind: 1,
                reserved: 0,
                accessor: {
                    Mediator.__erase(Logging.self)
                }
            )
            #elseif os(Linux) || os(Android) || os(FreeBSD)
            @section("swift5_mediatr") @used
            private let __mediator_record_Logging: DiscoveryRecord = (
                kind: 1,
                reserved: 0,
                accessor: {
                    Mediator.__erase(Logging.self)
                }
            )
            #endif
            """,
            macros: macros
        )
    }

    func testKeepsExistingInit() {
        assertMacroExpansion(
            """
            @Handler
            struct H: RequestHandler {
                let level: Int
                init(resolver: any Resolver) throws { level = 1 }
            }
            """,
            expandedSource: """
            struct H: RequestHandler {
                let level: Int
                init(resolver: any Resolver) throws { level = 1 }
            }

            #if canImport(Darwin)
            @section("__DATA_CONST,__swift5_mediatr") @used
            private let __mediator_record_H: DiscoveryRecord = (
                kind: 1,
                reserved: 0,
                accessor: {
                    Mediator.__erase(H.self)
                }
            )
            #elseif os(Linux) || os(Android) || os(FreeBSD)
            @section("swift5_mediatr") @used
            private let __mediator_record_H: DiscoveryRecord = (
                kind: 1,
                reserved: 0,
                accessor: {
                    Mediator.__erase(H.self)
                }
            )
            #endif
            """,
            macros: macros
        )
    }

    func testNonFinalClassGetsRequiredInit() {
        assertMacroExpansion(
            """
            @Handler
            class H: RequestHandler {
            }
            """,
            expandedSource: """
            class H: RequestHandler {

                required init(resolver: any Resolver) throws {
                }
            }

            #if canImport(Darwin)
            @section("__DATA_CONST,__swift5_mediatr") @used
            private let __mediator_record_H: DiscoveryRecord = (
                kind: 1,
                reserved: 0,
                accessor: {
                    Mediator.__erase(H.self)
                }
            )
            #elseif os(Linux) || os(Android) || os(FreeBSD)
            @section("swift5_mediatr") @used
            private let __mediator_record_H: DiscoveryRecord = (
                kind: 1,
                reserved: 0,
                accessor: {
                    Mediator.__erase(H.self)
                }
            )
            #endif
            """,
            macros: macros
        )
    }

    func testNestedTypeGetsStaticRecord() {
        assertMacroExpansion(
            """
            enum Orders {
                @Handler
                struct CountHandler: RequestHandler {
                }
            }
            """,
            expandedSource: """
            enum Orders {
                struct CountHandler: RequestHandler {

                    init(resolver: any Resolver) throws {
                    }
                }

                #if canImport(Darwin)
                @section("__DATA_CONST,__swift5_mediatr") @used
                private static let __mediator_record_CountHandler: DiscoveryRecord = (
                    kind: 1,
                    reserved: 0,
                    accessor: {
                        Mediator.__erase(CountHandler.self)
                    }
                )
                #elseif os(Linux) || os(Android) || os(FreeBSD)
                @section("swift5_mediatr") @used
                private static let __mediator_record_CountHandler: DiscoveryRecord = (
                    kind: 1,
                    reserved: 0,
                    accessor: {
                        Mediator.__erase(CountHandler.self)
                    }
                )
                #endif
            }
            """,
            macros: macros
        )
    }

    func testRejectsTypesNestedInGenericTypes() {
        assertMacroExpansion(
            """
            struct Box<T> {
                @Handler
                struct H: RequestHandler {
                }
            }
            """,
            expandedSource: """
            struct Box<T> {
                struct H: RequestHandler {

                    init(resolver: any Resolver) throws {
                    }
                }
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: "@Handler cannot be applied to a type nested in a generic type, because the discovery record is a static stored property", line: 2, column: 5)
            ],
            macros: macros
        )
    }

    func testRejectsLocalTypes() {
        assertMacroExpansion(
            """
            func make() {
                @Handler
                struct H: RequestHandler {
                }
            }
            """,
            expandedSource: """
            func make() {
                struct H: RequestHandler {

                    init(resolver: any Resolver) throws {
                    }
                }
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: "@Handler cannot be applied to a type declared inside a function; move it to type or file scope", line: 2, column: 5)
            ],
            macros: macros
        )
    }

    func testRejectsNonNominalDeclarations() {
        assertMacroExpansion(
            """
            @Handler
            func notAType() {}
            """,
            expandedSource: """
            func notAType() {}
            """,
            diagnostics: [
                DiagnosticSpec(message: "@Handler can only be applied to a struct, class, actor or enum", line: 1, column: 1)
            ],
            macros: macros
        )
    }
}
