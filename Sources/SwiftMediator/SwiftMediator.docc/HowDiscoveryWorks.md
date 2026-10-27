# How discovery works

Zero registration, the same way Swift Testing finds `@Test`.

## The record

Discovery is provided by [SwiftDiscovery](https://github.com/OlafAndreas/swift-discovery),
a small package extracted from this one. ``Handler()`` and ``Behavior()`` expand to a
file-scope global (or a `static let` on the enclosing type) placed in a dedicated binary
section with `@section` and `@used`:

```swift
@section("__DATA_CONST,__swift5_discov") @used
private let __mediator_record_PlaceOrderHandler: (version: UInt32, flags: UInt32, type: @convention(c) () -> UnsafeRawPointer, key: @convention(c) () -> UnsafeRawPointer) = (
    version: 1, flags: 0,
    type: { unsafeBitCast(PlaceOrderHandler.self as Any.Type, to: UnsafeRawPointer.self) },
    key: { unsafeBitCast(SwiftMediator.MediatorComponents.self as Any.Type, to: UnsafeRawPointer.self) }
)
```

Only constant expressions may initialise such a global, so the record is a tuple whose
accessors are non-capturing C function pointers returning type metadata. The `key` names
``MediatorComponents``, which is how the mediator's records stay separate from any other
`@Discoverable` records in the same binary. The expansion spells everything out, so your
module never imports SwiftDiscovery.

## The scan

`Discoverable.types(for:)` walks every loaded image once, on first use, and caches the
result per key. ``Mediator/discoveredTypes(_:)`` is the mediator's view of it.

- Section reading comes from [swift-sections](https://github.com/OlafAndreas/swift-sections).
  On Mach-O it registers with dyld, so every image is seen, including ones loaded later.
  On ELF (Linux, Android, FreeBSD) it enumerates images with `dl_iterate_phdr` and re-reads
  each image's section headers from disk, because ELF does not map them.
- Windows PE is not implemented; register explicitly there.

Results are deduplicated and sorted by mangled name, so registration order is the same on every launch of a binary. It is not alphabetical.
The index is built once; images loaded after that show up in `Discoverable.rescan()`.

Each recovered type is cast to `any RequestHandler.Type`, `any EventHandler.Type` or
`any PipelineBehavior.Type`. The cast opens the existential into a generic registration
function where the handler's `Req` type is read and keyed. Nothing is looked up by string.

## Policies

Discovery sees every record in every loaded image. Restrict it with a ``Discovery`` policy
when independent modules share a binary. SwiftPM links all test targets into one bundle on
some toolchains, so test suites should always scope discovery to themselves:

```swift
try Mediator(discovery: .thisModule())
try Mediator(discovery: .modules(["Orders", "Billing"]))
try Mediator(discovery: .none) { $0.register(OnlyThis.self) }
```

## Limits

- A handler nested in a generic type or declared inside a function cannot carry a record;
  the macro reports it.
- A handler in a library that is not linked into the final binary is not discovered.
  Discovery sees what is loaded, not what is in the source tree. A static-archive member
  that nothing references is never linked, and its record goes with it.
- Dead stripping and `strip` keep the records, because they are marked `@used` and are read
  from their section rather than looked up by symbol. Verified on macOS (release build,
  stripped, Swift 6.4) and on Linux x86_64 and aarch64 (`--static-swift-stdlib`, stripped,
  Swift 6.3.3).
