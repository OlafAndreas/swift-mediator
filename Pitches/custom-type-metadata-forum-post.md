[Pitch] Custom metadata attributes for types, and runtime access to custom sections

This revises my pitch from last week, [Runtime enumeration of custom sections](https://forums.swift.org/t/pitch-runtime-enumeration-of-custom-sections/90011), after the feedback there: it says what I want and how I would want it to work, rather than what a library can do today, and it drops the observation API. It also takes up SE-0385, which the Language Workgroup returned in 2023 asking for a design built on macros and constant initialization. Both now exist.

Swift has no way for a library to find the types that opted into it. Every library that needs this works around the gap. Swift Argument Parser takes a hand-maintained `subcommands:` array. SwiftLint regenerates a 254-entry `BuiltInRules.swift` with a tool whenever a rule is added. Quick walks the Objective-C class list and cannot on Linux. Swift Testing wrote a 358-line per-platform walker to find its own tests, and it is the one library whose section the runtime helps with on Linux. I built the same thing for my own framework, in three packages, and met the costs every other library pays: a record format the runtime cannot read, function pointers standing in for metatypes, a walker per platform, and re-reading image files from disk on Linux.

SE-0492 made the writing side a language feature. This pitch is the reading side. What it is like to use:

A library declares a key and applies it to types, directly or from its own macro:

```swift
@customMetadata public enum LintRule {}

@LintRule struct ArrayInitRule: Rule { ... }
@LintRule extension TrailingWhitespaceRule {}   // what a framework macro would emit
```

and asks for the types:

```swift
for case let rule as any Rule.Type in CustomMetadata.types(marked: LintRule.self) {
    registry.register(rule)
}
```

No registry, no code generation, no code at load time. A type registers by existing, in any module, on every platform, and everything else the library knows about it stays where it is today, on the type.

A library that already keeps its own records in a `@section` keeps them and drops its walker:

```swift
for section in customSectionContents(named: pluginSection) {   // the name as written in @section
    for record in section.bindMemory(to: PluginRecord.self) { register(record) }
}
```

It works on Apple platforms, Linux, Windows and Wasm, and on every deployment target the toolchain supports. On Linux it is the first way for a library to see other images' sections without re-reading their files from disk.

The full proposal, with the design, the restrictions and the alternatives, is here: https://github.com/OlafAndreas/swift-evolution/blob/olaf/custom-type-metadata/proposals/NNNN-custom-type-metadata.md. It is written as two parts that may be reviewed separately. The section access is implemented, as a draft pull request to swiftlang/swift (https://github.com/swiftlang/swift/pull/93419): it builds and its tests pass on macOS and Linux, Windows and Wasm emission are checked by cross-compiling and linking, and swift-discovery runs on it with a ten-line change in place of its 315-line walker (https://github.com/OlafAndreas/swift-discovery/tree/olaf/stdlib-sections). The attribute is not implemented, and an implementer is sought.

I would like to hear whether this shape fits the libraries you maintain, and what you would need from it.

Direction and design by me, built on SE-0385 by Pavel Yaskevich, Holly Borla, Alejandro Alonso and Stuart Montgomery, on SE-0492 by Kuba Mracek, and on the feedback in the earlier thread; prose by AI.
