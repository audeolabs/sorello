import Foundation
import JavaScriptCore

/// Which input the keyboard's capture pages ask WebKit for (ARCHITECTURE.md, "In-keyboard dictation (experiment)",
/// Capture). Each page's own script runs in JavaScriptCore against a stand-in for `getUserMedia`, `enumerateDevices`,
/// Web Audio and the message handler, so the tests see the requests the page makes and the track it records from.
enum CapturePageMicrophoneTests {
    static var tests: [TestCase] {
        [
            ("pageFollowsTheChoice", testPageFollowsTheChoice),
            ("systemPageTakesTheInputIOSChooses", testSystemPageTakesTheInputIOSChooses),
            ("builtInPageSwitchesFromHeadphonesToTheIPhone", testBuiltInPageSwitchesFromHeadphonesToTheIPhone),
            ("builtInPageKeepsTheIPhoneWhenIOSChoseIt", testBuiltInPageKeepsTheIPhoneWhenIOSChoseIt),
            ("builtInPageWaitsForWebKitToRenameTheTrack", testBuiltInPageWaitsForWebKitToRenameTheTrack),
            ("builtInPageRecordsWhatItHasWithoutOneIPhoneInput", testBuiltInPageRecordsWhatItHasWithoutOneIPhoneInput),
            ("builtInPageAsksAgainWhenTheIPhoneIsRefused", testBuiltInPageAsksAgainWhenTheIPhoneIsRefused),
            ("builtInPageFailsWhenEveryRequestIsRefused", testBuiltInPageFailsWhenEveryRequestIsRefused),
            ("stopWhileChoosingRecordsNothing", testStopWhileChoosingRecordsNothing),
            ("stopWhileTheNameSettlesRecordsNothing", testStopWhileTheNameSettlesRecordsNothing),
            ("builtInPageReachesNothingOutsideIt", testBuiltInPageReachesNothingOutsideIt),
        ]
    }

    private static let iPhone = Device(id: "built-in", label: "iPhone Microphone")
    private static let headset = Device(id: "headset", label: "Headset Microphone")
    private static let usb = Device(id: "usb", label: "USB-C Headphones")
    private static let airPods = Device(id: "bluetooth", label: "Example AirPods")

    private static func testPageFollowsTheChoice() {
        TestSupport.expectEqual(CapturePage.page(useBuiltInMicrophone: true), CapturePage.builtInMicrophoneHTML)
        TestSupport.expectEqual(CapturePage.page(useBuiltInMicrophone: false), CapturePage.html)
        TestSupport.expect(CapturePage.html != CapturePage.builtInMicrophoneHTML, "the two pages are the same")
    }

    private static func testSystemPageTakesTheInputIOSChooses() {
        let run = Run(page: CapturePage.html, devices: [iPhone, headset], systemChoice: headset)
        TestSupport.expectEqual(run.requestedDevices, [nil])
        TestSupport.expectEqual(run.recordingFrom, headset.label)
        TestSupport.expect(run.audioPosted, "the page posts no audio")
    }

    private static func testBuiltInPageSwitchesFromHeadphonesToTheIPhone() {
        for headphones in [headset, usb, airPods] {
            let run = Run(page: CapturePage.builtInMicrophoneHTML, devices: [headphones, iPhone], systemChoice: headphones)
            TestSupport.expectEqual(run.requestedDevices, [nil, iPhone.id])
            TestSupport.expectEqual(run.recordingFrom, iPhone.label)
            TestSupport.expectEqual(run.liveTracks, [iPhone.label])
            TestSupport.expect(run.audioPosted, "the page posts no audio after switching")
            TestSupport.expect(!run.postedText.contains(headphones.label) && !run.postedText.contains(iPhone.label),
                               "the page posted a device's label")
        }
        // Another language's label still names the iPhone as a word.
        let french = Device(id: "built-in", label: "Micro de l’iPhone")
        let run = Run(page: CapturePage.builtInMicrophoneHTML, devices: [headset, french], systemChoice: headset)
        TestSupport.expectEqual(run.recordingFrom, french.label)
        let iPad = Device(id: "built-in", label: "iPad Microphone")
        TestSupport.expectEqual(Run(page: CapturePage.builtInMicrophoneHTML, devices: [usb, iPad], systemChoice: usb).recordingFrom,
                                iPad.label)
    }

