Swift has never been able to answer a simple question: "which types in this program opted into X?"

That is why every Swift framework makes you register things by hand. Handlers, routes, migrations, plugins. One list, somewhere, that someone forgets to update.

Swift 6.3 changed that, almost by accident. SE-0492 added @section, meant for firmware tables, and it turns out to be enough to build MediatR-style discovery: write a handler, add one attribute, and the mediator finds it in the binary at startup. No registration code.

I spent a week building it and wrote up what it cost. Six things broke along the way, and each one taught me something about the toolchain:

• a section name that was one byte too long and failed silently
• Linux only seeing the main executable
• a test bundle that merged every module's handlers
• a macro that can only name one global
• an index that SE-0492 specifies and the toolchain does not emit

The last one became a Swift Evolution pitch, now on the forums.

Article: [MEDIUM LINK]
Pitch: https://forums.swift.org/t/pitch-runtime-enumeration-of-custom-sections/90011
Code: https://github.com/OlafAndreas/swift-mediator

#Swift #iOS #ServerSideSwift #SwiftEvolution
