# Runtime enumeration of custom sections

* Proposal: SE-NNNN
* Authors: Olaf Andreas Øvrum
* Review Manager: TBD
* Status: **Pitch** ([forum thread](https://forums.swift.org/t/pitch-runtime-enumeration-of-custom-sections/90011))
* Implementation: library-level prototype of the proposed API at [OlafAndreas/swift-sections](https://github.com/OlafAndreas/swift-sections), consumed by [swift-discovery](https://github.com/OlafAndreas/swift-discovery) and through it by [swift-mediator](https://github.com/OlafAndreas/swift-mediator); compiler and runtime changes not yet started
* Related: [SE-0492 Section Placement Control](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0492-section-control.md) ([pitch thread](https://forums.swift.org/t/pitch-3-section-placement-control/77435), [acceptance](https://forums.swift.org/t/accepted-with-modifications-se-0492-section-placement-control/82701)), [SE-0385 Custom Reflection Metadata](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0385-custom-reflection-metadata.md) (returned for revision), Swift Testing's [test content ABI](https://github.com/swiftlang/swift-testing/blob/main/Documentation/ABI/TestContent.md)

## Introduction

SE-0492 lets a library place a constant global into a named binary section. It deliberately stops there. Its Future Directions list "a unified runtime API for reading section contents across platforms and modules" and "macro-based linker sets and plugin registration" as work still to do. Its ELF design describes a `swift5_sections` index of custom section bounds; the Swift 6.4 toolchain does not emit it, and nothing in the runtime would read it if it did.

This proposal is that follow-on. It adds one runtime API that returns the contents of a named section in every loaded image, on every object format Swift supports, with notification for images loaded later. Everything a library builds on top, such as test discovery, plugin registries or handler lookup, becomes a loop over records it already knows the layout of:

```swift
for records in SectionContents.loaded(sectionName) {
    for record in records.bindMemory(to: MyRecord.self) { ... }
}
```

## Motivation

### What libraries do today

Since Swift 6.3 the pattern is legal and in use: a macro expands to a `@section` `@used` global whose value is a tuple of integers and C function pointers, and the library reads the section back at startup. Swift Testing does it for `@Test` in `swift5_tests`. The reference implementation for this proposal, `swift-discovery`, does it for a keyed `@Discoverable(Key.self)` attribute that a mediator framework uses to find request handlers. Both had to write the reading half themselves, and the reading half is where the cost is:

- **Mach-O.** Walk `_dyld_image_count`, call `getsectiondata` per image. Swift Testing's implementation notes that this walk is racy against images loading on other threads and prefers Objective-C runtime entry points when available. It also notes that building a `String` inside the walk can recurse into a libobjc lock, so section names must be `StaticString`.
- **ELF.** Section headers are not mapped at runtime. A library has three options. It can link a C target that references the linker's `__start_` and `__stop_` symbols, which only cover the one image the C target is linked into. It can enumerate images with `dl_iterate_phdr` and re-read each image's section headers from its file on disk, which is what the reference implementation does and which fails for images whose files are gone. Or it can rely on the Swift runtime already knowing its section by name, which Swift Testing gets because `MetadataSections` gained a `swift5_tests` field in version 4 and no other library does. The linker knew every one of these addresses; the toolchain simply does not record them.
- **COFF.** Parse the PE headers of every loaded module in memory, find the grouped section, and skip the zero padding that older SwiftRT emitted. Swift Testing's walker still carries a `FIXME` for long section names.
- **Wasm and static linking.** Start and stop symbols, under a different spelling per format.

The reference implementation, `swift-sections`, is the reading half done as well as a library can do it: about two hundred lines of Swift and C. On Mach-O it registers with dyld's add-image callback, the same registration the runtime uses, so every image is seen, later images are observed, and there is no racy walk. On ELF it opens and parses every loaded image's file to recover addresses the linker had at link time. It has no Windows path until someone ports Swift Testing's. Every library that wants discovery either depends on something like it or rewrites a worse version. The Swift runtime already solves every one of those problems for its own sections. It just does not share the solution.

### The section a library can borrow today, and why that is not enough

Swift Testing's test content ABI permits third-party records in `swift5_tests` under a `kind` value reserved by opening an issue against Swift Testing. Because the runtime enumerates that section, a library that adopts it gets ELF and COFF support without writing a walker. That is the strongest argument that the demand is real, and it is also a sign that the solution is in the wrong place. One package owns the section, assigns kinds by hand, fixes a record shape designed for tests, and cannot change it without breaking everyone who borrowed it. A runtime API that enumerates any named section makes the borrowing unnecessary and lets Swift Testing own its own section again.

### Why not go straight to a typed attribute

An earlier draft of this pitch proposed `@discoverable(Key.self)` as a language attribute with a compiler-emitted record. Building the library-level version showed why that is the second step and not the first:

- A language attribute cannot be applied by a macro. Attached macros do not add attributes to the declaration they are attached to, so a framework spelling such as `@Handler` could not expand to `@discoverable`. Adopters would write both, or the attribute would have to be permitted on extensions. Either is a design question the section API does not need answered.
- Peer macros cannot introduce arbitrary names at global scope, so a macro can emit exactly one record global per declaration. The reference implementation packs several keys into one global as a tuple of records, which works only because the reader walks bytes at a fixed stride. A compiler-emitted record would avoid that, but the reader is still the hard part.
- Everything the attribute would need from the runtime is the section API. Shipping the API first lets the attribute be designed against real adopters, and lets Swift Testing, Vapor-style routers and dependency-injection containers keep their own record shapes in the meantime.

## Proposed solution

A library declares its section name once, in the same `#if objectFormat` ladder SE-0492 already requires for `@section`, and asks the runtime for the contents:

```swift
#if objectFormat(MachO)
let handlerSection = SectionName("__DATA_CONST,__swift5_hndlr")
#elseif objectFormat(ELF) || objectFormat(Wasm)
let handlerSection = SectionName("swift5_hndlr")
#elseif objectFormat(COFF)
let handlerSection = SectionName(".sw5hndlr")
#endif

for records in SectionContents.loaded(handlerSection) {
    for record in records.bindMemory(to: HandlerRecord.self) {
        register(unsafeBitCast(record.type(), to: Any.Type.self))
    }
}
```

A library that supports plugins loaded after startup observes instead of enumerating:

```swift
let token = SectionContents.observe(handlerSection) { records in
    // Called once for each image already loaded, then once per image loaded later.
}
```

`swift-sections` is deleted outright; its API is the proposal. `swift-discovery`, which already reads through it, changes one import. Swift Testing's `SectionBounds.swift` becomes a few lines.

## Detailed design

### API

```swift
/// A custom section, named as in `@section` for the current object format.
public struct SectionName: Sendable, Hashable {
    public init(_ name: StaticString)
}

public enum SectionContents {
    /// The contents of `section` in each currently loaded image that has it, one buffer per
    /// image, in image load order. Buffers remain valid while the image stays loaded.
    public static func loaded(_ section: SectionName) -> [UnsafeRawBufferPointer]

    /// Calls `handler` for each loaded image that has `section`, then for each image loaded
    /// afterwards. Returns a token; dropping it stops future calls.
    public static func observe(
        _ section: SectionName,
        _ handler: @escaping @Sendable (UnsafeRawBufferPointer) -> Void
    ) -> ObservationToken
}
```

`SectionName` takes a `StaticString` so that no allocation happens on the enumeration path, which Swift Testing found necessary on Darwin. The API returns raw bytes and never interprets them. During the SE-0492 review it was noted that Swift struct layout is not guaranteed and that anything placed in a section for discovery needs a stable data format readable by the runtime, libraries and out-of-process tools; that remains each library's responsibility, and keeping the runtime out of the record format is what lets Swift Testing, `swift-discovery` and future adopters each keep their own. The compiler diagnoses a Mach-O name longer than 16 bytes at the `@section` site, which it does not do today; the limit is easy to hit and the failure is a silent empty section.

### Semantics

- **Order.** Images in load order, bytes in layout order within an image. Neither is a contract; libraries that need stable order sort their own records.
- **Duplicates.** A module linked statically into two images contributes its records twice. The API does not deduplicate because it does not know the record layout; the reference implementation dedupes on the type's metadata pointer.
- **Lifetime.** A buffer is valid while its image is loaded. Swift does not support unloading images that contain Swift metadata, so in practice buffers live for the process.
- **Retention.** Only `@used` globals are guaranteed to survive dead stripping; this is unchanged from SE-0492. A static archive member that nothing references is never linked, and its records go with it, which is the same caveat protocol conformance records have today. The proposal documents it rather than solving it.
- **Observer restrictions.** `observe` handlers may run on the thread that loaded the image, under the loader's lock on Darwin. A handler must not load images, must not block on work that might, and should copy what it needs and return. These are the rules the Swift runtime already follows for its own image callbacks.

### Runtime

The runtime already tracks every loaded image for its own metadata sections and receives a callback per image on Mach-O (dyld), ELF and COFF (`swift_addNewDSOImage` from `swiftrt.o`) and Wasm. This proposal extends that machinery to custom sections:

- **Mach-O.** Image enumeration goes through the runtime's existing dyld registration rather than a fresh `_dyld_image_count` walk, which closes the race Swift Testing documents. Section lookup is `getsectiondata` on the recorded header.
- **ELF.** The compiler emits the `swift5_sections` index SE-0492 specified, one entry per custom section with name, start and stop, in every object that places something in a custom section. `swiftrt.o` passes the index to the runtime in a new `MetadataSections` field. This is the step SE-0492 explicitly left for later, and it replaces the file re-read that is the only generic option today.
- **COFF.** The runtime walks the module's in-memory PE section headers for the grouped section, as Swift Testing does, once, for every library.
- **Wasm and static linking.** Start and stop symbols, resolved by the runtime from the same index.

Adding a field to `MetadataSections` is a versioned change to a struct that already carries a version, and the same change was made for `swift5_tests`. Older images report an older version and simply have no custom-section index.

## Source compatibility

Purely additive.

## ABI compatibility

Additive. One new field in `MetadataSections` behind a version bump on ELF and COFF; no change to existing sections or record layouts. Binaries built with older compilers lack the `swift5_sections` index on ELF and are reported as having no custom sections, which matches what a library sees today for any image but its own.

## Implications on adoption

The API is availability-gated on platforms with an OS-shipped runtime. On Darwin the enumeration half can be `@_alwaysEmitIntoClient` over `getsectiondata`, so a library can use the new API against older OS versions with no behavior change; only `observe` needs the shipped runtime. On Linux and Windows the toolchain ships the runtime, so availability follows the toolchain.

Libraries using `@section` today migrate by replacing their walker with `loaded` and, if they want late images, `observe`. Record layouts are untouched. Swift Testing can migrate `SectionBounds.swift` without changing its test content ABI.

## Alternatives considered

### Keep writing the walker

This works for Darwin and for the main image on ELF, and the cost per library is small. The gaps are structural: no other images on ELF, no Windows until ported, late images missed, and a race on Darwin that only the toolchain's own library knew to avoid. The runtime closes all four for its own sections already.

### Reserve a `kind` in `swift5_tests`

Available today and cross-platform, because the runtime enumerates that section. Rejected as the long-term answer because it makes one package the registrar for every discovery mechanism in the ecosystem, fixes a test-shaped record, and gives that package no way to evolve its own section. It is the right stopgap until this API ships, and it is evidence that the API is wanted.

### A typed `@discoverable(Key.self)` attribute first

Discussed under Motivation. It needs this API underneath it, cannot be applied by a macro without allowing the attribute on extensions, and fixes a record shape before adopters have shown what they need. It is listed under Future Directions.

### Revive SE-0385

SE-0385 attaches runtime-constructed attribute instances to types, functions and properties. Its open questions were about evaluation and breadth, not about reading sections, and its implementation would also need this API. The two are complementary.

### `dl_iterate_phdr` plus the image file on ELF

Program headers are mapped; section headers are not, so `dl_iterate_phdr` alone cannot find a custom section. The reference implementation combines it with re-reading each image's section headers from disk. That works for the common case and is what this proposal's ELF path would replace: it fails for images whose files were deleted or replaced after loading, it does file I/O on a path that should be a table lookup, and it recovers at runtime information the linker discarded. It is the strongest evidence that the index belongs in the toolchain.

### Build-time code generation

A SwiftPM plugin cannot see other modules, breaks under conditional compilation, and reintroduces the registry the pattern exists to remove.

## Future directions

- **Keyed discovery.** `@discoverable(Key.self)` on nominal types and on extensions, with a compiler-emitted record holding relative indirectable pointers to the type's and the key's context descriptors, and `Discoverable.types(for:)` over them. The extension form is what lets a framework macro apply it. This is the narrow subset of SE-0385 that the reference implementation already provides at library level.
- **Constant payloads.** With broader constant expressions from SE-0492's own future directions, records could carry a route path or a priority inline.
- **Conformance enumeration.** `Discoverable.types(conformingTo:)` over the existing conformance records, for cases where opt-in is not required.
- **Section name validation.** Beyond the Mach-O length check, the compiler could diagnose a COFF name without the grouped-section suffix when the global is meant to be enumerated.

## Acknowledgements

SE-0492 made the writing half possible and named the reading half as the next step. Swift Testing's `SectionBounds.swift` and its test content ABI document showed, in production code, exactly what the reading half costs on each platform and what a shared section looks like when one package has to own it. The `swift-sections`, `swift-discovery` and `swift-mediator` packages were built to measure the same costs from outside the toolchain and to prototype the API surface proposed here.
