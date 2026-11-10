// swift-tools-version: 6.2
import PackageDescription

// Every module is Swift 6 and warning-free. ARCHITECTURE.md, section 2, says what each one holds and may import.
let strict: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
    .treatAllWarnings(as: .error),
]
// The UI and the composition root run on the main actor unless they say otherwise.
let mainActor: [SwiftSetting] = strict + [.defaultIsolation(MainActor.self)]

let package = Package(
    name: "Sorello",
    platforms: [.macOS(.v26)],
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
        .target(name: "MacPlatform", dependencies: ["DictationCore"], swiftSettings: strict),
        .target(
            name: "SorelloApp",
            dependencies: ["DictationCore", "TextRules", "DictionaryKit", "DesignCore", "SpeechEngine", "Persistence",
                           "SorelloUI", "MacPlatform"],
            swiftSettings: mainActor
        ),
        .executableTarget(name: "Sorello", dependencies: ["SorelloApp"], swiftSettings: mainActor),
        .executableTarget(name: "SorelloSnapshots", dependencies: ["SorelloUI"], swiftSettings: mainActor),
        .executableTarget(name: "SorelloTranscribe", dependencies: ["SpeechEngine", "DictionaryKit", "DictationCore"],
                          swiftSettings: strict),

        // Tests.
        .target(name: "TestSupport", path: "Tests/TestSupport"),
        .testTarget(name: "DictationCoreTests", dependencies: ["DictationCore", "TestSupport"]),
        .testTarget(name: "TextRulesTests", dependencies: ["TextRules", "TestSupport"]),
        .testTarget(name: "DictionaryKitTests", dependencies: ["DictionaryKit", "TestSupport"]),
        .testTarget(name: "DesignCoreTests", dependencies: ["DesignCore", "TestSupport"]),
        .testTarget(name: "SpeechEngineTests", dependencies: ["SpeechEngine", "DictionaryKit", "DictationCore", "TestSupport"]),
        .testTarget(name: "PersistenceTests", dependencies: ["Persistence", "DictationCore", "TextRules", "TestSupport"]),
        .testTarget(name: "MacPlatformTests", dependencies: ["MacPlatform", "DictationCore", "TestSupport"]),
        .testTarget(name: "SorelloUITests", dependencies: ["SorelloUI", "DesignCore", "TestSupport"]),
        .testTarget(name: "SorelloAppTests", dependencies: ["SorelloApp", "TestSupport"]),
    ],
    swiftLanguageModes: [.v6]
)
