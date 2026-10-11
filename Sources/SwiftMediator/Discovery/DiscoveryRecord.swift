/// Layout of one entry in the discovery section. Written by the `@Handler` macro,
/// read by `DiscoverySection`.
///
/// Only constant expressions may initialise a `@section` global, so the record is a
/// plain tuple whose accessor is a non-capturing C function pointer that returns the
/// type metadata. Reading it back is `unsafeBitCast(ptr, to: Any.Type.self)`.
public typealias DiscoveryAccessor = @convention(c) () -> UnsafeRawPointer
public typealias DiscoveryRecord = (kind: UInt32, reserved: UInt32, accessor: DiscoveryAccessor)

public enum DiscoveryRecordKind {
    /// The accessor returns the metadata of a type conforming to one of the handler protocols.
    public static let type: UInt32 = 1
}

/// Section names. Mach-O section names are limited to 16 bytes.
public enum DiscoverySectionName {
    public static let machO = "__DATA_CONST,__swift5_mediatr"
    public static let elf = "swift5_mediatr"
}

extension Mediator {
    /// Called from macro-generated accessors. Erases a metatype to a raw pointer.
    @inlinable
    public static func __erase(_ type: Any.Type) -> UnsafeRawPointer {
        unsafeBitCast(type, to: UnsafeRawPointer.self)
    }
}
