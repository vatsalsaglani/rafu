import AppKit
import Observation
import SwiftUI
import WebKit

@Observable
final class CanvasWebPreviewController: NSObject, WKNavigationDelegate, WKUIDelegate {
    let destination: CanvasWebDestination
    private(set) var status = "Not connected"
    private(set) var blockedNavigation: URL?
    @ObservationIgnored private(set) var webView: WKWebView?

    init(destination: CanvasWebDestination) { self.destination = destination }

    func connect() {
        guard webView == nil, let url = destination.url else { return }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        view.uiDelegate = self
        webView = view
        blockedNavigation = nil
        status = "Connecting"
        view.load(URLRequest(url: url))
    }

    func stop() {
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView?.removeFromSuperview()
        webView = nil
        status = "Paused — choose Load to resume"
    }

    func webView(
        _ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        guard !action.shouldPerformDownload, action.targetFrame != nil else {
            blockedNavigation = action.request.url.flatMap(Self.browserURL)
            status = "New windows and downloads are disabled"
            decisionHandler(.cancel)
            return
        }
        if action.targetFrame?.isMainFrame == true {
            guard let url = action.request.url, destination.permitsNavigation(to: url) else {
                blockedNavigation = action.request.url.flatMap(Self.browserURL)
                status = "Navigation left the selected app origin"
                decisionHandler(.cancel)
                return
            }
        }
        decisionHandler(.allow)
    }

    func webView(
        _ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void
    ) {
        guard response.canShowMIMEType else {
            status = "Downloads are disabled"
            decisionHandler(.cancel)
            return
        }
        if response.isForMainFrame,
            response.response.url.map({ !destination.permitsNavigation(to: $0) }) ?? true
        {
            status = "The redirect left the selected app origin"
            blockedNavigation = response.response.url.flatMap(Self.browserURL)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { status = "Connected" }
    func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: any Error
    ) {
        status = "The app could not be loaded. Check that its server is running."
    }
    func webView(
        _ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error
    ) {
        status = "The app load failed"
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        stop()
        status = "The web process stopped"
    }
    func webView(
        _ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
        completionHandler:
            @escaping @MainActor @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) ->
            Void
    ) {
        // Use system trust evaluation. Never bypass a certificate error or
        // inject credentials. Interactive HTTP authentication is not supported.
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else {
            status = "Browser authentication is required"
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        blockedNavigation = navigationAction.request.url.flatMap(Self.browserURL)
        status = "New windows are disabled"
        return nil
    }
    func webView(
        _ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
        decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void
    ) {
        status = "Camera and microphone access are disabled"
        decisionHandler(.deny)
    }

    private static func browserURL(_ url: URL) -> URL? {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
            ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
            parts.user == nil, parts.password == nil
        else { return nil }
        return url
    }
}

struct CanvasWebCard: View {
    @Environment(\.rafuTheme) private var theme
    @Environment(\.canvasPresentationID) private var presentationID
    let card: CanvasCard
    let board: CanvasBoardState
    let session: WorkspaceSession
    var body: some View {
        if let resources = session.canvasResources[board.id], resources.board === board,
            let controller = resources.web(for: card)
        {
            let isCurrent = resources.canPresent(owner: presentationID)
            VStack(spacing: 0) {
                if let url = controller.blockedNavigation {
                    HStack {
                        Text(controller.status).font(.system(size: 12))
                            .foregroundStyle(theme.palette.textSecondary).lineLimit(1)
                        Spacer()
                        Button("Open \(url.host() ?? "Link") in Browser") {
                            NSWorkspace.shared.open(url)
                        }
                        .buttonStyle(RafuSecondaryButtonStyle(compact: true))
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                }
                if controller.webView != nil {
                    CanvasWebHost(
                        controller: controller, acceptsInput: true,
                        isCurrentPresentation: isCurrent,
                        onInput: {
                            if board.focusedCardID != card.id || !board.contentIsActive {
                                board.focus(card.id)
                            }
                        },
                        canMount: { [weak resources] in
                            resources?.canPresent(owner: presentationID) == true
                        })
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "globe").font(.system(size: 28))
                            .foregroundStyle(theme.palette.textSecondary)
                            .accessibilityHidden(true)
                        Text(
                            CanvasCardPresentation.displayTitle(
                                title: controller.destination.address, content: card.content)
                        )
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.palette.textPrimary)
                        Button("Load") {
                            board.focus(card.id)
                            session.connectCanvasWeb(card.id, board: board.id)
                        }
                        .buttonStyle(RafuProminentButtonStyle())
                        .help("Load the page. Rafu does not start your server.")
                        Text(
                            "Rafu does not start your server. The page can contact external services once it loads."
                        )
                        .font(.system(size: 11)).foregroundStyle(theme.palette.textSecondary)
                        .multilineTextAlignment(.center)
                        if controller.status != "Not connected",
                            !controller.status.hasPrefix("Paused")
                        {
                            Text(controller.status).font(.system(size: 11))
                                .foregroundStyle(theme.palette.textSecondary)
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .allowsHitTesting(isCurrent)
        }
    }
}

private struct CanvasWebHost: NSViewRepresentable {
    let controller: CanvasWebPreviewController
    let acceptsInput: Bool
    let isCurrentPresentation: Bool
    let onInput: () -> Void
    let canMount: @MainActor () -> Bool
    func makeNSView(context: Context) -> NativeContentMount { NativeContentMount() }
    func updateNSView(_ view: NativeContentMount, context: Context) {
        guard isCurrentPresentation, canMount(), let web = controller.webView else {
            view.detach()
            return
        }
        view.mount(web)
        view.onContentMouseDown = onInput
        view.isHidden = false
        view.acceptsContentInput = acceptsInput
    }
    static func dismantleNSView(_ view: NativeContentMount, coordinator: ()) { view.detach() }
}
