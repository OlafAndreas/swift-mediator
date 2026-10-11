# Fail fast

Configuration mistakes are caught when the mediator is built, never at the first request.

## Errors at construction

the ``Mediator`` initialiser throws ``MediatorError`` for:

- `conflictingHandlers`: two or more handlers claim the same request type.
- `notAHandler`: a type is marked `@Handler` or `@Behavior` but conforms to none of the
  handler protocols.

Build the mediator once in a unit test that only asserts it constructs, and these become
test failures rather than production incidents.

## Errors at dispatch

- `noHandler`: `send` was called for a request type with no handler.
- Resolver errors, such as `ResolverError.unregistered`, surface inside the pipeline when a
  handler or behavior is constructed, so logging and error-mapping behaviors see them.

## Non-throwing contexts

Factory closures and `app.mediator` cannot throw. The Factory binding's `Mediator.failFast`
and the Vapor binding's lazy `app.mediator` turn a construction error into a `fatalError`
with the message, on first resolution. A mediator with a broken registry never reaches a
request.
