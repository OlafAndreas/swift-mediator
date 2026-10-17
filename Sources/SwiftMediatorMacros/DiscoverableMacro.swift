import SwiftDiagnostics
import SwiftDiscoveryMacroSupport
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// Implements `@Handler` and `@Behavior`.
///
/// - Peer: emits a SwiftDiscovery record under `MediatorComponents`.
/// - Member: synthesises `init(resolver:)` from stored properties lacking defaults.
public struct DiscoverableMacro: PeerMacro, MemberMacro {

    // MARK: Peer — discovery record

    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        let placement = try DiscoveryRecordSyntax.placement(of: node, on: declaration, in: context)
        var declarations = DiscoveryRecordSyntax.declarations(
            recording: placement,
            under: ["SwiftMediator.MediatorComponents"],
            identifierPrefix: "__mediator_record_"
        )
        if let request = LinkTimeSymbol.requestArgument(of: node) {
            guard !placement.storage.contains("static") else {
                throw DiagnosticsError(diagnostics: [
                    Diagnostic(node: Syntax(node), message: Message.nestedHandlerWithRequest)
                ])
            }
            // One strong symbol per request. A second handler for the same request in this module
            // is a compile-time "multiple definitions of symbol" error; one in another module of the
            // same image is a duplicate-symbol error at link time. The function must not be private:
            // the compiler emits no C entry point for private `@_cdecl` functions.
            let symbol = LinkTimeSymbol.symbol(forRequestSpelled: request)
            declarations.append(
                """
                @_cdecl(\(literal: symbol)) @used func __mediator_handler_for_\(raw: placement.typeName)() {
                }
                """
            )
        }
        return declarations
    }

    enum Message: DiagnosticMessage {
        case nestedHandlerWithRequest
        var message: String {
            "@Handler(for:) requires a handler declared at file scope; the link-time symbol cannot be a member"
        }
        var diagnosticID: MessageID { MessageID(domain: "SwiftMediatorMacros", id: "\(self)") }
        var severity: DiagnosticSeverity { .error }
    }

    // MARK: Member — init(resolver:)

    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        if hasResolverInit(declaration) { return [] }

        var assignments: [String] = []
        for member in declaration.memberBlock.members {
            guard let variable = member.decl.as(VariableDeclSyntax.self),
                  !variable.modifiers.contains(where: { $0.name.tokenKind == .keyword(.static) }),
                  variable.attributes.isEmpty   // property wrappers (@Injected …) supply their own value
            else { continue }

            for binding in variable.bindings {
                guard binding.initializer == nil,
                      isStored(binding),
                      let identifier = binding.pattern.as(IdentifierPatternSyntax.self),
                      let type = binding.typeAnnotation?.type
                else { continue }
                let property = identifier.identifier.trimmed.text
                assignments.append("self.\(property) = try resolver.resolve((\(type.trimmed)).self)")
            }
        }

        var modifiers: [String] = []
        if let access = accessModifier(of: declaration) { modifiers.append(access) }
        if let classDecl = declaration.as(ClassDeclSyntax.self),
           !classDecl.modifiers.contains(where: { $0.name.tokenKind == .keyword(.final) }) {
            modifiers.append("required")
        }
        let prefix = modifiers.isEmpty ? "" : modifiers.joined(separator: " ") + " "
        let body = assignments.isEmpty ? "" : "\n    " + assignments.joined(separator: "\n    ") + "\n"

        return ["\(raw: prefix)init(resolver: any Resolver) throws {\(raw: body)}"]
    }

    // MARK: Helpers

    private static func hasResolverInit(_ declaration: some DeclGroupSyntax) -> Bool {
        declaration.memberBlock.members.contains { member in
            guard let initializer = member.decl.as(InitializerDeclSyntax.self) else { return false }
            let parameters = initializer.signature.parameterClause.parameters
            return parameters.count == 1 && parameters.first?.firstName.text == "resolver"
        }
    }

    /// Stored if it has no accessor block, or only observers (`willSet` / `didSet`).
    private static func isStored(_ binding: PatternBindingSyntax) -> Bool {
        guard let accessors = binding.accessorBlock else { return true }
        switch accessors.accessors {
        case .getter: return false
        case .accessors(let list):
            return list.allSatisfy { accessor in
                switch accessor.accessorSpecifier.tokenKind {
                case .keyword(.willSet), .keyword(.didSet): true
                default: false
                }
            }
        }
    }

    private static func accessModifier(of declaration: some DeclGroupSyntax) -> String? {
        for modifier in declaration.modifiers {
            switch modifier.name.tokenKind {
            case .keyword(.public), .keyword(.open): return "public"
            case .keyword(.package): return "package"
            case .keyword(.internal): return nil
            case .keyword(.fileprivate), .keyword(.private): return "fileprivate"
            default: continue
            }
        }
        return nil
    }
}
