import Foundation
import Testing
@testable import SpeechEngine

/// How a bundle says its encoder's 15 s function is reached (ARCHITECTURE.md, section 5): by the name "b15" unless
/// its manifest says the encoder has one function, which is then loaded without a name. The manifests are invented.
struct EncoderLayoutTests {
    private func layout(_ json: String) throws -> EncoderLayout {
        let manifest = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        return EncoderLayout(manifest: manifest)
    }

    @Test("A manifest that says nothing names the function for its window, as every build before this did")
    func aSilentManifestNamesTheFunction() throws {
        let layout = try layout(#"{"buckets_seconds": [15]}"#)
        #expect(layout == .named)
        #expect(layout.functionName(seconds: 15) == "b15")
        #expect(layout.functionName(seconds: 30) == "b30")
    }

    @Test func aManifestMaySayItsEncoderHasSeveralFunctions() throws {
        #expect(try layout(#"{"multifunction": true}"#) == .named)
    }

    @Test("A build for a system that cannot name a function says so, and its one function is loaded without a name")
    func aSingleFunctionEncoderHasNoName() throws {
        let layout = try layout(#"{"multifunction": false, "encoder_opset": "iOS16", "buckets_seconds": [15]}"#)
        #expect(layout == .single)
        #expect(layout.functionName(seconds: 15) == nil)
    }

    @Test("Only the value false means one function")
    func anythingElseNamesTheFunction() throws {
        #expect(try layout(#"{"multifunction": "false"}"#) == .named)
        #expect(try layout(#"{"multifunction": null}"#) == .named)
    }
}
