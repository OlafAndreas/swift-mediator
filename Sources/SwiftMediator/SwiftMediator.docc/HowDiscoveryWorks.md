# How discovery works

Zero registration, the same way Swift Testing finds `@Test`.

## The record

``Handler()`` and ``Behavior()`` expand to a file-scope global (or a `static let` on the
enclosing type) placed in a dedicated binary section with `@section` and `@used`:

```swift
@section("__DATA_CONST,__swift5_mediatr") @used
private let __mediator_record_PlaceOrderHandler: DiscoveryRecord = (
    kind: 1, reserved: 0,
    accessor: { Mediator.__erase(PlaceOrderHandler.self) }
)
```

Only constant expressions may initialise such a global, so the record is a tuple whose
accessor is a non-capturing C function pointer returning the type metadata.

## The scan

``DiscoverySection`` walks every loaded image once, on first use, and caches the result.

- On Mach-O, `getsectiondata` reads the section from each image.
- On ELF (Linux, Android, FreeBSD), a small C shim exposes the linker's weak
  `__start_swift5_mediatr` and `__stop_swift5_mediatr` symbols, which bound the section in
  the image the shim is linked into. For statically linked SwiftPM products that is the
  executable.
- Windows PE is not implemented; register explicitly there.

Images loaded after the first scan are not seen; ``DiscoverySection/rescan()`` exists for
that case.

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
  Discovery sees what is loaded, not what is in the source tree.
- Dead stripping keeps the records because they are marked `@used`.
