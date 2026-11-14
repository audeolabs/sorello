// swift-tools-version: 6.2
import PackageDescription

// Every module, tests included, is Swift 6 and warning-free. ARCHITECTURE.md, section 2, says what each one holds and may import.
let strict: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
    .treatAllWarnings(as: .error),
]
// The UI and the composition root run on the main actor unless they say otherwise.
let mainActor: [SwiftSetting] = strict + [.defaultIsolation(MainActor.self)]

let package = Package(
    name: "Sorello",
    // iOS is here for the iPhone app, which links the two libraries below (ARCHITECTURE.md, section 13).
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .executable(name: "Sorello", targets: ["Sorello"]),
        .executable(name: "SorelloSnapshots", targets: ["SorelloSnapshots"]),
        .executable(name: "sorello-transcribe", targets: ["SorelloTranscribe"]),
        // The `sorello` command, which every app carries as Contents/Helpers/sorello (ARCHITECTURE.md, section 10).
        .executable(name: "sorello-command", targets: ["SorelloCommandMain"]),
        // What the iPhone app links, built for iOS by iOS/Makefile: the app takes the first, its keyboard the second.
        .library(name: "SorelloSpeech", type: .static,
                 targets: ["SpeechEngine", "DictionaryKit", "TextRules", "DictationCore"]),
        .library(name: "SorelloText", type: .static, targets: ["TextRules"]),
    ],
    // Sorello's one dependency: Sparkle updates the app (ARCHITECTURE.md, section 6, "Updates"). One exact version, so
    // what is signed and shipped is what was reviewed.
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
    ],
    targets: [
        // Neutral modules: nothing here imports a macOS-only framework.
        .target(name: "DictationCore", swiftSettings: strict),
        .target(name: "TextRules", swiftSettings: strict),
        .target(name: "DictionaryKit", swiftSettings: strict),
        .target(name: "DesignCore", swiftSettings: strict),
        .target(name: "SpeechEngine", dependencies: ["DictationCore", "DictionaryKit"], swiftSettings: strict),
        .target(name: "Persistence", dependencies: ["DictationCore", "TextRules"], swiftSettings: strict),
        .target(name: "FileTranscription", dependencies: ["SpeechEngine", "TextRules", "DictationCore"],
                swiftSettings: strict),

        // macOS.
        .target(name: "SorelloUI", dependencies: ["DesignCore"], swiftSettings: mainActor),
        .target(name: "MacPlatform", dependencies: ["DictationCore", "DictionaryKit"], swiftSettings: strict),
        .target(
            name: "SorelloApp",
            dependencies: ["DictationCore", "TextRules", "DictionaryKit", "DesignCore", "SpeechEngine", "Persistence",
                           "FileTranscription", "SorelloUI", "MacPlatform",
                           .product(name: "Sparkle", package: "Sparkle")],
            swiftSettings: mainActor
        ),
        .executableTarget(name: "Sorello", dependencies: ["SorelloApp"], swiftSettings: mainActor),
        .executableTarget(name: "SorelloSnapshots", dependencies: ["SorelloUI"], swiftSettings: mainActor),
        .executableTarget(name: "SorelloTranscribe", dependencies: ["SpeechEngine", "DictionaryKit", "DictationCore"],
                          swiftSettings: strict),
        .target(name: "SorelloCommand",
                dependencies: ["FileTranscription", "SpeechEngine", "Persistence", "DictionaryKit", "TextRules",
                               "DictationCore"],
                swiftSettings: strict),
        .executableTarget(name: "SorelloCommandMain", dependencies: ["SorelloCommand"], swiftSettings: strict),

        // Tests.
        .target(name: "TestSupport", path: "Tests/TestSupport", swiftSettings: strict),
        .testTarget(name: "DictationCoreTests", dependencies: ["DictationCore", "TestSupport"], swiftSettings: strict),
        .testTarget(name: "TextRulesTests", dependencies: ["TextRules", "TestSupport"], swiftSettings: strict),
        .testTarget(name: "DictionaryKitTests", dependencies: ["DictionaryKit", "TestSupport"], swiftSettings: strict),
        .testTarget(name: "DesignCoreTests", dependencies: ["DesignCore", "TestSupport"], swiftSettings: strict),
        .testTarget(name: "SpeechEngineTests", dependencies: ["SpeechEngine", "DictionaryKit", "DictationCore", "TestSupport"], swiftSettings: strict),
        .testTarget(name: "PersistenceTests", dependencies: ["Persistence", "DictationCore", "TextRules", "TestSupport"], swiftSettings: strict),
        .testTarget(name: "FileTranscriptionTests",
                    dependencies: ["FileTranscription", "SpeechEngine", "TextRules", "DictationCore", "TestSupport"],
                    swiftSettings: strict),
        .testTarget(name: "SorelloCommandTests",
                    dependencies: ["SorelloCommand", "FileTranscription", "SpeechEngine", "Persistence", "DictionaryKit",
                                   "TextRules", "DictationCore", "TestSupport"],
                    swiftSettings: strict),
        .testTarget(name: "MacPlatformTests", dependencies: ["MacPlatform", "DictationCore", "DictionaryKit", "TestSupport"], swiftSettings: strict),
        .testTarget(name: "SorelloUITests", dependencies: ["SorelloUI", "DesignCore", "TestSupport"], swiftSettings: strict),
        .testTarget(name: "SorelloAppTests",
                    dependencies: ["SorelloApp", "DictationCore", "TextRules", "DictionaryKit", "DesignCore",
                                   "SpeechEngine", "Persistence", "FileTranscription", "SorelloUI", "MacPlatform",
                                   "TestSupport"],
                    swiftSettings: strict),
    ],
    swiftLanguageModes: [.v6]
)
