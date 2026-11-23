// swift-tools-version: 6.2
import PackageDescription

// The build for older Macs (ARCHITECTURE.md, section 15): SORELLO_LEGACY=1 lowers the Mac's minimum system to
// macOS 13 and defines SORELLO_LEGACY, under which the code takes what those systems lack from SystemCompat's
// stand-ins. Without it the package is the usual one, and nothing below differs.
let legacy = Context.environment["SORELLO_LEGACY"] == "1"

// Every module, tests included, is Swift 6 and warning-free. ARCHITECTURE.md, section 2, says what each one holds and may import.
let strict: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
    .treatAllWarnings(as: .error),
] + (legacy ? [.define("SORELLO_LEGACY")] : [])
// The UI and the composition root run on the main actor unless they say otherwise.
let mainActor: [SwiftSetting] = strict + [.defaultIsolation(MainActor.self)]
// An executable records the SDK it was linked against, and AppKit and SwiftUI give it that SDK's behaviour. SwiftPM's
// link records the minimum system instead unless clang is told the SDK, which `swift` passes in SDKROOT
// (swiftlang/swift-package-manager#10696). The build for older Macs would otherwise record the macOS 13 SDK.
let linkedSDK: [LinkerSetting] = legacy ? (Context.environment["SDKROOT"].map {
    [.unsafeFlags(["-Xclang-linker", "-isysroot", "-Xclang-linker", $0])]
} ?? []) : []

// Sorello's own encoder for an Intel Mac, a C module only the build for older Macs has (ARCHITECTURE.md, section 15,
// "The encoder on an Intel Mac"). It is optimized in every configuration: unoptimized, one chunk takes minutes, which
// the tests that run it with the model cannot wait for.
let nativeEncoder: [Target] = legacy ? [.target(name: "NativeEncoder", cSettings: [.unsafeFlags(["-O3"])])] : []
let speechEngineDependencies: [Target.Dependency] = ["DictationCore", "DictionaryKit", "SystemCompat"]
    + (legacy ? ["NativeEncoder"] : [])

