# Swift can finally find your types at startup. Here is what it cost.

*Published on Medium: https://medium.com/@olaf.ovrum/swift-can-finally-find-your-types-at-startup-here-is-what-it-cost-ad3c67de9803*

*Draft. Target: Medium, about 11 minutes.*

---

This is a request handler. It is the whole handler.

```swift
@Handler
struct PlaceOrderHandler: RequestHandler {
    let repository: any OrderRepository
    let clock: any Clock

    func handle(_ request: PlaceOrder) async throws -> PlaceOrder.Response {
        let order = try await repository.create(request.items, at: clock.now)
        return .init(orderID: order.id)
    }
}
```

And this is the whole call site.

```swift
let mediator = try Mediator()
let receipt = try await mediator.send(PlaceOrder(items: cart))
```

Nothing registers the handler. No list of handlers in a composition root, no `register(PlaceOrderHandler.self)` that someone forgets when they add the next one, no code generation step. The mediator finds every `@Handler` in the binary when it starts, builds each one from its stored properties when a request arrives, and fails at startup if two handlers claim the same request.

If you have used MediatR in .NET, you know this shape. If you have tried to build it in Swift, you know why you could not: Swift has no way to enumerate the types in a program. That changed in Swift 6.3, quietly, in a proposal that was not about discovery at all. I spent a week finding out what it makes possible and where it stops. This is that week.

## The attribute that changed it

SE-0492, Section Placement Control, adds two attributes. `@section` puts a global's storage into a named section of the binary. `@used` tells the linker not to strip it. That is all the proposal does, and it was written for firmware tables and linker sets, not for frameworks.

The reason it matters for discovery is what a section is. A section is a contiguous run of bytes in the executable or library that the loader maps into memory under a name. If every handler drops a small record into the same section, the records end up next to each other, and anything that can find the section can walk the records. This is exactly how Swift Testing finds your `@Test` functions, and before SE-0492 it was something only the toolchain's own libraries could do.

There is one rule that shapes everything downstream. A `@section` global has to be a compile-time constant, because the bytes go into the binary at link time and nothing runs to initialise them. The proposal defines constant narrowly: integer and float literals, booleans, tuples of those, references to non-generic functions, and closure literals that capture nothing. No strings. No enum cases. No calls.

So a discovery record looks like this, and cannot look like much else:

```swift
@section("__DATA_CONST,__swift5_discov") @used
private let __mediator_record_PlaceOrderHandler: (
    version: UInt32, flags: UInt32,
    type: @convention(c) () -> UnsafeRawPointer,
    key: @convention(c) () -> UnsafeRawPointer
) = (
    version: 1,
    flags: 0,
    type: { unsafeBitCast(PlaceOrderHandler.self as Any.Type, to: UnsafeRawPointer.self) },
    key: { unsafeBitCast(MediatorComponents.self as Any.Type, to: UnsafeRawPointer.self) }
)
```

Two integers and two C function pointers. Each pointer is a closure that returns a type's metadata erased to a raw pointer, because a metatype is not a constant but a function that returns one is. The reader walks the section at a fixed stride, calls each closure, and casts the result back to `Any.Type`. From there, `type as? any RequestHandler.Type` opens the existential and the mediator can read the handler's request type and key it.

Nobody writes that record by hand. `@Handler` is a macro that emits it, plus an initialiser that resolves each stored property from a dependency container. The developer's cost per handler is one attribute. The framework's cost is everything below.

## Failure one: the enum case

My first record used `kind: DiscoveryRecordKind.type` instead of `kind: 1`, because a named constant is obviously better than a magic number. The compiler disagreed. A static property is not a literal, and the constant-expression checker does not look through it. The record became `version: 1`, with a doc comment where the enum used to be.

Small, but it set the tone. Every convenience you would normally reach for is off the table in this one global. The macro has to generate the dumbest possible Swift, and the readability has to live in the macro's source instead.

## Failure two: sixteen bytes

The first section name I chose was `__swift5_mediator`. Mach-O section names are limited to 16 bytes, including the two underscores. That name is 17. The compiler did not complain, the linker did not complain, and the section was simply not there at runtime. The fix was `__swift5_mediatr`, and later `__swift5_discov` when the code moved to its own package.

I mention this one because it is the kind of failure that does not fail. The pitch that came out of this work proposes a compiler diagnostic for it. It is three lines in type checking and would have saved an afternoon.

## Failure three: Linux sees one image

Reading the section on macOS is pleasant. dyld gives you every loaded image and `getsectiondata` returns the bytes by name. On Linux there is no equivalent, because ELF does not map section headers into memory at all. The documented trick is that the linker synthesises `__start_<name>` and `__stop_<name>` symbols for any section whose name is a valid C identifier, so a small C file can reference them and hand the bounds to Swift.

It works, with a catch that took me a while to see. Those symbols are per image, and they are only defined in the image that links the C file. For a statically linked SwiftPM executable that is the executable, which is fine. For anything loaded with `dlopen`, or for a handler library linked as a shared object, the records are invisible. Swift Testing gets around this because the Swift runtime learned the name of its section and records the bounds itself when each image loads. No other library gets that.

