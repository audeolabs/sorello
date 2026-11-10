import AppKit
import Foundation
import Testing
@testable import SorelloUI

/// A scene is a fixed picture: the scenes whose views animate with the clock (the Run Log's retry line, the preparing
/// dot) render the same at any moment.
@MainActor
struct SnapshotStillnessTests {
    @Test(arguments: ["main-runlog", "main-general-preparing", "setup-test-preparing"])
    func aSceneRendersTheSameAtAnyMoment(name: String) async throws {
        let scene = try #require(SnapshotCatalog.all.first { $0.name == name })
        let first = try #require(SnapshotRenderer.png(of: scene, scale: 1))
        // Less than either animation's period, and not a multiple of it.
        try await Task.sleep(for: .milliseconds(370))
        let second = try #require(SnapshotRenderer.png(of: scene, scale: 1))
        #expect(first == second)
    }
}
