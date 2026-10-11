#ifndef SWIFTMEDIATOR_SECTION_SHIM_H
#define SWIFTMEDIATOR_SECTION_SHIM_H

/// Bounds of the `swift5_mediatr` ELF section in the image this shim is linked into.
/// Both return NULL on non-ELF platforms or when the image has no such section.
/// On Mach-O the Swift side uses getsectiondata instead and never calls these.
const void *swiftmediator_elf_section_start(void);
const void *swiftmediator_elf_section_stop(void);

#endif
