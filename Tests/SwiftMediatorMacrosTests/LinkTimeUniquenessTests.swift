import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import XCTest
import SwiftMediatorMacros

/// The link-time half of "exactly one handler per request": `@Handler(for:)` defines a symbol
/// named from the request, `@RequiresHandler` references it.
final class LinkTimeUniquenessTests: XCTestCase {
    let macros: [String: Macro.Type] = [
        "Handler": DiscoverableMacro.self,
        "RequiresHandler": RequiresHandlerMacro.self,
    ]

    func testHandlerForRequestDefinesTheSymbol() {
        assertMacroExpansion(
            """
            @Handler(for: CreateOrder.self)
            struct CreateOrderHandler: RequestHandler {
                func handle(_ request: CreateOrder) async throws -> OrderID { fatalError() }
            }
            """,
            expandedSource: """
            struct CreateOrderHandler: RequestHandler {
                func handle(_ request: CreateOrder) async throws -> OrderID { fatalError() }

                init(resolver: any Resolver) throws {
                }
            }

            #if canImport(Darwin)
            @section("__DATA_CONST,__swift5_discov") @used
            private let __mediator_record_CreateOrderHandler: (version: UInt32, flags: UInt32, type: @convention(c) () -> UnsafeRawPointer, key: @convention(c) () -> UnsafeRawPointer) = (
                version: 1,
                flags: 0,
                type: {
                    unsafeBitCast(CreateOrderHandler.self as Any.Type, to: UnsafeRawPointer.self)
                },
                key: {
                    unsafeBitCast(SwiftMediator.MediatorComponents.self as Any.Type, to: UnsafeRawPointer.self)
                }
            )
            #elseif os(Linux) || os(Android) || os(FreeBSD)
            @section("swift5_discov") @used
            private let __mediator_record_CreateOrderHandler: (version: UInt32, flags: UInt32, type: @convention(c) () -> UnsafeRawPointer, key: @convention(c) () -> UnsafeRawPointer) = (
                version: 1,
                flags: 0,
                type: {
                    unsafeBitCast(CreateOrderHandler.self as Any.Type, to: UnsafeRawPointer.self)
                },
                key: {
                    unsafeBitCast(SwiftMediator.MediatorComponents.self as Any.Type, to: UnsafeRawPointer.self)
                }
            )
            #endif

            @_cdecl("mediator_handler_for_CreateOrder") @used func __mediator_handler_for_CreateOrderHandler() {
            }
            """,
            macros: macros
        )
    }

    func testNestedRequestNameIsQualified() {
        assertMacroExpansion(
            """
            @Handler(for: Orders.CreateOrder.self)
            struct CreateOrderHandler: RequestHandler {
                func handle(_ request: Orders.CreateOrder) async throws -> OrderID { fatalError() }
            }
            """,
            expandedSource: """
            struct CreateOrderHandler: RequestHandler {
                func handle(_ request: Orders.CreateOrder) async throws -> OrderID { fatalError() }

                init(resolver: any Resolver) throws {
                }
            }

            #if canImport(Darwin)
            @section("__DATA_CONST,__swift5_discov") @used
            private let __mediator_record_CreateOrderHandler: (version: UInt32, flags: UInt32, type: @convention(c) () -> UnsafeRawPointer, key: @convention(c) () -> UnsafeRawPointer) = (
                version: 1,
                flags: 0,
                type: {
                    unsafeBitCast(CreateOrderHandler.self as Any.Type, to: UnsafeRawPointer.self)
                },
                key: {
                    unsafeBitCast(SwiftMediator.MediatorComponents.self as Any.Type, to: UnsafeRawPointer.self)
                }
            )
            #elseif os(Linux) || os(Android) || os(FreeBSD)
            @section("swift5_discov") @used
            private let __mediator_record_CreateOrderHandler: (version: UInt32, flags: UInt32, type: @convention(c) () -> UnsafeRawPointer, key: @convention(c) () -> UnsafeRawPointer) = (
                version: 1,
                flags: 0,
                type: {
                    unsafeBitCast(CreateOrderHandler.self as Any.Type, to: UnsafeRawPointer.self)
                },
                key: {
                    unsafeBitCast(SwiftMediator.MediatorComponents.self as Any.Type, to: UnsafeRawPointer.self)
                }
            )
            #endif

            @_cdecl("mediator_handler_for_Orders_CreateOrder") @used func __mediator_handler_for_CreateOrderHandler() {
            }
            """,
            macros: macros
        )
    }

    func testRequiresHandlerReferencesTheSymbol() {
        assertMacroExpansion(
            """
            @RequiresHandler
            struct CreateOrder: Request {
                typealias Response = OrderID
            }
            """,
            expandedSource: """
            struct CreateOrder: Request {
                typealias Response = OrderID
            }

            @_silgen_name("mediator_handler_for_CreateOrder") private func __mediator_demand_CreateOrder()

            @used private let __mediator_requires_CreateOrder: Int = {
                __mediator_demand_CreateOrder()
                return 0
            }()
            """,
            macros: macros
        )
    }

    func testRequiresHandlerOnNestedRequestUsesQualifiedSymbolAndStaticStorage() {
        assertMacroExpansion(
            """
            enum Orders {
                @RequiresHandler
                struct CreateOrder: Request {
                    typealias Response = OrderID
                }
            }
            """,
            expandedSource: """
            enum Orders {
                struct CreateOrder: Request {
                    typealias Response = OrderID
                }

                @_silgen_name("mediator_handler_for_Orders_CreateOrder") private static func __mediator_demand_CreateOrder()

                @used private static let __mediator_requires_CreateOrder: Int = {
                    __mediator_demand_CreateOrder()
                    return 0
                }()
            }
            """,
            macros: macros
        )
    }

    func testHandlerForRequestRejectsNestedHandler() {
        assertMacroExpansion(
            """
            enum Handlers {
                @Handler(for: CreateOrder.self)
                struct CreateOrderHandler: RequestHandler {
                    func handle(_ request: CreateOrder) async throws -> OrderID { fatalError() }
                }
            }
            """,
            expandedSource: """
            enum Handlers {
                struct CreateOrderHandler: RequestHandler {
                    func handle(_ request: CreateOrder) async throws -> OrderID { fatalError() }

                    init(resolver: any Resolver) throws {
                    }
                }
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: "@Handler(for:) requires a handler declared at file scope; the link-time symbol cannot be a member", line: 2, column: 5)
            ],
            macros: macros
        )
    }
}
