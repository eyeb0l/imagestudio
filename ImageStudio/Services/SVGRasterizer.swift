import Foundation
import UIKit
import WebKit

nonisolated enum SVGRasterError: Error, Equatable {
    /// The document isn't one WebKit can show as an image.
    case invalidDocument
    /// Rendering took too long, e.g. a document built to hang the renderer.
    case timedOut
    /// The web content process died.
    case rendererTerminated
    /// The app is in the background, where a web view can't be relied on to finish.
    case unavailableInBackground
    /// Setting up or running the web view failed, or the caller gave up while queued.
    case failed
    case cancelled
}

/// What to render: which part of a document, at what size. Pure, so the layout can be tested
/// without a web view.
nonisolated struct SVGRenderPlan: Equatable, Sendable {
    /// Largest bitmap edge. Bounds memory to about 67 MB per image.
    static let maxPixelSize = 4096

    /// The bitmap this plan produces, in pixels.
    let outputPixels: CGSize
    /// The size the whole document is drawn at, in pixels. Larger than `outputPixels` for a crop.
    let documentPixels: CGSize
    /// Where the bitmap's top-left corner is in the drawn document, in pixels.
    let offset: CGPoint
    /// Documents that give no size are drawn on a canvas of `SVGDocument.fallbackSize` units and
    /// scaled, so they're framed the same at every size.
    let hasIntrinsicSize: Bool

    /// The whole document, with its longest edge at `maxPixelSize`.
    init(document: SVGDocument, maxPixelSize: Int) {
        let edge = CGFloat(min(max(maxPixelSize, 1), Self.maxPixelSize))
        let ratio = document.aspectRatio
        let pixels = ratio >= 1
            ? CGSize(width: edge, height: max((edge / ratio).rounded(), 1))
            : CGSize(width: max((edge * ratio).rounded(), 1), height: edge)
        outputPixels = pixels
        documentPixels = pixels
        offset = .zero
        hasIntrinsicSize = document.intrinsicSize != nil
    }

    /// A crop of the document drawn at `documentPixels`, for zooming in beyond a bitmap of the
    /// whole document. `region` is in unit coordinates, where (1, 1) is the bottom-right corner.
    init(document: SVGDocument, documentPixels: CGSize, region: CGRect) {
        let region = region.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        let limit = CGFloat(Self.maxPixelSize)
        outputPixels = CGSize(width: min((region.width * documentPixels.width).rounded(), limit),
                              height: min((region.height * documentPixels.height).rounded(), limit))
        self.documentPixels = documentPixels
        offset = CGPoint(x: region.minX * documentPixels.width, y: region.minY * documentPixels.height)
        hasIntrinsicSize = document.intrinsicSize != nil
    }

    var isEmpty: Bool { outputPixels.width < 1 || outputPixels.height < 1 }

    /// The page shown in the web view. The document is base64-encoded into an `<img>`, so none of
    /// its text is parsed as HTML and WebKit treats it as an image: no scripts and no subresources,
    /// whatever it contains. The content security policy allows nothing else to load.
    func html(for data: Data, displayScale: CGFloat) -> String {
        let width = documentPixels.width / displayScale
        let height = documentPixels.height / displayScale
        let boxWidth = hasIntrinsicSize ? width : CGFloat(SVGDocument.fallbackSize.width)
        let boxHeight = hasIntrinsicSize ? height : CGFloat(SVGDocument.fallbackSize.height)
        let transform = "translate(\(-offset.x / displayScale)px,\(-offset.y / displayScale)px) scale(\(width / boxWidth))"
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1,minimum-scale=1,maximum-scale=1,shrink-to-fit=no">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'">
        <style>
        html,body{margin:0;padding:0;background:transparent;overflow:hidden;width:100%;height:100%}
        img{display:block;position:absolute;left:0;top:0;max-width:none;width:\(boxWidth)px;height:\(boxHeight)px;transform-origin:0 0;transform:\(transform)}
        </style></head><body><img alt="" src="data:image/svg+xml;base64,\(data.base64EncodedString())"></body></html>
        """
    }
}

/// Turns SVG documents into bitmaps with an off-screen `WKWebView`.
///
/// iOS has no public API that draws a whole SVG document: ImageIO and `UIImage` return nothing for
/// one (checked on the iOS 27.2 simulator). WebKit is the renderer the system does offer, so
/// everything that displays an SVG goes through here, via `ImageLoader`.
///
/// The documents are untrusted, so the web views run no JavaScript from content and have nowhere
/// to send anything: a non-persistent data store, no base URL or file access, a content rule list
/// blocking every load except the `data:` image, a navigation delegate allowing nothing but the
/// page itself, and the document shown as an `<img>` (see `SVGRenderPlan.html`).
///
/// A render can't hang its caller: it ends with an error after `timeout`, and that web view (with
/// its process) is thrown away. Web views are expensive to start (seconds in the simulator) but
/// renders on a running one take milliseconds, so at most `maxConcurrentRenders` exist and they're
/// reused until they've been idle for `idleLifetime`.
///
/// Main actor only because WebKit is. Everything here waits on callbacks instead of blocking.
final class SVGRasterizer {
    static let shared = SVGRasterizer()

    /// Cold starts of the web content process took up to 6 s in the simulator.
    nonisolated static let defaultTimeout: Duration = .seconds(20)
    private static let ruleListIdentifier = "ImageStudio.BlockAllLoads"
    /// `data:` URLs are exempt from content rules, so this leaves only the inline image.
    private static let blockEverything = #"[{"trigger":{"url-filter":".*"},"action":{"type":"block"}}]"#

    private let timeout: Duration
    private let maxConcurrentRenders: Int
    private let idleLifetime: Duration
    private let canRender: () -> Bool
    /// Lazy, so nothing touches WebKit until a render is really going ahead, e.g. in a background relaunch.
    private lazy var dataStore = WKWebsiteDataStore.nonPersistent()

    private var ruleList: WKContentRuleList?
    private var idleWebViews: [WKWebView] = []
    private var idleReleaseTask: Task<Void, Never>?
    private var activeRenders = 0
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Bool, Never>)] = []
    /// How many times the app has gone to the background. A render whose timeout spans one of
    /// these was stalled by the system, which says nothing about its document.
    private var suspensionCount = 0
    private var suspensionObserver: (any NSObjectProtocol)?

    /// How many web views this rasteriser has ever made, and the most renders at once, for tests.
    private(set) var webViewsCreated = 0
    private(set) var peakConcurrentRenders = 0

    init(timeout: Duration = SVGRasterizer.defaultTimeout,
         maxConcurrentRenders: Int = 2,
         idleLifetime: Duration = .seconds(60),
         canRender: @escaping () -> Bool = { UIApplication.shared.applicationState != .background }) {
        self.timeout = timeout
        self.maxConcurrentRenders = maxConcurrentRenders
        self.idleLifetime = idleLifetime
        self.canRender = canRender
        suspensionObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.noteAppWentToBackground() }
        }
    }

    isolated deinit {
        if let suspensionObserver { NotificationCenter.default.removeObserver(suspensionObserver) }
    }

    func noteAppWentToBackground() {
        suspensionCount += 1
    }

    /// Renders the whole document, with its longest edge at `maxPixelSize` and its background
    /// left transparent.
    func rasterize(_ data: Data, document: SVGDocument, maxPixelSize: Int,
                   timeout: Duration? = nil) async throws(SVGRasterError) -> UIImage {
        try await render(data, plan: SVGRenderPlan(document: document, maxPixelSize: maxPixelSize), timeout: timeout)
    }

    func render(_ data: Data, plan: SVGRenderPlan, timeout: Duration? = nil) async throws(SVGRasterError) -> UIImage {
        guard !plan.isEmpty, data.count <= SVGDocument.maxByteCount else { throw .invalidDocument }
        while true {
            let suspensions = suspensionCount
            do throws(SVGRasterError) {
                return try await attempt(data, plan: plan, timeout: timeout)
            } catch {
                // Only a timeout with the app in the foreground throughout blames the document.
                // The clock keeps running while the app is suspended, so the timeout can fire the
                // moment it comes back. If it is back, render again rather than report a failure.
                guard error == .timedOut, suspensionCount != suspensions else { throw error }
                guard canRender() else { throw .unavailableInBackground }
            }
        }
    }

    private func attempt(_ data: Data, plan: SVGRenderPlan, timeout: Duration?) async throws(SVGRasterError) -> UIImage {
        guard canRender() else { throw .unavailableInBackground }

        try await acquireRenderSlot()
        defer { releaseRenderSlot() }
        // The app may have gone to the background while this was queued.
        guard canRender() else { throw .unavailableInBackground }

        let webView = try await dequeueWebView()
        let job = SVGRenderJob(webView: webView, plan: plan, data: data)
        let result = await job.run(timeout: timeout ?? self.timeout)
        switch result {
        case .success, .failure(.invalidDocument):
            idleWebViews.append(webView)
        default:
            // It may still be stuck on this document. Dropping it ends its web content process.
            break
        }
        scheduleIdleRelease()
        // Going to the background stalls a web view. That says nothing about the document.
        if case .failure(.timedOut) = result, !canRender() { throw .unavailableInBackground }
        return try result.get()
    }

    // MARK: Concurrency limit

    private func acquireRenderSlot() async throws(SVGRasterError) {
        guard !Task.isCancelled else { throw .cancelled }
        if activeRenders < maxConcurrentRenders {
            noteRenderStarted()
            return
        }
        let id = UUID()
        let granted = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiters.append((id, continuation))
            }
        } onCancel: {
            Task { @MainActor in self.cancelWaiter(id) }
        }
        // A granted slot was already counted for this caller by `releaseRenderSlot()`.
        guard granted else { throw .cancelled }
    }

    private func releaseRenderSlot() {
        if waiters.isEmpty {
            activeRenders -= 1
        } else {
            waiters.removeFirst().continuation.resume(returning: true)
        }
    }

    private func noteRenderStarted() {
        activeRenders += 1
        peakConcurrentRenders = max(peakConcurrentRenders, activeRenders)
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(returning: false)
    }

    // MARK: Web views

    private func dequeueWebView() async throws(SVGRasterError) -> WKWebView {
        idleReleaseTask?.cancel()
        if let webView = idleWebViews.popLast() { return webView }
        return makeWebView(ruleList: try await compiledRuleList())
    }

    /// With no rule list nothing is rendered: a missing protection is a failure, not a downgrade.
    private func compiledRuleList() async throws(SVGRasterError) -> WKContentRuleList {
        if let ruleList { return ruleList }
        let store = WKContentRuleListStore.default()
        let compiled = try? await store?.compileContentRuleList(forIdentifier: Self.ruleListIdentifier,
                                                                encodedContentRuleList: Self.blockEverything)
        guard let compiled else { throw .failed }
        ruleList = compiled
        return compiled
    }

    private func makeWebView(ruleList: WKContentRuleList) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.preferences.isFraudulentWebsiteWarningEnabled = false
        configuration.websiteDataStore = dataStore
        configuration.userContentController.add(ruleList)
        configuration.suppressesIncrementalRendering = true
        configuration.dataDetectorTypes = []
        configuration.allowsAirPlayForMediaPlayback = false
        configuration.allowsPictureInPictureMediaPlayback = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all

        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webViewsCreated += 1
        return webView
    }

    private func scheduleIdleRelease() {
        idleReleaseTask?.cancel()
        idleReleaseTask = Task { [idleLifetime] in
            try? await Task.sleep(for: idleLifetime)
            guard !Task.isCancelled else { return }
            self.idleWebViews.removeAll()
        }
    }
}

/// One render on one web view: load the page, check the image really loaded, take a snapshot.
/// Ends exactly once, on the first of success, failure and timeout.
private final class SVGRenderJob: NSObject, WKNavigationDelegate {
    /// Asks the page whether WebKit managed to read the image. An SVG that's unusable leaves a
    /// blank page rather than failing the load, so this can't be told from the navigation.
    /// `allowsContentJavaScript` limits the page's scripts, not this one from the app.
    private static let imageLoaded = "(function(){var i=document.images[0];return !!i&&i.complete&&i.naturalWidth>0})()"

    private let webView: WKWebView
    private let plan: SVGRenderPlan
    private let data: Data
    private var navigation: WKNavigation?
    private var continuation: CheckedContinuation<Result<UIImage, SVGRasterError>, Never>?
    private var timeoutTask: Task<Void, Never>?

    init(webView: WKWebView, plan: SVGRenderPlan, data: Data) {
        self.webView = webView
        self.plan = plan
        self.data = data
    }

    func run(timeout: Duration) async -> Result<UIImage, SVGRasterError> {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled else { return }
                self?.finish(.failure(.timedOut))
            }
            let scale = max(webView.traitCollection.displayScale, 1)
            webView.frame = CGRect(x: 0, y: 0, width: plan.outputPixels.width / scale,
                                   height: plan.outputPixels.height / scale)
            webView.navigationDelegate = self
            // A nil base URL gives the page an opaque origin, with no access to files or anything else.
            navigation = webView.loadHTMLString(plan.html(for: data, displayScale: scale), baseURL: nil)
        }
    }

    private func finish(_ result: Result<UIImage, SVGRasterError>) {
        guard let continuation else { return }
        self.continuation = nil
        timeoutTask?.cancel()
        webView.navigationDelegate = nil
        webView.stopLoading()
        continuation.resume(returning: result)
    }

    private func takeSnapshot() {
        let configuration = WKSnapshotConfiguration()
        configuration.rect = webView.bounds
        // Waiting for a screen update isn't useful or dependable in a view that isn't on screen.
        configuration.afterScreenUpdates = false
        webView.takeSnapshot(with: configuration) { [weak self] image, _ in
            guard let self else { return }
            if let cgImage = image?.cgImage {
                // Scale 1, like every other image `ImageLoader` returns.
                finish(.success(UIImage(cgImage: cgImage)))
            } else {
                finish(.failure(.failed))
            }
        }
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        // Only the page itself, which has this URL because it was loaded with no base URL.
        decisionHandler(navigationAction.request.url?.absoluteString == "about:blank" ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard navigation === self.navigation else { return }
        webView.evaluateJavaScript(Self.imageLoaded) { [weak self] value, _ in
            guard let self, continuation != nil else { return }
            if value as? Bool == true {
                takeSnapshot()
            } else {
                finish(.failure(.invalidDocument))
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        guard navigation === self.navigation else { return }
        finish(.failure(.failed))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        guard navigation === self.navigation else { return }
        finish(.failure(.failed))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finish(.failure(.rendererTerminated))
    }
}

/// Rendered bitmaps of SVG files in Caches, so the library grid doesn't need a web view for images
/// it has shown before. Each source file has its own folder, so its entries can go with it.
nonisolated struct SVGRasterCache: Sendable {
    static let shared = SVGRasterCache(directory: URL.cachesDirectory.appending(path: "SVGRasters", directoryHint: .isDirectory))
    /// The full-screen viewer's larger bitmaps are big files and quick to redo once WebKit's running.
    static let maxCachedPixelSize = 2048

    let directory: URL

    func url(forSource source: URL, maxPixelSize: Int) -> URL {
        folder(for: source.lastPathComponent).appending(path: "\(maxPixelSize).png", directoryHint: .notDirectory)
    }

    func store(_ image: UIImage, forSource source: URL, maxPixelSize: Int) {
        guard maxPixelSize <= Self.maxCachedPixelSize, let data = image.pngData() else { return }
        let url = url(forSource: source, maxPixelSize: maxPixelSize)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Originals use the same protection, so a background relaunch can read them while locked.
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// Removes everything cached for a source file.
    func remove(fileName: String) {
        try? FileManager.default.removeItem(at: folder(for: fileName))
    }

    func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func folder(for fileName: String) -> URL {
        directory.appending(path: fileName, directoryHint: .isDirectory)
    }
}
