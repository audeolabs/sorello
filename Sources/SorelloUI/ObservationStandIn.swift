// In the build for older Macs, `@Observable` in this module is the stand-in that Sources/SystemCompat/Observation.swift
// describes. The names are declared here, where they are used, so that they win over Apple's, which SwiftUI and other
// frameworks bring in and macOS 13 cannot run. The usual build compiles none of this.
#if SORELLO_LEGACY
import SystemCompat

@attached(memberAttribute)
macro Observable() = #externalMacro(module: "ObservationMacros", type: "ObservableMacro")

@attached(accessor, names: named(init), named(get), named(set), named(_modify))
@attached(peer, names: prefixed(_))
macro ObservationTracked() = #externalMacro(module: "ObservationMacros", type: "ObservationTrackedMacro")

@attached(accessor, names: named(willSet))
macro ObservationIgnored() = #externalMacro(module: "ObservationMacros", type: "ObservationIgnoredMacro")

typealias Observable = SystemCompat.Observable

func withObservationTracking<Result>(
    _ apply: () -> Result, onChange: @autoclosure () -> @Sendable () -> Void
) -> Result {
    SystemCompat.withObservationTracking(apply, onChange: onChange())
}
#endif
