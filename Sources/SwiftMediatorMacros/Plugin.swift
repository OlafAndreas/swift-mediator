import SwiftCompilerPlugin
import SwiftSyntaxMacros

@main
struct SwiftMediatorMacrosPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        DiscoverableMacro.self,
        RequiresHandlerMacro.self,
    ]
}
