#if SORELLO_KEYBOARD_DICTATION
import UIKit
import WebKit

/// One in-keyboard dictation's capture (ARCHITECTURE.md, "In-keyboard dictation (experiment)", Capture): a hidden web
/// view whose fixed page records through `getUserMedia`, since iOS refuses AVFoundation recording in a keyboard. WebKit
/// records in its own process, under the containing app's microphone permission. The web view is made for one
/// dictation, or for the held microphone and then handed to the tap's dictation (`handOver`), 1×1 pt and fully
/// transparent, and torn down with its message handler when it ends.
///
/// Locked down: a non-persistent data store; the initial load of the fixed page only, every other navigation, new
/// window and download cancelled; the microphone granted only to that page's main frame in this capture's web view,
/// and only while it is open and `mayGrantMicrophone` agrees; the camera and every other request denied; messages taken
/// only from that main frame while open, and read strictly (`CaptureMessageReader`). Nothing is sent into the page.
@MainActor
final class WebAudioCapture: NSObject, WKNavigationDelegate, WKUIDelegate {
    /// Asked right before WebKit's microphone grant: the attempt still runs (or the hold still holds) and the host does
    /// not own the microphone.
    private var mayGrantMicrophone: () -> Bool
    /// Each message read from the page, while open.
    private var onMessage: (CaptureMessageReader.Message) -> Void
    /// One of `CapturePage`'s fixed pages in the keyboard; a verification harness, never the keyboard, passes a
    /// synthetic source.
    private let page: String
    private var webView: WKWebView?
    private var reader = CaptureMessageReader()
    private var initialLoadAllowed = false
    private var initialResponseAllowed = false
    private(set) var isOpen = false
    /// The page has loaded, so its script, `sorelloRecord` included, is defined.
    private(set) var isLoaded = false

    init(page: String = CapturePage.html, mayGrantMicrophone: @escaping () -> Bool,
         onMessage: @escaping (CaptureMessageReader.Message) -> Void) {
        self.page = page
        self.mayGrantMicrophone = mayGrantMicrophone
        self.onMessage = onMessage
    }

    /// Adds the web view to `container` and loads the page, which asks for the microphone at once.
    func open(in container: UIView) {
        guard webView == nil, !isOpen else { return }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController.add(MessageRelay(capture: self), name: CapturePage.handlerName)
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.isUserInteractionEnabled = false
        webView.accessibilityElementsHidden = true
        webView.navigationDelegate = self
        webView.uiDelegate = self
        container.addSubview(webView)
        self.webView = webView
        isOpen = true
        webView.loadHTMLString(page, baseURL: CapturePage.baseURL)
    }

    /// The tap's dictation takes a held capture whose page has loaded: its grants and messages are the attempt's from
    /// now on, and the page records from now on (`CapturePage.recordScript`). A record script that fails is `failed`.
    func handOver(mayGrantMicrophone: @escaping () -> Bool, onMessage: @escaping (CaptureMessageReader.Message) -> Void) {
        guard isOpen, isLoaded, let webView else { return }
        self.mayGrantMicrophone = mayGrantMicrophone
        self.onMessage = onMessage
        webView.evaluateJavaScript(CapturePage.recordScript) { [weak self, weak webView] _, error in
            guard error != nil, let self, let webView else { return }
            failed(webView)
        }
    }

    /// Stops every track and the audio context, and tears the web view down at once; nothing it posts later is read.
    func close() {
        isOpen = false
        guard let webView else { return }
        self.webView = nil
        webView.evaluateJavaScript(CapturePage.stopScript, completionHandler: nil)
        webView.setMicrophoneCaptureState(.none, completionHandler: nil)
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: CapturePage.handlerName)
        webView.stopLoading()
        webView.removeFromSuperview()
    }

    fileprivate func received(_ message: WKScriptMessage) {
        guard isOpen, let webView, message.webView === webView, message.name == CapturePage.handlerName,
              message.frameInfo.isMainFrame, Self.isCaptureOrigin(message.frameInfo.securityOrigin) else { return }
        onMessage(reader.read(message.body))
    }

    private static func isCaptureOrigin(_ origin: WKSecurityOrigin) -> Bool {
        origin.protocol == "https" && origin.host == CapturePage.host && (origin.port == 0 || origin.port == 443)
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        // The initial load of the fixed page, once; nothing else, ever.
        let initial = webView === self.webView && isOpen && !initialLoadAllowed && navigationAction.targetFrame?.isMainFrame == true
            && navigationAction.navigationType == .other && navigationAction.request.url == CapturePage.baseURL
        if initial { initialLoadAllowed = true }
        decisionHandler(initial ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        let initial = webView === self.webView && isOpen && initialLoadAllowed && !initialResponseAllowed
            && navigationResponse.isForMainFrame && navigationResponse.response.url == CapturePage.baseURL
        if initial { initialResponseAllowed = true }
        decisionHandler(initial ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if webView === self.webView, isOpen { isLoaded = true }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        failed(webView)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        failed(webView)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        failed(webView)
    }

    /// The page could not be shown or its process ended: capture is gone, whatever the phase.
    private func failed(_ webView: WKWebView) {
        guard webView === self.webView, isOpen else { return }
        onMessage(.failed)
    }

    // MARK: WKUIDelegate

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void) {
        let grant = webView === self.webView && isOpen && type == .microphone && frame.isMainFrame
            && Self.isCaptureOrigin(origin) && Self.isCaptureOrigin(frame.securityOrigin) && mayGrantMicrophone()
        decisionHandler(grant ? .grant : .deny)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        nil
    }
}

/// The message handler, which WebKit holds strongly: it holds the capture weakly, so a capture that is gone reads nothing.
private final class MessageRelay: NSObject, WKScriptMessageHandler {
    private weak var capture: WebAudioCapture?

    init(capture: WebAudioCapture) {
        self.capture = capture
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated { capture?.received(message) }
    }
}
#endif
