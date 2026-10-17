import SwiftDiagnostics
import SwiftDiscoveryMacroSupport
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// `@RequiresHandler` on a request type: emits an undefined reference to the link-time symbol
/// that `@Handler(for: ThisRequest.self)` defines, so the image fails to link without one.
public struct RequiresHandlerMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        // Reuses the discovery checks: nominal type, not local, no generic enclosing type.
        let placement = try DiscoveryRecordSyntax.placement(of: node, on: declaration, in: context)
        let name = placement.typeName
        let symbol = LinkTimeSymbol.symbol(forRequestSpelled: LinkTimeSymbol.qualifiedName(of: name, in: context))
        let isNested = placement.storage.contains("static")
        let functionModifiers = isNested ? "private static" : "private"
        return [
            """
            @_silgen_name(\(literal: symbol)) \(raw: functionModifiers) func __mediator_demand_\(raw: name)()
            """,
            """
            @used \(raw: placement.storage) let __mediator_requires_\(raw: name): Int = {
                __mediator_demand_\(raw: name)()
                return 0
            }()
            """,
        ]
    }
}
