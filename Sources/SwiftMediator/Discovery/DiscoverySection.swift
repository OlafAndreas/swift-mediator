#if canImport(Darwin)
import MachO
#endif
import SwiftMediatorSectionShim

/// Walks every loaded image and returns the types recorded by `@Handler` / `@Behavior`.
public enum DiscoverySection {
    /// The discovered types, scanned once on first use. Swift's lazy statics are
    /// thread-safe, so any number of mediators created in parallel share one scan.
    public static func discoveredTypes() -> [Any.Type] { cached }

    /// Re-walks the loaded images. Only needed if a plugin was loaded after first use.
    public static func rescan() -> [Any.Type] {
        var types: [Any.Type] = []
        forEachRecord { record in
            guard record.kind == DiscoveryRecordKind.type else { return }
            types.append(unsafeBitCast(record.accessor(), to: Any.Type.self))
        }
        return types
    }

    private static let cached: [Any.Type] = rescan()

    static func forEachRecord(_ body: (DiscoveryRecord) -> Void) {
        #if canImport(Darwin)
        let (segment, section) = splitMachOName(DiscoverySectionName.machO)
        for index in 0..<_dyld_image_count() {
            guard let header = _dyld_get_image_header(index) else { continue }
            var size: UInt = 0
            let header64 = UnsafeRawPointer(header).assumingMemoryBound(to: mach_header_64.self)
            guard let data = getsectiondata(header64, segment, section, &size), size > 0 else { continue }
            let count = Int(size) / MemoryLayout<DiscoveryRecord>.stride
            let records = UnsafeRawPointer(data).assumingMemoryBound(to: DiscoveryRecord.self)
            for i in 0..<count { body(records[i]) }
        }
        #elseif os(Linux) || os(Android) || os(FreeBSD)
        // ELF: the linker provides __start_/__stop_ bounds for the section in the image the
        // shim is linked into (the executable, for statically linked SwiftPM products).
        guard let start = swiftmediator_elf_section_start(),
              let stop = swiftmediator_elf_section_stop(),
              stop > start
        else { return }
        let count = (stop - start) / MemoryLayout<DiscoveryRecord>.stride
        let records = start.assumingMemoryBound(to: DiscoveryRecord.self)
        for i in 0..<count { body(records[i]) }
        #else
        // Windows PE is not supported yet. Register handlers explicitly through
        // `Mediator.Configuration`.
        #endif
    }

    private static func splitMachOName(_ name: String) -> (String, String) {
        let parts = name.split(separator: ",", maxSplits: 1).map(String.init)
        return (parts[0], parts[1])
    }
}
