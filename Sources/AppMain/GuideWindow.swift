import AppKit
import WebKit

/// Shows the illustrated user guide (Resources/Guide/index.html) in a web view.
@MainActor
final class GuideWindowController: NSWindowController, WKNavigationDelegate {
    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "\(AppInfo.name) Guide"
        window.minSize = NSSize(width: 560, height: 400)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("Guide")
        let web = WKWebView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView = web
        super.init(window: window)
        web.navigationDelegate = self
        if let index = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Guide") {
            web.loadFileURL(index, allowingReadAccessTo: index.deletingLastPathComponent())
        } else {
            web.loadHTMLString("<p style='font: 15px -apple-system; padding: 40px'>The guide is not included in this build.</p>", baseURL: nil)
        }
        if !window.setFrameUsingName("Guide") { window.center() }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Links to the web open in the default browser; links inside the guide stay here.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        if let url = action.request.url, action.navigationType == .linkActivated, !url.isFileURL {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
        } else {
            decisionHandler(.allow)
        }
    }
}
