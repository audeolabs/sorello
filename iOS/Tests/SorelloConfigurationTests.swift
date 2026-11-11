import Foundation

enum SorelloConfigurationTests {
    static var tests: [TestCase] {
        [
            ("readsBothIdentifiers", testReadsBothIdentifiers),
            ("rejectsMissingOrUnexpandedValues", testRejectsMissingOrUnexpandedValues),
            ("rejectsInvalidScheme", testRejectsInvalidScheme),
            ("buildsDictateURL", testBuildsDictateURL),
            ("readsUniversalLink", testReadsUniversalLink),
            ("rejectsInvalidUniversalLink", testRejectsInvalidUniversalLink),
            ("prefersUniversalLinkForDictateURL", testPrefersUniversalLinkForDictateURL),
        ]
    }

    private static var validInfo: [String: Any] {
        ["LocalFlowAppGroupIdentifier": "group.example.synthetic", "LocalFlowURLScheme": "synthetic-flow"]
    }

    private static let link = "https://links.example/synthetic-flow/dictate"

    private static func testReadsBothIdentifiers() {
        TestSupport.expectEqual(
            SorelloConfiguration(infoDictionary: validInfo),
            SorelloConfiguration(appGroupIdentifier: "group.example.synthetic", urlScheme: "synthetic-flow"))
        TestSupport.expectEqual(SorelloConfiguration(infoDictionary: validInfo)?.universalLink, nil)
    }

    private static func testRejectsMissingOrUnexpandedValues() {
        TestSupport.expectEqual(SorelloConfiguration(infoDictionary: nil), nil)
        TestSupport.expectEqual(SorelloConfiguration(infoDictionary: [:]), nil)
        for key in validInfo.keys {
            var info = validInfo
            info[key] = nil
            TestSupport.expectEqual(SorelloConfiguration(infoDictionary: info), nil)
            info[key] = ""
            TestSupport.expectEqual(SorelloConfiguration(infoDictionary: info), nil)
            info[key] = 42
            TestSupport.expectEqual(SorelloConfiguration(infoDictionary: info), nil)
        }
        var info = validInfo
        info["LocalFlowAppGroupIdentifier"] = "$(APP_GROUP)"
        TestSupport.expectEqual(SorelloConfiguration(infoDictionary: info), nil)
        info["LocalFlowAppGroupIdentifier"] = "group.example synthetic"
        TestSupport.expectEqual(SorelloConfiguration(infoDictionary: info), nil)
    }

    private static func testRejectsInvalidScheme() {
        for scheme in ["$(URL_SCHEME)", "1flow", "synthetic flow", "synthetic://", "flów", "-flow"] {
            var info = validInfo
            info["LocalFlowURLScheme"] = scheme
            TestSupport.expect(SorelloConfiguration(infoDictionary: info) == nil, "accepted scheme \(scheme)")
        }
        var info = validInfo
        info["LocalFlowURLScheme"] = "Synthetic+flow.v2-dev"
        TestSupport.expect(SorelloConfiguration(infoDictionary: info) != nil, "rejected a valid scheme")
    }

    private static func testBuildsDictateURL() {
        let configuration = SorelloConfiguration(infoDictionary: validInfo)!
        TestSupport.expectEqual(configuration.dictateURL?.absoluteString, "synthetic-flow://dictate")
    }

    private static func testReadsUniversalLink() {
        var info = validInfo
        info["LocalFlowUniversalLink"] = link
        TestSupport.expectEqual(
            SorelloConfiguration(infoDictionary: info),
            SorelloConfiguration(appGroupIdentifier: "group.example.synthetic", urlScheme: "synthetic-flow",
                                   universalLink: URL(string: link)!))
        for valid in ["https://links.example/d", "HTTPS://Links.Example/Flow/Dictate", "https://a.links.example/x/y/z/"] {
            info["LocalFlowUniversalLink"] = valid
            TestSupport.expectEqual(SorelloConfiguration(infoDictionary: info)?.universalLink?.absoluteString, valid)
        }
    }

    /// A present but invalid link fails the whole configuration closed, never falling back to the scheme.
    private static func testRejectsInvalidUniversalLink() {
        let invalid: [Any] = [
            "", " ", 42, ["https://links.example/dictate"], "$(UNIVERSAL_LINK)",
            "https://links.example/$(PATH)", "https://$(HOST)/dictate",
            "http://links.example/dictate", "synthetic-flow://dictate", "ftp://links.example/dictate",
            "links.example/dictate", "/synthetic-flow/dictate", "https:links.example/dictate",
            "https://links.example", "https://links.example/", "https:///dictate",
            "https://user@links.example/dictate", "https://user:pw@links.example/dictate",
            "https://links.example:443/dictate", "https://links.example:8443/dictate",
            "https://links.example/dictate?", "https://links.example/dictate?start=1",
            "https://links.example/dictate#", "https://links.example/dictate#start",
            "https://links example/dictate", "https://links.example/dic tate", " https://links.example/dictate",
            "https://links.example/dictate\n",
        ]
        for value in invalid {
            var info = validInfo
            info["LocalFlowUniversalLink"] = value
            TestSupport.expect(SorelloConfiguration(infoDictionary: info) == nil, "accepted universal link \(value)")
        }
    }

    private static func testPrefersUniversalLinkForDictateURL() {
        var info = validInfo
        info["LocalFlowUniversalLink"] = link
        let configuration = SorelloConfiguration(infoDictionary: info)!
        TestSupport.expectEqual(configuration.dictateURL?.absoluteString, link)
        TestSupport.expectEqual(configuration.urlScheme, "synthetic-flow")
        TestSupport.expectEqual(
            SorelloConfiguration(appGroupIdentifier: "group.example.synthetic", urlScheme: "synthetic-flow")
                .dictateURL?.absoluteString,
            "synthetic-flow://dictate")
    }
}
