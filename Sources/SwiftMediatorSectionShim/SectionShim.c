#include "SwiftMediatorSectionShim.h"

#if defined(__ELF__)
// The linker synthesises __start_<section> / __stop_<section> for any section whose
// name is a valid C identifier, provided something references them. Weak so that an
// image with no @Handler records links and reports an empty range.
extern const char __start_swift5_mediatr[] __attribute__((weak));
extern const char __stop_swift5_mediatr[] __attribute__((weak));

const void *swiftmediator_elf_section_start(void) { return __start_swift5_mediatr; }
const void *swiftmediator_elf_section_stop(void) { return __stop_swift5_mediatr; }
#else
const void *swiftmediator_elf_section_start(void) { return 0; }
const void *swiftmediator_elf_section_stop(void) { return 0; }
#endif