let package = Package(
    name: "Sorello",
    // iOS is here for the iPhone app, which links the two libraries below (ARCHITECTURE.md, section 13).
    platforms: [.macOS(legacy ? .v13 : .v26), .iOS(.v26)],
    products: [
        .executable(name: "Sorello", targets: ["Sorello"]),
        .executable(name: "SorelloSnapshots", targets: ["SorelloSnapshots"]),
        .executable(name: "sorello-transcribe", targets: ["SorelloTranscribe"]),
        // The `sorello` command, which every app carries as Contents/Helpers/sorello (ARCHITECTURE.md, section 10).
        .executable(name: "sorello-command", targets: ["SorelloCommandMain"]),
        // What the iPhone app links, built for iOS by iOS/Makefile: the app takes the first, its keyboard the second.
        .library(name: "SorelloSpeech", type: .static,
                 targets: ["SpeechEngine", "DictionaryKit", "TextRules", "DictationCore"]),
        .library(name: "SorelloText", type: .static, targets: ["TextRules", "DictionaryKit"]),
    ],
    // Sorello's one dependency: Sparkle updates the app (ARCHITECTURE.md, section 6, "Updates"). One exact version, so
    // what is signed and shipped is what was reviewed.
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
    ],
    targets: [
        // Neutral modules: nothing here imports a macOS-only framework.
        .target(name: "DictationCore", dependencies: ["SystemCompat"], swiftSettings: strict),
        .target(name: "TextRules", swiftSettings: strict),
        // Apple's lock and actor queue, or their stand-ins in the build for older Macs. Imports only Foundation.
        .target(name: "SystemCompat", swiftSettings: strict),
        .target(name: "DictionaryKit", dependencies: ["SystemCompat"], swiftSettings: strict),
        .target(name: "DesignCore", swiftSettings: strict),
        // Screen notes' rules, pure but for the Mac app only (ARCHITECTURE.md, section 14).
        .target(name: "ScreenNotes", swiftSettings: strict),
        .target(name: "SpeechEngine", dependencies: speechEngineDependencies, swiftSettings: strict),
        .target(name: "Persistence", dependencies: ["DictationCore", "TextRules", "SystemCompat"], swiftSettings: strict),
        .target(name: "FileTranscription", dependencies: ["SpeechEngine", "TextRules", "DictationCore"],
                swiftSettings: strict),

    ] + nativeEncoder + [
        // macOS.
        // AppKit's display link, or its stand-in in the build for older Macs.
        .target(name: "MacCompat", swiftSettings: strict),
        .target(name: "SorelloUI", dependencies: ["DesignCore", "SystemCompat", "MacCompat"], swiftSettings: mainActor),
        .target(name: "MacPlatform",
                dependencies: ["DictationCore", "DictionaryKit", "DesignCore", "ScreenNotes", "SystemCompat",
                               "MacCompat"],
                swiftSettings: strict),
        .target(
            name: "SorelloApp",
            dependencies: ["DictationCore", "TextRules", "DictionaryKit", "DesignCore", "SpeechEngine", "Persistence",
                           "FileTranscription", "SorelloUI", "MacPlatform", "ScreenNotes", "SystemCompat",
                           "MacCompat", .product(name: "Sparkle", package: "Sparkle")],
            swiftSettings: mainActor
        ),
        .executableTarget(name: "Sorello", dependencies: ["SorelloApp"], swiftSettings: mainActor,
                          linkerSettings: linkedSDK),
        .executableTarget(name: "SorelloSnapshots", dependencies: ["SorelloUI"], swiftSettings: mainActor,
                          linkerSettings: linkedSDK),
        .executableTarget(name: "SorelloTranscribe", dependencies: ["SpeechEngine", "DictionaryKit", "DictationCore"],
                          swiftSettings: strict, linkerSettings: linkedSDK),
        .target(name: "SorelloCommand",
                dependencies: ["FileTranscription", "SpeechEngine", "Persistence", "DictionaryKit", "TextRules",
                               "DictationCore", "SystemCompat"],
                swiftSettings: strict),
        .executableTarget(name: "SorelloCommandMain", dependencies: ["SorelloCommand"], swiftSettings: strict,
                          linkerSettings: linkedSDK),

        // Tests.
        .target(name: "TestSupport", path: "Tests/TestSupport", swiftSettings: strict),
        .testTarget(name: "SystemCompatTests", dependencies: ["SystemCompat"], swiftSettings: strict),
        .testTarget(name: "MacCompatTests", dependencies: ["MacCompat"], swiftSettings: strict),
        .testTarget(name: "DictationCoreTests", dependencies: ["DictationCore", "SystemCompat", "TestSupport"], swiftSettings: strict),
        .testTarget(name: "TextRulesTests", dependencies: ["TextRules", "TestSupport"], swiftSettings: strict),
        .testTarget(name: "DictionaryKitTests", dependencies: ["DictionaryKit", "SystemCompat", "TestSupport"], swiftSettings: strict),
        .testTarget(name: "DesignCoreTests", dependencies: ["DesignCore", "TestSupport"], swiftSettings: strict),
        .testTarget(name: "ScreenNotesTests", dependencies: ["ScreenNotes"], swiftSettings: strict),
        .testTarget(name: "SpeechEngineTests", dependencies: ["SpeechEngine", "DictionaryKit", "DictationCore", "SystemCompat", "TestSupport"],
                    resources: [.copy("Fixtures")], swiftSettings: strict),
        .testTarget(name: "PersistenceTests", dependencies: ["Persistence", "DictationCore", "TextRules", "SystemCompat", "TestSupport"], swiftSettings: strict),
        .testTarget(name: "FileTranscriptionTests",
                    dependencies: ["FileTranscription", "SpeechEngine", "TextRules", "DictationCore", "SystemCompat", "TestSupport"],
                    swiftSettings: strict),
        .testTarget(name: "SorelloCommandTests",
                    dependencies: ["SorelloCommand", "FileTranscription", "SpeechEngine", "Persistence", "DictionaryKit",
                                   "TextRules", "DictationCore", "SystemCompat", "TestSupport"],
                    swiftSettings: strict),
        .testTarget(name: "MacPlatformTests", dependencies: ["MacPlatform", "DictationCore", "DictionaryKit", "SystemCompat", "TestSupport"], swiftSettings: strict),
        .testTarget(name: "SorelloUITests", dependencies: ["SorelloUI", "DesignCore", "TestSupport"], swiftSettings: strict),
        .testTarget(name: "SorelloAppTests",
                    dependencies: ["SorelloApp", "DictationCore", "TextRules", "DictionaryKit", "DesignCore",
                                   "SpeechEngine", "Persistence", "FileTranscription", "SorelloUI", "MacPlatform",
                                   "ScreenNotes", "SystemCompat", "TestSupport"],
                    swiftSettings: strict),
    ],
    swiftLanguageModes: [.v6]
)
