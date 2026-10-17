# Link-time uniqueness and existence for handlers

This branch is a proof of concept for a future direction of the pitch
[Custom Metadata Attributes for Types and Runtime Access to Custom Sections](https://github.com/OlafAndreas/swift-evolution/blob/olaf/custom-type-metadata/proposals/NNNN-custom-type-metadata.md):
a way to say, at compile and link time, that exactly one handler exists for a
request. It uses today's toolchain and macros only, so it approximates what the
compiler could do and documents where the approximation falls short.

## What the macros do

`@Handler(for: CreateOrder.self)` emits, beside the handler's discovery record, a
strong C symbol named from the request type:

```swift
@_cdecl("mediator_handler_for_CreateOrder") @used func __mediator_handler_for_CreateOrderHandler() {}
```

`@RequiresHandler()` on the request type emits an undefined reference to the same
symbol and a `@used` global whose initializer touches it, so the reference
survives into the object file:

```swift
@_silgen_name("mediator_handler_for_CreateOrder") private func __mediator_demand_CreateOrder()
@used private let __mediator_requires_CreateOrder: Int = { __mediator_demand_CreateOrder(); return 0 }()
```

The linker then enforces both halves:

| Case | Outcome |
|---|---|
| exactly one handler | links and runs |
| no handler, request requires one | undefined symbol at link |
| two handlers in two modules | duplicate symbol at link |
| two handlers in one module | compile error (two definitions of one symbol) |

The demo package in the pitch author's scratchpad exercised the four cases;
`Tests/SwiftMediatorMacrosTests/LinkTimeUniquenessTests.swift` checks the
expansions.

## Where the approximation falls short

* **The symbol comes from the spelled type name, not the mangled one.** A macro
  sees `CreateOrder.self` as source text. `CreateOrder` in two unrelated
  packages collides, and `Orders.CreateOrder` written from outside the module
  does not match `CreateOrder` written inside it. The compiler would derive the
  symbol from the mangled name of the request type and the key, which has
  neither problem.
* **The symbol is exported.** `@_cdecl` on an internal function gives a
  default-visibility symbol, so every dynamic library built with the macro
  exports a `mediator_handler_for_*` symbol. The compiler would make it hidden.
* **A demand on a protocol is not expressible.** The pitch's direction lets a
  protocol declare the demand so that every non-generic conformer inherits it,
  with a per-type opt-out; a macro cannot see conformers.
* **Dynamic libraries weaken the guarantee**, as they do for the compiler
  version. The check is a link-time check, so it holds when the demander and
  the provider are in one link. A framework that wants it everywhere puts the
  demand in a static target that the program always links. Carried in a dynamic
  library instead, the demand is still enforced at the executable's link on ELF
  (its linkers reject unresolved symbols in the shared libraries they link
  against, `--no-allow-shlib-undefined`), while on Mach-O it needs
  `-undefined dynamic_lookup` and fails at launch rather than at link, or
  degrades to a run-time check when weak-linked, and on COFF a DLL cannot carry
  an unresolved import at all. Images loaded later are checked by the query at
  run time in every case.

## The direction, as the pitch states it

Once a key can take a metatype argument, a key may declare that argument
`unique`: the compiler emits a strong symbol per application, so a second
application with the same argument is a diagnostic within a module and a
duplicate-symbol error within an image. A type, or a protocol on behalf of its
conformers, may declare that it `requires` an application: the compiler emits
an undefined reference, so a missing application fails to link and pulls the
providing object file out of a static archive that nothing else references. A
key declared both `unique` and `required` means exactly one application per
image, which lets a framework insist that the program linking it provides one
configuration type. `@main` already works this way for one fixed symbol, with
the platform's entry point as the demander; the direction gives libraries the
same guarantee for their own types.
