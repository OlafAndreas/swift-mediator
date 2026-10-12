I have wanted MediatR in Swift for years.

Not the library. The feeling. You write a handler, you never register it, and the app just knows it is there. In .NET that comes from reflection. In Swift there was no way to ask "which types in this binary opted in?", so every framework I have used or written ends up with a list somewhere that someone forgets to update.

Last week I noticed that Swift 6.3 had quietly made it possible. SE-0492 added @section, written for firmware tables, and it turned out to be exactly enough. So I built it. One attribute on a handler, and the mediator finds it in the binary at startup.

Then I spent the rest of the week finding out what that costs. Six things broke, and I am still a little annoyed at the section name that was one byte too long and failed without a single warning. Linux only saw the main executable. A test bundle merged every module's handlers. A macro turned out to be allowed to name exactly one global. And an index that the proposal describes is simply not emitted by the toolchain.

That last one bothered me enough that I wrote a Swift Evolution pitch. It is my first, it is on the forums now, and I would genuinely like to be told what I got wrong.

The article is the honest version of the week, failures included.

Article: https://medium.com/@olaf.ovrum/swift-can-finally-find-your-types-at-startup-here-is-what-it-cost-ad3c67de9803
Pitch: https://forums.swift.org/t/pitch-runtime-enumeration-of-custom-sections/90011
Code: https://github.com/OlafAndreas/swift-mediator

#Swift #iOS #ServerSideSwift #SwiftEvolution
