#if SORELLO_KEYBOARD_DICTATION
import Foundation

/// The keyboard's capture pages (ARCHITECTURE.md, "In-keyboard dictation (experiment)", Capture): two fixed strings,
/// with nothing interpolated into them, loaded under an `https` origin of a reserved domain that never resolves. Their
/// policy lets nothing load; their script uses only `getUserMedia`, Web Audio and the one message handler, posting mono
/// 16-bit chunks of at most 0.25 s as base64. `html` records from the input iOS chooses; `builtInMicrophoneHTML`
/// switches to the iPhone's own microphone when iOS chose another ("Use iPhone microphone"). Host tests read this
/// source for anything that could reach outside it, and run its script.
enum CapturePage {
    /// A secure context, so the page may call `getUserMedia`; `.invalid` never resolves.
    static let baseURL = URL(string: "https://capture.sorello.invalid/")!
    static let host = "capture.sorello.invalid"
    /// The one message handler.
    static let handlerName = "sorelloCapture"
    /// What Swift runs to stop it: every track and the audio context.
    static let stopScript = "sorelloStop();"
    /// What Swift runs at the tap in a held page: it posts audio from then on.
    static let recordScript = "sorelloRecord();"

    /// The page for the shared `useBuiltInMicrophone`, read at the tap.
    static func page(useBuiltInMicrophone: Bool) -> String {
        useBuiltInMicrophone ? builtInMicrophoneHTML : html
    }

    /// Records from the input iOS chooses, Bluetooth hands-free included.
    static let html = opening + "var sorelloPreferBuiltIn = false;\nvar sorelloHeld = false;\n" + script

    /// Records from the iPhone's microphone when iOS chose another input and exactly one input's label names the iPhone
    /// or iPad as a word; otherwise as `html`. A first track named for the iPhone, with another input listed, is watched
    /// for up to 1.5 s for WebKit to rename it once the route settles. Labels are read only here and never posted.
    static let builtInMicrophoneHTML = opening + "var sorelloPreferBuiltIn = true;\nvar sorelloHeld = false;\n" + script

    /// The held microphone's page (Held microphone): chooses the input as `builtInMicrophoneHTML` does and runs Web Audio
    /// while the keyboard is up, but posts no audio until `recordScript`.
    static let heldMicrophoneHTML = opening + "var sorelloPreferBuiltIn = true;\nvar sorelloHeld = true;\n" + script

    private static let opening = #"""
    <!doctype html>
    <html>
    <head>
    <meta charset="utf-8">
    <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'">
    </head>
    <body>
    <script>
    "use strict";

    """#

    private static let script = #"""
    var sorelloStopped = false;
    var sorelloMedia = null;
    var sorelloContext = null;
    var sorelloNodes = [];

    function sorelloPost(message) {
      webkit.messageHandlers.sorelloCapture.postMessage(message);
    }

    function sorelloStopTracks(media) {
      media.getTracks().forEach(function (track) { track.onended = null; track.stop(); });
    }

    // The tap, in a held page: its audio processing is made now, so it holds nothing from before; or, while the page
    // still chooses its input, as soon as it has chosen.
    function sorelloRecord() {
      if (!sorelloHeld) { return; }
      sorelloHeld = false;
      if (sorelloContext && sorelloMedia && !sorelloStopped) { sorelloConnect(sorelloContext, sorelloMedia); }
    }

    function sorelloStop() {
      sorelloStopped = true;
      if (sorelloMedia) { sorelloStopTracks(sorelloMedia); sorelloMedia = null; }
      sorelloNodes.forEach(function (node) { node.disconnect(); });
      sorelloNodes = [];
      if (sorelloContext) { sorelloContext.close(); sorelloContext = null; }
    }

    function sorelloEncode(samples) {
      var pcm = new Int16Array(samples.length);
      for (var i = 0; i < samples.length; i++) {
        var s = Math.max(-1, Math.min(1, samples[i]));
        pcm[i] = s < 0 ? Math.round(s * 32768) : Math.round(s * 32767);
      }
      var bytes = new Uint8Array(pcm.buffer);
      var text = "";
      for (var j = 0; j < bytes.length; j += 4096) {
        text += String.fromCharCode.apply(null, bytes.subarray(j, j + 4096));
      }
      return btoa(text);
    }

