/// Which discovered types a mediator registers.
///
/// Discovery sees every `@Handler` / `@Behavior` record in the loaded images. That is
/// usually what an app wants. Restrict it when several independent modules share a
/// binary, which is what happens when SwiftPM links all test targets into one bundle:
///
///     try Mediator(discovery: .thisModule())              // this test target only
///     try Mediator(discovery: .modules(["Orders", "Billing"]))
public struct Discovery: Sendable {
    let include: @Sendable (Any.Type) -> Bool

    public init(_ include: @escaping @Sendable (Any.Type) -> Bool) {
        self.include = include
    }

    /// Every record in every loaded image. The default.
    public static let all = Discovery { _ in true }

    /// No discovery; register everything explicitly.
    public static let none = Discovery { _ in false }

    /// Only types declared in the named modules.
    public static func modules(_ names: Set<String>) -> Discovery {
        Discovery { names.contains(moduleName(of: $0)) }
    }

    /// Only types declared in the module this call is written in.
    public static func thisModule(fileID: String = #fileID) -> Discovery {
        .modules([String(fileID.prefix { $0 != "/" })])
    }

    /// The module a type was declared in, from its qualified name.
    public static func moduleName(of type: Any.Type) -> String {
        String(String(reflecting: type).prefix { $0 != "." })
    }

    /// Whether the policy admits `type`.
    public func callAsFunction(_ type: Any.Type) -> Bool { include(type) }
}