## Failure four: the test bundle that merged everything

CI went red on a test that had nothing to do with discovery. A Fluent test was failing to decode a response, and the response it was decoding came from a handler in a different test target.

On the macOS runner's toolchain, SwiftPM links every test target in the package into a single test bundle. One image, one section, every module's handlers in it. Each test suite's mediator was discovering the handlers of every other suite, and the first one to claim a request won.

The fix became a feature: a discovery policy. `Mediator(discovery: .thisModule())` restricts discovery to types declared in the calling module, and `.modules(["Orders", "Billing"])` names them explicitly. The module name comes from the type's qualified name, which is the only place the runtime exposes it. Every test suite in the repository now uses the policy, and the article you are reading would have been shorter if I had thought about test bundles on day one.

## Failure five: a macro can only name one global

By this point discovery had grown into its own package, with a generic `@Discoverable(Key.self)` attribute that any framework can use, and the mediator's `@Handler` as one client of it. The obvious next step was letting a type be discovered under several keys, which means several records, which means several globals.

Swift's macro system has a rule I had not met: a peer macro has to declare the names it introduces, and the usual way is `names: prefixed(__discovery_record_)`, which covers exactly the prefix plus the declaration's own name. One name per declaration. The escape hatch is `names: arbitrary`, which the compiler refused with a message I had to read twice:

```
'peer' macros are not allowed to introduce arbitrary names at global scope
```

The answer was to pack every key into the one global as a tuple of records. Tuples lay out their elements consecutively, each record is 24 bytes, and the reader walks bytes at a fixed stride without caring where one global ends and the next begins. It works, it is slightly disgusting, and it is one of two reasons the eventual pitch does not propose a language attribute: an attribute that a macro cannot apply, or can apply only once, is an attribute adopters will have to write by hand.

## Failure six: the index that is not there

Working through the Linux problem, I read SE-0492 properly. It knows about the ELF limitation and specifies a fix: the compiler emits a `swift5_sections` index into every object that uses a custom section, listing each section's name and bounds, so that the runtime can register them per image the way it does for Swift's own metadata. The proposal then says that reading the index "is left as a future direction".

I compiled a probe on the Swift 6.4 Linux toolchain and looked at the section table. The index is not emitted. The custom sections are there; the index is not, and there is no flag to request it. So today a generic library has exactly one way to see custom sections in every loaded ELF image: enumerate images with `dl_iterate_phdr`, open each one's file on disk, parse its section headers, and translate addresses by the load bias. I wrote that. It is 70 lines of C, it passes its tests, and it is the most convincing argument I have for why this belongs in the runtime.

## What the runtime already knows

Every one of these problems is already solved inside the Swift runtime, for Swift's own sections. It tracks every loaded image through dyld's callbacks on Apple platforms and through a stub linked into every image on Linux and Windows. It knows section bounds at load time because the stub records them. It gets notified when images load late. It just has no entry point that lets a library ask for a section by name.

So the last thing I built was a proposal. Not for the mediator, and not for a discovery attribute, but for the smallest thing that would have made the week unnecessary: one runtime API that returns the contents of a named section from every loaded image, plus an observer for images loaded later. It is the follow-on SE-0492 asked for. The prototype is a dependency-free package, `swift-sections`, that does the dyld registration on macOS and the disk re-read on Linux, and the discovery package and the mediator read through it. If the proposal lands, the prototype is deleted and nothing above it changes.

The pitch is on the Swift Forums. If you know the runtime's image-inspection code, the thread has a question for you about how the ELF index should be handed over. If you maintain anything that walks a section today, it has a second one.

## The yardstick

I had one rule for the mediator from the start: using it has to feel like a large win per line, or it is not worth adding a dependency. Here is where it landed, counted in lines a developer writes per feature.

- A new request type: the struct and its nested `Response`, which you would write anyway. Zero lines of framework.
- A new handler: one attribute. The initialiser, the registration and the keying are generated or discovered.
- A cross-cutting behavior such as retry or logging: one attribute on a struct with one method and an `order`.
- A test with a stubbed handler: one trait on the test, `.resolver`, and one `stub` line in the configuration.
- Scoping discovery to a module, which you need in tests: one argument.

Against that, three packages, one macro, a C file, and a Swift Evolution pitch. The developer-facing side of the ledger is where I wanted it. The framework-facing side is the part Swift could still make cheaper, and that is what the pitch is for.

---

*Code: [swift-mediator](https://github.com/OlafAndreas/swift-mediator), [swift-discovery](https://github.com/OlafAndreas/swift-discovery), [swift-sections](https://github.com/OlafAndreas/swift-sections). Pitch: [Runtime enumeration of custom sections](https://forums.swift.org/t/pitch-runtime-enumeration-of-custom-sections/90011). Requires Swift 6.3; the attributes do not exist in 6.2, which was failure number seven and the shortest.*
