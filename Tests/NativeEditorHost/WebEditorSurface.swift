import AppKit
import WebKit

struct WebEditorState: Codable, Equatable {
    let sequence: Int
    let text: String
    let selection: [Int]
    let focused: Bool

    var isValid: Bool {
        sequence >= 0 && text.utf16.count <= 100_000 && selection.count == 2
            && selection[0] >= 0 && selection[1] >= 0
            && selection[0] <= text.utf16.count && selection[1] <= text.utf16.count - selection[0]
    }
}

struct WebEditorEvent: Codable, Equatable {
    let event: String
    let trusted: Bool
    let state: WebEditorState
}

@MainActor
final class WebEditorSurface: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    let view: WKWebView
    var onEvent: ((WebEditorEvent) -> Void)?
    var onFailure: (() -> Void)?
    private(set) var state: WebEditorState?

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        view = WKWebView(frame: NSRect(x: 0, y: 0, width: 720, height: 360), configuration: configuration)
        super.init()
        configuration.userContentController.add(self, name: "probe")
        view.navigationDelegate = self
        view.autoresizingMask = [.width, .height]
    }

    func load() { view.loadHTMLString(Self.html, baseURL: nil) }

    func stop() {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "probe")
        view.navigationDelegate = nil
        view.stopLoading()
    }

    func containsResponder(_ responder: NSResponder?) -> Bool {
        guard let responder = responder as? NSView else { return false }
        return responder === view || responder.isDescendant(of: view)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame,
              let data = try? JSONSerialization.data(withJSONObject: message.body),
              let event = try? JSONDecoder().decode(WebEditorEvent.self, from: data),
              event.state.isValid,
              ["ready", "keydown", "keyup", "input", "selectionchange"].contains(event.event),
              event.event == "ready" || event.trusted,
              event.state.sequence == (state?.sequence ?? -1) + 1 else {
            onFailure?()
            return
        }
        state = event.state
        onEvent?(event)
    }

    // A fresh DOM read is independent of the event-driven snapshot. It may not
    // silently replace that snapshot, or a missed/untrusted edit would pass.
    func readState(_ completion: @escaping (WebEditorState?) -> Void) {
        view.evaluateJavaScript("window.probeState()") { result, error in
            guard error == nil, let result,
                  let data = try? JSONSerialization.data(withJSONObject: result),
                  let state = try? JSONDecoder().decode(WebEditorState.self, from: data), state.isValid else {
                completion(nil)
                return
            }
            completion(state)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.evaluateJavaScript("window.startProbe()") { [weak self] _, error in
            if error != nil { self?.onFailure?() }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { onFailure?() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { onFailure?() }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { onFailure?() }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        decisionHandler(navigationAction.request.url?.absoluteString == "about:blank" ? .allow : .cancel)
    }

    private static let html = #"""
    <!doctype html><html><head><meta charset="utf-8">
    <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'">
    <style>html,body{margin:0;height:100%;background:white}textarea{box-sizing:border-box;width:100%;height:100%;border:0;padding:16px;resize:none;font:20px system-ui;outline:none;letter-spacing:0}</style>
    </head><body><textarea id="editor" aria-label="Keyboard test editor" spellcheck="false" autocorrect="off" autocapitalize="off" autocomplete="off"></textarea>
    <script>
    (() => {
        const editor = document.getElementById('editor');
        let sequence = -1;
        let started = false;
        window.probeState = () => ({sequence, text: editor.value,
            selection: [editor.selectionStart, editor.selectionEnd - editor.selectionStart],
            focused: document.activeElement === editor && document.hasFocus()});
        const report = (event, trusted) => {
            sequence += 1;
            window.webkit.messageHandlers.probe.postMessage({event, trusted, state: window.probeState()});
        };
        for (const name of ['keydown', 'keyup', 'input']) {
            editor.addEventListener(name, event => { if (started) report(name, event.isTrusted); });
        }
        document.addEventListener('selectionchange', event => {
            if (started) report('selectionchange', event.isTrusted);
        });
        for (const name of ['copy', 'cut', 'paste', 'drop']) {
            editor.addEventListener(name, event => { event.preventDefault(); report('blocked', false); });
        }
        window.startProbe = () => {
            editor.focus();
            if (!started) { started = true; report('ready', true); }
        };
    })();
    </script></body></html>
    """#
}