    private static func testBuiltInPageKeepsTheIPhoneWhenIOSChoseIt() {
        // Only the iPhone listed: nothing else could be recording, so it records at once.
        let alone = Run(page: CapturePage.builtInMicrophoneHTML, devices: [iPhone], systemChoice: iPhone)
        TestSupport.expectEqual(alone.requestedDevices, [nil])
        TestSupport.expectEqual(alone.recordingFrom, iPhone.label)
        TestSupport.expectEqual(alone.recordingStartedAt, 0)
        // Headphones listed too: the name is watched for 1.5 s, and still naming the iPhone, it records that track.
        let run = Run(page: CapturePage.builtInMicrophoneHTML, devices: [iPhone, headset], systemChoice: iPhone)
        TestSupport.expectEqual(run.requestedDevices, [nil])
        TestSupport.expectEqual(run.recordingFrom, iPhone.label)
        TestSupport.expect((1500 ... 1600).contains(run.recordingStartedAt ?? -1),
                           "recording started at \(run.recordingStartedAt.map(String.init) ?? "never") ms, not at the 1.5 s limit")
        TestSupport.expect(run.audioPosted, "the page posts no audio after the limit")
    }

    /// Seen on an iPhone with Bluetooth headphones: WebKit named the first track "iPhone Microphone" while iOS routed
    /// the headphones' microphone, and renamed it about 0.3 s after the grant.
    private static func testBuiltInPageWaitsForWebKitToRenameTheTrack() {
        for headphones in [airPods, headset] {
            let run = Run(page: CapturePage.builtInMicrophoneHTML, devices: [iPhone, headphones], systemChoice: iPhone,
                          renamed: (to: headphones.label, atMilliseconds: 300))
            TestSupport.expectEqual(run.requestedDevices, [nil, iPhone.id])
            TestSupport.expectEqual(run.recordingFrom, iPhone.label)
            TestSupport.expectEqual(run.liveTracks, [iPhone.label])
            TestSupport.expect((300 ... 400).contains(run.recordingStartedAt ?? -1),
                               "recording started at \(run.recordingStartedAt.map(String.init) ?? "never") ms, not just after the rename")
            TestSupport.expect(!run.postedText.contains(headphones.label), "the page posted a device's label")
        }
        // A rename after the limit is not waited for.
        let late = Run(page: CapturePage.builtInMicrophoneHTML, devices: [iPhone, airPods], systemChoice: iPhone,
                       renamed: (to: airPods.label, atMilliseconds: 2500))
        TestSupport.expectEqual(late.requestedDevices, [nil])
    }

    private static func testBuiltInPageRecordsWhatItHasWithoutOneIPhoneInput() {
        let none = Run(page: CapturePage.builtInMicrophoneHTML, devices: [usb], systemChoice: usb)
        TestSupport.expectEqual(none.requestedDevices, [nil])
        TestSupport.expectEqual(none.recordingFrom, usb.label)
        // Two inputs that name the iPhone: not knowing which, the page does not guess.
        let other = Device(id: "other", label: "iPhone Lavalier")
        let two = Run(page: CapturePage.builtInMicrophoneHTML, devices: [usb, iPhone, other], systemChoice: usb)
        TestSupport.expectEqual(two.requestedDevices, [nil])
        TestSupport.expectEqual(two.recordingFrom, usb.label)
        // A label that only contains the word does not name it.
        let lookalike = Device(id: "lookalike", label: "iPhoneDock Mic")
        TestSupport.expectEqual(Run(page: CapturePage.builtInMicrophoneHTML, devices: [usb, lookalike], systemChoice: usb)
            .requestedDevices, [nil])
    }

