#if SORELLO_KEYBOARD_DICTATION
import Foundation

/// The keyboard's capture page (ARCHITECTURE.md, "In-keyboard dictation (experiment)", Capture): one fixed string,
/// with nothing interpolated into it, loaded under an `https` origin of a reserved domain that never resolves. Its
/// policy lets nothing load; its script uses only `getUserMedia`, Web Audio and the one message handler, posting mono
/// 16-bit chunks of at most 0.25 s as base64. A host test reads this source for anything that could reach outside it.
enum CapturePage {
    /// A secure context, so the page may call `getUserMedia`; `.invalid` never resolves.
    static let baseURL = URL(string: "https://capture.sorello.invalid/")!
    static let host = "capture.sorello.invalid"
    /// The one message handler.
    static let handlerName = "sorelloCapture"
    /// What Swift runs to stop it: every track and the audio context.
    static let stopScript = "sorelloStop();"

    static let html = #"""
    <!doctype html>
    <html>
    <head>
    <meta charset="utf-8">
    <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'">
    </head>
    <body>
    <script>
    "use strict";
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
      sorelloMedia = media;
      media.getAudioTracks().forEach(function (track) {
        track.onended = function () { if (!sorelloStopped) { sorelloPost({ kind: "ended" }); } };
      });
      var context = new AudioContext();
      sorelloContext = context;
      var size = 4096;
      while (size / context.sampleRate > 0.25 && size > 256) { size = size / 2; }
      var source = context.createMediaStreamSource(media);
      var processor = context.createScriptProcessor(size, 1, 1);
      var sequence = 0;
      processor.onaudioprocess = function (event) {
        if (sorelloStopped) { return; }
        sorelloPost({ kind: "audio", seq: sequence, rate: context.sampleRate,
                      pcm: sorelloEncode(event.inputBuffer.getChannelData(0)) });
        sequence += 1;
      };
      source.connect(processor);
      processor.connect(context.destination);
      sorelloNodes = [source, processor];
      if (context.state === "suspended") { context.resume(); }
    }

    navigator.mediaDevices.getUserMedia({
      audio: { channelCount: 1, echoCancellation: false, noiseSuppression: false, autoGainControl: false },
      video: false
    }).then(sorelloStart, function () { if (!sorelloStopped) { sorelloPost({ kind: "failed" }); } });
    </script>
    </body>
    </html>
    """#
}
#endif
