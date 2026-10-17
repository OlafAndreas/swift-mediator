import SwiftSyntax
import SwiftSyntaxMacros

/// The link-time symbol that ties a request to its handler.
///
/// `@Handler(for:)` defines it with `@_cdecl`; `@RequiresHandler` references it with
/// `@_silgen_name`. Both derive it from the request type's name as spelled, with everything that
/// is not an identifier character replaced by an underscore, so `Orders.CreateOrder` becomes
/// `mediator_handler_for_Orders_CreateOrder`.
enum LinkTimeSymbol {
    static let prefix = "mediator_handler_for_"

    static func symbol(forRequestSpelled spelled: String) -> String {
        prefix + sanitized(spelled)
    }

    static func sanitized(_ spelled: String) -> String {
        String(spelled.map { $0.isLetter || $0.isNumber || $0 == "_" ? $0 : "_" })
    }

    /// The attached declaration's name, qualified by its enclosing nominal types.
    static func qualifiedName(of name: String, in context: some MacroExpansionContext) -> String {
        var parts: [String] = []
        for enclosing in context.lexicalContext.reversed() {   // lexicalContext is innermost first
            if let named = enclosing.asProtocol(NamedDeclSyntax.self) {
                parts.append(named.name.text)
            } else if let extended = enclosing.as(ExtensionDeclSyntax.self) {
                parts.append(extended.extendedType.trimmedDescription)
            }
        }
        parts.append(name)
        return parts.joined(separator: ".")
    }

    /// The `for:` argument of `@Handler(for: SomeRequest.self)`, as spelled, or nil for `@Handler`.
    static func requestArgument(of node: AttributeSyntax) -> String? {
        guard let arguments = node.arguments?.as(LabeledExprListSyntax.self),
              let argument = arguments.first(where: { $0.label?.text == "for" }),
              let member = argument.expression.as(MemberAccessExprSyntax.self),
              member.declName.baseName.tokenKind == .keyword(.self),
              let base = member.base
        else { return nil }
        return base.trimmedDescription
    }
}