    private static func testBuiltInPageAsksAgainWhenTheIPhoneIsRefused() {
        let run = Run(page: CapturePage.builtInMicrophoneHTML, devices: [headset, iPhone], systemChoice: headset,
                      refused: [iPhone.id])
        TestSupport.expectEqual(run.requestedDevices, [nil, iPhone.id, nil])
        TestSupport.expectEqual(run.recordingFrom, headset.label)
        TestSupport.expectEqual(run.liveTracks, [headset.label])
        TestSupport.expect(!run.failed, "the page failed though the last request was granted")
    }

    private static func testBuiltInPageFailsWhenEveryRequestIsRefused() {
        let run = Run(page: CapturePage.builtInMicrophoneHTML, devices: [headset, iPhone], systemChoice: headset,
                      refused: [iPhone.id], refuseSystemAfterFirst: true)
        TestSupport.expectEqual(run.requestedDevices, [nil, iPhone.id, nil])
        TestSupport.expect(run.failed, "the page did not report the failure")
        TestSupport.expectEqual(run.liveTracks, [])
        TestSupport.expectEqual(run.recordingFrom, nil)
    }

    private static func testStopWhileChoosingRecordsNothing() {
        // Stopped while the inputs are listed: the first track stops and nothing more is asked for.
        let listing = Run(page: CapturePage.builtInMicrophoneHTML, devices: [headset, iPhone], systemChoice: headset,
                          stopAfterFirstGrant: true)
        TestSupport.expectEqual(listing.requestedDevices, [nil])
        TestSupport.expectEqual(listing.liveTracks, [])
        TestSupport.expectEqual(listing.recordingFrom, nil)
        TestSupport.expect(!listing.failed && !listing.audioPosted, "a stopped page posted")
    }

    private static func testStopWhileTheNameSettlesRecordsNothing() {
        let run = Run(page: CapturePage.builtInMicrophoneHTML, devices: [iPhone, airPods], systemChoice: iPhone,
                      renamed: (to: airPods.label, atMilliseconds: 600), stopAtMilliseconds: 300)
        TestSupport.expectEqual(run.requestedDevices, [nil])
        TestSupport.expectEqual(run.liveTracks, [])
        TestSupport.expectEqual(run.recordingFrom, nil)
        TestSupport.expect(!run.failed && !run.audioPosted, "a stopped page posted")
    }

