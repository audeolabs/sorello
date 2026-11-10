// swift-tools-version: 6.2
import PackageDescription

// Every module, tests included, is Swift 6 and warning-free. ARCHITECTURE.md, section 2, says what each one holds and may import.
let strict: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
    .treatAllWarnings(as: .error),
]
// The UI and the composition root run on the main actor unless they say otherwise.
let mainActor: [SwiftSetting] = strict + [.defaultIsolation(MainActor.self)]
// An executable records the SDK it was linked against, and AppKit and SwiftUI give it that SDK's design and
// behaviour. SwiftPM's link records the minimum system instead unless clang is told the SDK, which `swift` passes in
// SDKROOT (swiftlang/swift-package-manager#10696). scripts/build-app.sh fails if the app records anything else.
let linkedSDK: [LinkerSetting] = Context.environment["SDKROOT"].map {
    [.unsafeFlags(["-Xclang-linker", "-isysroot", "-Xclang-linker", $0])]
} ?? []

let package = Package(
    name: "Sorello",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Sorello", targets: ["Sorello"]),
        .executable(name: "SorelloSnapshots", targets: ["SorelloSnapshots"]),
        .executable(name: "sorello-transcribe", targets: ["SorelloTranscribe"]),
    ],
    targets: [
        // Neutral modules: nothing here imports a macOS-only framework.
        .target(name: "DictationCore", swiftSettings: strict),
        .target(name: "TextRules", swiftSettings: strict),
        .target(name: "DictionaryKit", swiftSettings: strict),
        .target(name: "DesignCore", swiftSettings: strict),
        .target(name: "SpeechEngine", dependencies: ["DictationCore", "DictionaryKit"], swiftSettings: strict),
        .target(name: "Persistence", dependencies: ["DictationCore", "TextRules"], swiftSettings: strict),

        // macOS.
        .target(name: "SorelloUI", dependencies: ["DesignCore"], swiftSettings: mainActor),
        .target(name: "MacPlatform", dependencies: ["DictationCore", "DictionaryKit"], swiftSettings: strict),
        .target(
            name: "SorelloApp",
            dependencies: ["DictationCore", "TextRules", "DictionaryKit", "DesignCore", "SpeechEngine", "Persistence",
                           "SorelloUI", "MacPlatform"],
            swiftSettings: mainActor
        ),
        .executableTarget(name: "Sorello", dependencies: ["SorelloApp"], swiftSettings: mainActor,
                          linkerSettings: linkedSDK),
        .executableTarget(name: "SorelloSnapshots", dependencies: ["SorelloUI"], swiftSettings: mainActor,
                          linkerSettings: linkedSDK),
        .executableTarget(name: "SorelloTranscribe", dependencies: ["SpeechEngine", "DictionaryKit", "DictationCore"],
                          swiftSettings: strict, linkerSettings: linkedSDK),

        // Tests.
        .target(name: "TestSupport", path: "Tests/TestSupport", swiftSettings: strict),
        .testTarget(name: "DictationCoreTests", dependencies: ["DictationCore", "TestSupport"], swiftSettings: strict),
        .testTarget(name: "TextRulesTests", dependencies: ["TextRules", "TestSupport"], swiftSettings: strict),
        .testTarget(name: "DictionaryKitTests", dependencies: ["DictionaryKit", "TestSupport"], swiftSettings: strict),
        .testTarget(name: "DesignCoreTests", dependencies: ["DesignCore", "TestSupport"], swiftSettings: strict),
        .testTarget(name: "SpeechEngineTests", dependencies: ["SpeechEngine", "DictionaryKit", "DictationCore", "TestSupport"], swiftSettings: strict),
        .testTarget(name: "PersistenceTests", dependencies: ["Persistence", "DictationCore", "TextRules", "TestSupport"], swiftSettings: strict),
        .testTarget(name: "MacPlatformTests", dependencies: ["MacPlatform", "DictationCore", "DictionaryKit", "TestSupport"], swiftSettings: strict),
        .testTarget(name: "SorelloUITests", dependencies: ["SorelloUI", "DesignCore", "TestSupport"], swiftSettings: strict),
        .testTarget(name: "SorelloAppTests",
                    dependencies: ["SorelloApp", "DictationCore", "TextRules", "DictionaryKit", "DesignCore",
                                   "SpeechEngine", "Persistence", "SorelloUI", "MacPlatform", "TestSupport"],
                    swiftSettings: strict),
    ],
    swiftLanguageModes: [.v6]
)
