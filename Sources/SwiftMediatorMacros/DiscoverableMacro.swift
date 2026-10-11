import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// Implements `@Handler` and `@Behavior`.
///
/// - Peer: emits a `DiscoveryRecord` into the mediator's binary section.
/// - Member: synthesises `init(resolver:)` from stored properties lacking defaults.
public struct DiscoverableMacro: PeerMacro, MemberMacro {

    // MARK: Peer — discovery record

    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let name = nominalName(of: declaration) else {
            throw DiagnosticsError(diagnostics: [
                Diagnostic(node: Syntax(node), message: Message.notNominal(attribute: attributeName(node)))
            ])
        }

        // Nested types get a `static let` on the enclosing type instead of a file-scope global.
        // Static stored properties are not allowed in generic types or local scopes.
        var isNested = false
        for enclosing in context.lexicalContext {
            if enclosing.is(FunctionDeclSyntax.self) || enclosing.is(ClosureExprSyntax.self)
                || enclosing.is(InitializerDeclSyntax.self) || enclosing.is(AccessorDeclSyntax.self) {
                throw DiagnosticsError(diagnostics: [
                    Diagnostic(node: Syntax(node), message: Message.localType(attribute: attributeName(node)))
                ])
            }
            if hasGenericParameters(enclosing) {
                throw DiagnosticsError(diagnostics: [
                    Diagnostic(node: Syntax(node), message: Message.genericEnclosingType(attribute: attributeName(node)))
                ])
            }
            if enclosing.is(StructDeclSyntax.self) || enclosing.is(ClassDeclSyntax.self)
                || enclosing.is(ActorDeclSyntax.self) || enclosing.is(EnumDeclSyntax.self)
                || enclosing.is(ExtensionDeclSyntax.self) {
                isNested = true
            }
        }
        let storage = isNested ? "private static" : "private"

        // `kind` must be a literal: only constant expressions may initialise a @section global.
        let record = """
        let __mediator_record_\(name): DiscoveryRecord = (
            kind: 1,
            reserved: 0,
            accessor: { Mediator.__erase(\(name).self) }
        )
        """

        return [
            """
            #if canImport(Darwin)
            @section("__DATA_CONST,__swift5_mediatr") @used
            \(raw: storage) \(raw: record)
            #elseif os(Linux) || os(Android) || os(FreeBSD)
            @section("swift5_mediatr") @used
            \(raw: storage) \(raw: record)
            #endif
            """
        ]
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

    private static func nominalName(of declaration: some DeclSyntaxProtocol) -> String? {
        if let d = declaration.as(StructDeclSyntax.self) { return d.name.trimmed.text }
        if let d = declaration.as(ClassDeclSyntax.self) { return d.name.trimmed.text }
        if let d = declaration.as(ActorDeclSyntax.self) { return d.name.trimmed.text }
        if let d = declaration.as(EnumDeclSyntax.self) { return d.name.trimmed.text }
        return nil
    }

    private static func hasGenericParameters(_ node: Syntax) -> Bool {
        if let d = node.as(StructDeclSyntax.self) { return d.genericParameterClause != nil }
        if let d = node.as(ClassDeclSyntax.self) { return d.genericParameterClause != nil }
        if let d = node.as(ActorDeclSyntax.self) { return d.genericParameterClause != nil }
        if let d = node.as(EnumDeclSyntax.self) { return d.genericParameterClause != nil }
        return false
    }

    private static func attributeName(_ node: AttributeSyntax) -> String {
        node.attributeName.trimmed.description
    }

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

    enum Message: DiagnosticMessage {
        case notNominal(attribute: String)
        case localType(attribute: String)
        case genericEnclosingType(attribute: String)

        var message: String {
            switch self {
            case .notNominal(let attribute):
                "@\(attribute) can only be applied to a struct, class, actor or enum"
            case .localType(let attribute):
                "@\(attribute) cannot be applied to a type declared inside a function; move it to type or file scope"
            case .genericEnclosingType(let attribute):
                "@\(attribute) cannot be applied to a type nested in a generic type, because the discovery record is a static stored property"
            }
        }
        var diagnosticID: MessageID { MessageID(domain: "SwiftMediatorMacros", id: "\(self)") }
        var severity: DiagnosticSeverity { .error }
    }
}