    function sorelloStart(media) {
      if (sorelloStopped) { sorelloStopTracks(media); return; }
      // A track can end before recording starts, while the page waits for its name to settle.
      var ended = media.getAudioTracks().some(function (track) { return track.readyState === "ended"; });
      if (ended) { sorelloStopTracks(media); sorelloMedia = null; sorelloPost({ kind: "ended" }); return; }
      sorelloMedia = media;
      media.getAudioTracks().forEach(function (track) {
        track.onended = function () { if (!sorelloStopped) { sorelloPost({ kind: "ended" }); } };
      });
      var context = new AudioContext();
      sorelloContext = context;
      if (!sorelloHeld) { sorelloConnect(context, media); }
    }

    // Each chunk is posted, its sequence starting at 0, with whether the track's label names the iPhone, as one of two
    // fixed words. A context iOS suspended or interrupted while held (a call, Siri, another app's audio) is resumed.
    function sorelloConnect(context, media) {
      if (context.state !== "running") { context.resume(); }
      var track = media.getAudioTracks()[0];
      var mic = track && sorelloBuiltInLabel.test(track.label) ? "builtIn" : "other";
      var size = 4096;
      while (size / context.sampleRate > 0.25 && size > 256) { size = size / 2; }
      var source = context.createMediaStreamSource(media);
      var processor = context.createScriptProcessor(size, 1, 1);
      var sequence = 0;
      processor.onaudioprocess = function (event) {
        if (sorelloStopped) { return; }
        sorelloPost({ kind: "audio", seq: sequence, rate: context.sampleRate, mic: mic,
                      pcm: sorelloEncode(event.inputBuffer.getChannelData(0)) });
        sequence += 1;
      };
      source.connect(processor);
      processor.connect(context.destination);
      sorelloNodes = [source, processor];
    }

    function sorelloFailed() {
      if (!sorelloStopped) { sorelloPost({ kind: "failed" }); }
    }

    function sorelloAsk(deviceId) {
      var audio = { channelCount: 1, echoCancellation: false, noiseSuppression: false, autoGainControl: false };
      if (deviceId) { audio.deviceId = { exact: deviceId }; }
      return navigator.mediaDevices.getUserMedia({ audio: audio, video: false });
    }

    // iOS labels its own microphone "iPhone Microphone" (in English), naming the device as a word.
    var sorelloBuiltInLabel = /(^|[^A-Za-z])(iPhone|iPad)([^A-Za-z]|$)/;

    // WebKit names the first track from its list of inputs before iOS settles the route, then renames it.
    var sorelloSettleStep = 100;
    var sorelloSettleLimit = 1500;

    // Asking for the iPhone's microphone by its id makes WebKit request it as the preferred input.
    function sorelloSwitch(media, deviceId) {
      sorelloStopTracks(media);
      sorelloMedia = null;
      sorelloAsk(deviceId).then(sorelloStart, function () {
        if (!sorelloStopped) { sorelloAsk(null).then(sorelloStart, sorelloFailed); }
      });
    }

    function sorelloSettle(media, track, deviceId, waited) {
      if (sorelloStopped) { return; }
      if (track.readyState === "ended") { sorelloStart(media); return; }
      if (!sorelloBuiltInLabel.test(track.label)) { sorelloSwitch(media, deviceId); return; }
      if (waited >= sorelloSettleLimit) { sorelloStart(media); return; }
      setTimeout(function () { sorelloSettle(media, track, deviceId, waited + sorelloSettleStep); }, sorelloSettleStep);
    }

    // The first track is kept, unrecorded, while the inputs are listed and its name settles, so a stop meanwhile
    // stops it.
    function sorelloChoose(media) {
      if (sorelloStopped) { sorelloStopTracks(media); return; }
      var track = media.getAudioTracks()[0];
      if (!sorelloPreferBuiltIn || !track) { sorelloStart(media); return; }
      sorelloMedia = media;
      navigator.mediaDevices.enumerateDevices().then(function (devices) {
        if (sorelloStopped) { return; }
        var inputs = devices.filter(function (device) { return device.kind === "audioinput" && device.deviceId; });
        var builtIn = inputs.filter(function (device) { return sorelloBuiltInLabel.test(device.label); });
        if (builtIn.length !== 1 || (inputs.length === 1 && sorelloBuiltInLabel.test(track.label))) {
          sorelloStart(media);
          return;
        }
        sorelloSettle(media, track, builtIn[0].deviceId, 0);
      }, function () {
        if (!sorelloStopped) { sorelloStart(media); }
      });
    }

    sorelloAsk(null).then(sorelloChoose, sorelloFailed);
    </script>
    </body>
    </html>
    """#
}
#endif
