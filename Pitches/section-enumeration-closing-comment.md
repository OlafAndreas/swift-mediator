Closing comment for "[Pitch] Runtime enumeration of custom sections" (topic 90011)

Thank you for the replies here. I have taken the advice to state the want rather than the mechanism and written a new pitch: [link to the new thread].

It keeps what this thread proposed, runtime access to custom sections, now backed by the section index SE-0492 described and extended to COFF and Wasm. On top of it sits the thing I actually want: a marker attribute on types that the runtime can enumerate, written as a narrowed revision of SE-0385. The observation API and the idea of a kind in `swift5_tests` are dropped, for the reasons given here. The function takes a `StaticString`, returns `UnsafeRawBufferPointer` and is back-deployed, so a library with strict availability constraints can adopt it; a `RawSpan` form is listed as a future direction.

The section access is implemented on a branch of swiftlang/swift, and swift-discovery runs on it with a ten-line change in place of swift-sections. The full proposal is on my fork: https://github.com/OlafAndreas/swift-evolution/blob/olaf/custom-type-metadata/proposals/NNNN-custom-type-metadata.md

I would like to continue the conversation in the new thread.