    /// The same checks as `CapturePage.html`'s (`KeyboardDictationAudioTests`), and its posts carry only fixed kinds.
    private static func testBuiltInPageReachesNothingOutsideIt() {
        let page = CapturePage.builtInMicrophoneHTML.lowercased()
        let forbidden = [
            "fetch", "xmlhttprequest", "xhr", "websocket", "rtcpeerconnection", "rtcdatachannel", "eventsource", "beacon",
            "localstorage", "sessionstorage", "indexeddb", "caches", "cookie", "storage", "frame", "window", "open(",
            "worker", "import", "eval", "function(\"", "settimeout(\"", "://", "src=", "href", "url(", "<link", "<img",
            "<iframe", "<object", "<embed", "<form", "location", "history", "document.write", "navigator.sendbeacon",
            "postmessage(message, ", "parent", "opener", "srcdoc", "blob:", "data:",
        ]
        for name in forbidden {
            TestSupport.expect(!page.contains(name), "the built-in microphone page names \(name)")
        }
        TestSupport.expect(page.contains(#"content="default-src 'none'; script-src 'unsafe-inline'""#),
                           "the built-in microphone page's policy is not default-src 'none' with an inline script")
        TestSupport.expectEqual(page.components(separatedBy: "messagehandlers.").count, 2)
        TestSupport.expectEqual(page.components(separatedBy: "<script").count, 2)
        for constraint in ["echocancellation: false", "noisesuppression: false", "autogaincontrol: false", "channelcount: 1",
                           "video: false"] {
            TestSupport.expect(page.contains(constraint), "the built-in microphone page does not ask for \(constraint)")
        }
        // Every post is an object literal of a fixed kind: nothing read from a device can be posted.
        let posts = page.components(separatedBy: "sorellopost(").dropFirst()
        for post in posts where !post.hasPrefix("message)") {
            TestSupport.expect(post.hasPrefix("{ kind: \"audio\"") || post.hasPrefix("{ kind: \"ended\" }")
                || post.hasPrefix("{ kind: \"failed\" }"), "the page posts something other than its fixed kinds")
        }
    }

    // MARK: Running a page

    struct Device {
        var id: String
        var label: String
    }

    /// One page's script, run to rest against the stand-ins, with one audio callback delivered to what it records.
    private struct Run {
        var requestedDevices: [String?] = []
        var recordingFrom: String?
        var liveTracks: [String] = []
        var audioPosted = false
        var failed = false
        var postedText = ""
        /// Milliseconds of the harness's clock when the page made its audio context, nil if it never did.
        var recordingStartedAt: Int?

        /// `renamed`: WebKit renames the first track that long after the page starts. `stopAtMilliseconds`: Swift
        /// stops the page then.
        init(page: String, devices: [Device], systemChoice: Device, refused: Set<String> = [],
             refuseSystemAfterFirst: Bool = false, stopAfterFirstGrant: Bool = false,
             renamed: (to: String, atMilliseconds: Int)? = nil, stopAtMilliseconds: Int? = nil) {
            guard let context = JSContext() else {
                TestSupport.expect(false, "JavaScriptCore made no context")
                return
            }
            var exception: String?
            context.exceptionHandler = { _, value in exception = value?.toString() }
            let config: [String: Any] = [
                "devices": devices.map { ["kind": "audioinput", "deviceId": $0.id, "label": $0.label] },
                "systemLabel": systemChoice.label,
                "refused": Array(refused),
                "refuseSystemAfterFirst": refuseSystemAfterFirst,
                "stopAfterFirstGrant": stopAfterFirstGrant,
                "renameTo": renamed?.to ?? NSNull(),
                "renameAt": renamed?.atMilliseconds ?? NSNull(),
                "stopAt": stopAtMilliseconds ?? NSNull(),
            ]
            context.setObject(config, forKeyedSubscript: "harnessConfig" as NSString)
            context.evaluateScript(Self.standIns)
            context.evaluateScript(Self.script(of: page))
            // Promise jobs run as each evaluation ends. Each tick moves the clock 10 ms; 3 s settles every chain.
            for _ in 0 ..< 300 { context.evaluateScript("harnessTick();") }
            context.evaluateScript("harnessDeliverAudio();")
            if let exception { TestSupport.expect(false, "the page threw: \(exception)") }
            let result = context.evaluateScript("JSON.stringify(harnessResult())")?.toString() ?? "{}"
            guard let data = result.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                TestSupport.expect(false, "the harness gave no result")
                return
            }
            requestedDevices = (object["requests"] as? [Any] ?? []).map { $0 as? String }
            recordingFrom = object["recordingFrom"] as? String
            liveTracks = object["liveTracks"] as? [String] ?? []
            let posts = object["posts"] as? [[String: Any]] ?? []
            audioPosted = posts.contains { $0["kind"] as? String == "audio" }
            failed = posts.contains { $0["kind"] as? String == "failed" }
            postedText = object["postedText"] as? String ?? ""
            recordingStartedAt = object["startedAt"] as? Int
        }

        private static func script(of page: String) -> String {
            guard let start = page.range(of: "<script>"), let end = page.range(of: "</script>") else {
                TestSupport.expect(false, "the page has no script")
                return ""
            }
            return String(page[start.upperBound ..< end.lowerBound])
        }

        private static let standIns = #"""
        var harnessRequests = [];
        var harnessTracks = [];
        var harnessPosts = [];
        var harnessContexts = [];
        var harnessNow = 0;
        var harnessTimers = [];
        var harnessStartedAt = null;

        function setTimeout(callback, delay) {
          harnessTimers.push({ at: harnessNow + delay, callback: callback });
        }

        function harnessStream(label) {
          var track = { label: label, stopped: false, onended: null, stop: function () { this.stopped = true; } };
          harnessTracks.push(track);
          var stream = { getTracks: function () { return [track]; }, getAudioTracks: function () { return [track]; } };
          return stream;
        }

        var navigator = { mediaDevices: {
          getUserMedia: function (constraints) {
            var audio = constraints.audio || {};
            var exact = audio.deviceId && audio.deviceId.exact;
            harnessRequests.push(exact || null);
            if (exact) {
              if (harnessConfig.refused.indexOf(exact) >= 0) { return Promise.reject(new Error("refused")); }
              var device = harnessConfig.devices.filter(function (d) { return d.deviceId === exact; })[0];
              if (!device) { return Promise.reject(new Error("no such device")); }
              return Promise.resolve(harnessStream(device.label));
            }
            if (harnessConfig.refuseSystemAfterFirst && harnessRequests.length > 1) {
              return Promise.reject(new Error("refused"));
            }
            return Promise.resolve(harnessStream(harnessConfig.systemLabel));
          },
          enumerateDevices: function () {
            if (harnessConfig.stopAfterFirstGrant) { sorelloStop(); }
            return Promise.resolve(harnessConfig.devices.slice());
          }
        } };

        var webkit = { messageHandlers: { sorelloCapture: { postMessage: function (message) { harnessPosts.push(message); } } } };

        function AudioContext() {
          this.sampleRate = 48000;
          this.state = "running";
          this.destination = {};
          this.source = null;
          this.processor = null;
          this.closed = false;
          harnessContexts.push(this);
          if (harnessStartedAt === null) { harnessStartedAt = harnessNow; }
        }
        AudioContext.prototype.createMediaStreamSource = function (media) {
          this.source = { media: media, connect: function () {}, disconnect: function () {} };
          return this.source;
        };
        AudioContext.prototype.createScriptProcessor = function () {
          this.processor = { onaudioprocess: null, connect: function () {}, disconnect: function () {} };
          return this.processor;
        };
        AudioContext.prototype.resume = function () {};
        AudioContext.prototype.close = function () { this.closed = true; };

        // A browser's; JavaScriptCore has none. The encoding is `KeyboardDictationAudioTests`' concern.
        function btoa(text) { return "AAAA"; }

        function harnessTick() {
          harnessNow += 10;
          if (harnessConfig.renameAt !== null && harnessNow === harnessConfig.renameAt && harnessTracks.length > 0) {
            harnessTracks[0].label = harnessConfig.renameTo;
          }
          if (harnessConfig.stopAt !== null && harnessNow === harnessConfig.stopAt) { sorelloStop(); }
          var due = harnessTimers.filter(function (t) { return t.at <= harnessNow; });
          harnessTimers = harnessTimers.filter(function (t) { return t.at > harnessNow; });
          due.forEach(function (t) { t.callback(); });
        }

        function harnessLive() {
          return harnessContexts.filter(function (c) { return !c.closed && c.source; });
        }

        function harnessDeliverAudio() {
          harnessLive().forEach(function (c) {
            if (c.processor && c.processor.onaudioprocess) {
              var samples = new Float32Array(256);
              c.processor.onaudioprocess({ inputBuffer: { getChannelData: function () { return samples; } } });
            }
          });
        }

        function harnessResult() {
          var live = harnessLive();
          var recordingFrom = null;
          if (live.length === 1) {
            var track = live[0].source.media.getAudioTracks()[0];
            if (!track.stopped) { recordingFrom = track.label; }
          }
          return {
            requests: harnessRequests,
            recordingFrom: recordingFrom,
            liveTracks: harnessTracks.filter(function (t) { return !t.stopped; }).map(function (t) { return t.label; }),
            posts: harnessPosts.map(function (p) { return { kind: p.kind }; }),
            postedText: JSON.stringify(harnessPosts),
            startedAt: harnessStartedAt
          };
        }
        """#
    }
}
