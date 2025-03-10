/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation
import WebKit
import Storage
import Shared
import SwiftyJSON
import XCGLogger

fileprivate var debugTabCount = 0

func mostRecentTab(inTabs tabs: [Tab]) -> Tab? {
    var recent = tabs.first
    tabs.forEach { tab in
        if let time = tab.lastExecutedTime, time > (recent?.lastExecutedTime ?? 0) {
            recent = tab
        }
    }
    return recent
}

protocol TabContentScript {
    static func name() -> String
    func scriptMessageHandlerName() -> String?
    func userContentController(_ userContentController: WKUserContentController, didReceiveScriptMessage message: WKScriptMessage)
}

@objc
protocol TabDelegate {
    func tab(_ tab: Tab, didAddSnackbar bar: SnackBar)
    func tab(_ tab: Tab, didRemoveSnackbar bar: SnackBar)
    func tab(_ tab: Tab, didSelectFindInPageForSelection selection: String)
    func tab(_ tab: Tab, didSelectSearchWithFirefoxForSelection selection: String)
    @objc optional func tab(_ tab: Tab, didCreateWebView webView: WKWebView)
    @objc optional func tab(_ tab: Tab, willDeleteWebView webView: WKWebView)
}

@objc
protocol URLChangeDelegate {
    func tab(_ tab: Tab, urlDidChangeTo url: URL)
}

struct TabState {
    var isPrivate: Bool = false
    var url: URL?
    var title: String?
    var favicon: Favicon?
}

enum TabGroupTimerState {
    case navSearchLoaded
    case tabNavigatedToDifferentUrl
    case tabSwitched
    case tabSelected
    case newTab
    case none
}

enum TabUrlType: String {
    case regular
    case search
    case followOnSearch
    case organicSearch
    case googleTopSite
    case googleTopSiteFollowOn
}

class Tab: NSObject {
    fileprivate var _isPrivate: Bool = false
    internal fileprivate(set) var isPrivate: Bool {
        get {
            return _isPrivate
        }
        set {
            if _isPrivate != newValue {
                _isPrivate = newValue
            }
        }
    }
    var urlType: TabUrlType = .regular
    var tabState: TabState {
        return TabState(isPrivate: _isPrivate, url: url, title: displayTitle, favicon: displayFavicon)
    }
    
    var timerPerWebsite: [String: StopWatchTimer] = [:]
    
    // Tab Groups
    var tabGroupsTimerHelper = StopWatchTimer()
    var tabGroupTimerState: TabGroupTimerState = .none
    var tabAssociatedSearchTerm: String = ""
    var tabAssociatedSearchUrl: String = ""
    var tabHistoryMetadatakey: HistoryMetadataKey?
    var tabHistoryCurrentState: TabGroupTimerState = .none
    
    // PageMetadata is derived from the page content itself, and as such lags behind the
    // rest of the tab.
    var pageMetadata: PageMetadata?

    var readabilityResult: ReadabilityResult?

    var consecutiveCrashes: UInt = 0
    
    // Setting defualt page as topsites
    var newTabPageType: NewTabPage = .topSites
    var tabUUID: String = UUID().uuidString
    private var screenshotUUIDString: String? //UUID().uuidString
    
    var screenshotUUID: UUID? {
        get {
            guard let uuidString = screenshotUUIDString else { return nil }
            return UUID(uuidString: uuidString)
        } set(value) {
            screenshotUUIDString = value?.uuidString ?? ""
        }
    }
    
    var adsTelemetryUrlList: [String] = [String]()
    var adsProviderName: String = ""
    
    // To check if current URL is the starting page i.e. either blank page or internal page like topsites
    var isURLStartingPage: Bool {
        guard url != nil else { return true }
        if url!.absoluteString.hasPrefix("internal://") {
            return true
        }
        return false
    }

    var canonicalURL: URL? {
        if let string = pageMetadata?.siteURL,
            let siteURL = URL(string: string) {

            // If the canonical URL from the page metadata doesn't contain the
            // "#" fragment, check if the tab's URL has a fragment and if so,
            // append it to the canonical URL.
            if siteURL.fragment == nil,
                let fragment = self.url?.fragment,
                let siteURLWithFragment = URL(string: "\(string)#\(fragment)") {
                return siteURLWithFragment
            }

            return siteURL
        }
        return self.url
    }

    var userActivity: NSUserActivity?

    var webView: WKWebView?
    var tabDelegate: TabDelegate?
    weak var urlDidChangeDelegate: URLChangeDelegate?     // TODO: generalize this.
    var bars = [SnackBar]()
    var favicons = [Favicon]() {
        didSet {
            updateFaviconCache()
        }
    }
    var lastExecutedTime: Timestamp?
    var firstCreatedTime: Timestamp?
    var sessionData: SessionData?
    fileprivate var lastRequest: URLRequest?
    var restoring: Bool = false
    var pendingScreenshot = false
    var url: URL? {
        didSet {
            if let _url = url, let internalUrl = InternalURL(_url), internalUrl.isAuthorized {
                url = URL(string: internalUrl.stripAuthorization)
            }
        }
    }
    var lastKnownUrl: URL? {
        // Tab url can be nil when user cold starts the app
        // thus we check session data for last known url
        guard self.url != nil else {
            return self.sessionData?.urls.last
        }
        return self.url
    }
    
    var isFxHomeTab: Bool {
        if let numberOfUrls = self.sessionData?.urls.count,
           let offset = self.sessionData?.currentPage,
           let url = self.sessionData?.urls[numberOfUrls - 1 + offset],
           url.absoluteString.hasPrefix("internal://") {
            return true
        }
        return false
    }
    
    var isCustomHomeTab: Bool {
        guard let profile = self.browserViewController?.profile else { return false }
        
        // Note: sessionData holds your navigation history on that tab, & sessionData.currentPage
        //  is where you are currently. With numberOfUrls - 1 + offset, we're grabbing the url
        //  for the last known position of navigation for that tab.
        if let customHomeUrl = HomeButtonHomePageAccessors.getHomePage(profile.prefs),
           let numberOfUrls = self.sessionData?.urls.count,
           let offset = self.sessionData?.currentPage,
           let url = self.sessionData?.urls[numberOfUrls - 1 + offset],
           let baseDomain = url.baseDomain,
           let customHomeBaseDomain = customHomeUrl.baseDomain,
           baseDomain.hasPrefix(customHomeBaseDomain) {
            return true
        }
        return false
    }

    var mimeType: String?
    var isEditing: Bool = false
    var currentFaviconUrl: URL?
    // When viewing a non-HTML content type in the webview (like a PDF document), this URL will
    // point to a tempfile containing the content so it can be shared to external applications.
    var temporaryDocument: TemporaryDocument?

    /// Returns true if this tab's URL is known, and it's longer than we want to store.
    var urlIsTooLong: Bool {
        guard let url = self.url else {
            return false
        }
        return url.absoluteString.lengthOfBytes(using: .utf8) > AppConstants.DB_URL_LENGTH_MAX
    }

    // Use computed property so @available can be used to guard `noImageMode`.
    var noImageMode: Bool {
        didSet {
            guard noImageMode != oldValue else {
                return
            }

            contentBlocker?.noImageMode(enabled: noImageMode)

            UserScriptManager.shared.injectUserScriptsIntoTab(self, nightMode: nightMode, noImageMode: noImageMode)
        }
    }

    var nightMode: Bool {
        didSet {
            guard nightMode != oldValue else {
                return
            }

            webView?.evaluateJavascriptInDefaultContentWorld("window.__firefox__.NightMode.setEnabled(\(nightMode))")
            // For WKWebView background color to take effect, isOpaque must be false,
            // which is counter-intuitive. Default is true. The color is previously
            // set to black in the WKWebView init.
            webView?.isOpaque = !nightMode

            UserScriptManager.shared.injectUserScriptsIntoTab(self, nightMode: nightMode, noImageMode: noImageMode)
        }
    }

    var contentBlocker: FirefoxTabContentBlocker?

    /// The last title shown by this tab. Used by the tab tray to show titles for zombie tabs.
    var lastTitle: String?

    /// Whether or not the desktop site was requested with the last request, reload or navigation.
    var changedUserAgent: Bool = false {
        didSet {
            if changedUserAgent != oldValue {
                TabEvent.post(.didToggleDesktopMode, for: self)
            }
        }
    }
    
    var readerModeAvailableOrActive: Bool {
        if let readerMode = self.getContentScript(name: "ReaderMode") as? ReaderMode {
            return readerMode.state != .unavailable
        }
        return false
    }

    fileprivate(set) var screenshot: UIImage?

    // If this tab has been opened from another, its parent will point to the tab from which it was opened
    weak var parent: Tab?

    fileprivate var contentScriptManager = TabContentScriptManager()

    fileprivate let configuration: WKWebViewConfiguration

    /// Any time a tab tries to make requests to display a Javascript Alert and we are not the active
    /// tab instance, queue it for later until we become foregrounded.
    fileprivate var alertQueue = [JSAlertInfo]()

    weak var browserViewController: BrowserViewController?

    init(bvc: BrowserViewController, configuration: WKWebViewConfiguration, isPrivate: Bool = false) {
        self.configuration = configuration
        self.nightMode = false
        self.noImageMode = false
        self.browserViewController = bvc
        super.init()
        self.isPrivate = isPrivate
        debugTabCount += 1

        TelemetryWrapper.recordEvent(category: .action, method: .add, object: .tab, value: isPrivate ? .privateTab : .normalTab)
    }
    
    func updateObservationForKey(key: HistoryMetadataKey, observation: HistoryMetadataObservation) {
        if let profile = self.browserViewController?.profile {
            profile.places.noteHistoryMetadataObservation(key: key, observation: observation)
        }
    }
 
    func updateHisotryMetadataKey(url: String, searchTerm: String, referralUrl: String) {
        self.tabHistoryMetadatakey = HistoryMetadataKey(url: url, searchTerm: searchTerm, referrerUrl: referralUrl)
    }

    func updateTimerAndObserving(state: TabGroupTimerState, searchTerm: String? = nil, searchProviderUrl: URL? = nil, nextUrl: String = "") {
        switch state {
        case .navSearchLoaded:
            tabGroupsTimerHelper.startOrResume()
            tabAssociatedSearchUrl = searchProviderUrl?.absoluteString ?? ""
            tabAssociatedSearchTerm = searchTerm ?? ""
            if let searchUrl = searchProviderUrl {
                self.tabHistoryMetadatakey = HistoryMetadataKey(url: searchUrl.absoluteString, searchTerm: searchTerm, referrerUrl: nextUrl)
            }
            tabHistoryCurrentState = state
        case .newTab:
            tabGroupsTimerHelper.resetTimer()
            tabGroupsTimerHelper.startOrResume()
            tabHistoryCurrentState = state
        case .tabNavigatedToDifferentUrl:
            let newKey = HistoryMetadataKey(url: tabAssociatedSearchUrl, searchTerm: tabAssociatedSearchTerm, referrerUrl: nextUrl)
            if let oldKey = self.tabHistoryMetadatakey, oldKey.referrerUrl != nextUrl {
                let observation = HistoryMetadataObservation(titleObservation: nil, viewTimeObservation: tabGroupsTimerHelper.elpasedTime, documentTypeObservation: nil)
                updateObservationForKey(key: oldKey, observation: observation)
            }
            self.tabHistoryMetadatakey = newKey
            tabGroupsTimerHelper.resetTimer()
            tabGroupsTimerHelper.startOrResume()
            tabHistoryCurrentState = state
        case .tabSelected:
            if tabGroupsTimerHelper.isPaused {
                tabGroupsTimerHelper.startOrResume()
            }
            tabHistoryCurrentState = state
        case .tabSwitched:
            if let key = tabHistoryMetadatakey {
                let observation = HistoryMetadataObservation(titleObservation: nil, viewTimeObservation: tabGroupsTimerHelper.elpasedTime, documentTypeObservation: nil)
                updateObservationForKey(key: key, observation: observation)
            }
            tabGroupsTimerHelper.pauseOrStop()
            tabHistoryCurrentState = state
        case .none:
            tabHistoryCurrentState = state
        }
    }

    class func toRemoteTab(_ tab: Tab) -> RemoteTab? {
        if tab.isPrivate {
            return nil
        }

        if let displayURL = tab.url?.displayURL, RemoteTab.shouldIncludeURL(displayURL) {
            let history = Array(tab.historyList.filter(RemoteTab.shouldIncludeURL).reversed())
            return RemoteTab(clientGUID: nil,
                URL: displayURL,
                title: tab.displayTitle,
                history: history,
                lastUsed: Date.now(),
                icon: nil)
        } else if let sessionData = tab.sessionData, !sessionData.urls.isEmpty {
            let history = Array(sessionData.urls.filter(RemoteTab.shouldIncludeURL).reversed())
            if let displayURL = history.first {
                return RemoteTab(clientGUID: nil,
                    URL: displayURL,
                    title: tab.displayTitle,
                    history: history,
                    lastUsed: sessionData.lastUsedTime,
                    icon: nil)
            }
        }

        return nil
    }

    weak var navigationDelegate: WKNavigationDelegate? {
        didSet {
            if let webView = webView {
                webView.navigationDelegate = navigationDelegate
            }
        }
    }

    func createWebview() {
        if webView == nil {
            configuration.userContentController = WKUserContentController()
            configuration.allowsInlineMediaPlayback = true
            let webView = TabWebView(frame: .zero, configuration: configuration)
            webView.delegate = self

            webView.accessibilityLabel = .WebViewAccessibilityLabel
            webView.allowsBackForwardNavigationGestures = true
            webView.allowsLinkPreview = true

            // Night mode enables this by toggling WKWebView.isOpaque, otherwise this has no effect.
            webView.backgroundColor = .black

            // Turning off masking allows the web content to flow outside of the scrollView's frame
            // which allows the content appear beneath the toolbars in the BrowserViewController
            webView.scrollView.layer.masksToBounds = false
            webView.navigationDelegate = navigationDelegate

            restore(webView)

            self.webView = webView
            self.webView?.addObserver(self, forKeyPath: KVOConstants.URL.rawValue, options: .new, context: nil)
            UserScriptManager.shared.injectUserScriptsIntoTab(self, nightMode: nightMode, noImageMode: noImageMode)
            tabDelegate?.tab?(self, didCreateWebView: webView)
        }
    }

    func restore(_ webView: WKWebView) {
        // Pulls restored session data from a previous SavedTab to load into the Tab. If it's nil, a session restore
        // has already been triggered via custom URL, so we use the last request to trigger it again; otherwise,
        // we extract the information needed to restore the tabs and create a NSURLRequest with the custom session restore URL
        // to trigger the session restore via custom handlers
        if let sessionData = self.sessionData {
            restoring = true

            var urls = [String]()
            for url in sessionData.urls {
                urls.append(url.absoluteString)
            }

            let currentPage = sessionData.currentPage
            self.sessionData = nil
            var jsonDict = [String: AnyObject]()
            jsonDict["history"] = urls as AnyObject?
            jsonDict["currentPage"] = currentPage as AnyObject?
            guard let json = JSON(jsonDict).stringify()?.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
                return
            }

            if let restoreURL = URL(string: "\(InternalURL.baseUrl)/\(SessionRestoreHandler.path)?history=\(json)") {
                let request = PrivilegedRequest(url: restoreURL) as URLRequest
                webView.load(request)
                lastRequest = request
            }
        } else if let request = lastRequest {
            webView.load(request)
        } else {
            print("creating webview with no lastRequest and no session data: \(self.url?.description ?? "nil")")
        }
    }

    deinit {
        debugTabCount -= 1

        #if DEBUG
        guard let appDelegate = UIApplication.shared.delegate as? AppDelegate else { return }
        func checkTabCount(failures: Int) {
            // Need delay for pool to drain.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                if appDelegate.tabManager.remoteTabs.count == debugTabCount {
                    return
                }

                // If this assert has false positives, remove it and just log an error.
                assert(failures < 3, "Tab init/deinit imbalance, possible memory leak.")
                checkTabCount(failures: failures + 1)
            }
        }
        checkTabCount(failures: 0)
        #endif
    }

    func close() {
        contentScriptManager.uninstall(tab: self)

        webView?.removeObserver(self, forKeyPath: KVOConstants.URL.rawValue)

        if let webView = webView {
            tabDelegate?.tab?(self, willDeleteWebView: webView)
        }

        webView?.navigationDelegate = nil
        webView?.removeFromSuperview()
        webView = nil
    }

    var loading: Bool {
        return webView?.isLoading ?? false
    }

    var estimatedProgress: Double {
        return webView?.estimatedProgress ?? 0
    }

    var backList: [WKBackForwardListItem]? {
        return webView?.backForwardList.backList
    }

    var forwardList: [WKBackForwardListItem]? {
        return webView?.backForwardList.forwardList
    }

    var historyList: [URL] {
        func listToUrl(_ item: WKBackForwardListItem) -> URL { return item.url }
        var tabs = self.backList?.map(listToUrl) ?? [URL]()
        if let url = url {
            tabs.append(url)
        }
        return tabs
    }

    var title: String? {
        return webView?.title
    }

    var displayTitle: String {
        if let title = webView?.title, !title.isEmpty {
            if let key = tabHistoryMetadatakey {
                if tabHistoryCurrentState == .navSearchLoaded {
                    let observation = HistoryMetadataObservation(titleObservation: title, viewTimeObservation: nil, documentTypeObservation: nil)
                    updateObservationForKey(key: key, observation: observation)
                } else if tabHistoryCurrentState == .tabNavigatedToDifferentUrl {
                    let observation = HistoryMetadataObservation(titleObservation: title, viewTimeObservation: nil, documentTypeObservation: nil)
                    updateObservationForKey(key: key, observation: observation)
                }
            }
            return title
        }

        // When picking a display title. Tabs with sessionData are pending a restore so show their old title.
        // To prevent flickering of the display title. If a tab is restoring make sure to use its lastTitle.
        if let url = self.url, InternalURL(url)?.isAboutHomeURL ?? false, sessionData == nil, !restoring {
            return Strings.AppMenuOpenHomePageTitleString
        }

        //lets double check the sessionData in case this is a non-restored new tab
        if let firstURL = sessionData?.urls.first, sessionData?.urls.count == 1, InternalURL(firstURL)?.isAboutHomeURL ?? false {
            return Strings.AppMenuOpenHomePageTitleString
        }

        if let url = self.url, !InternalURL.isValid(url: url), let shownUrl = url.displayURL?.absoluteString {
            return shownUrl
        }

        guard let lastTitle = lastTitle, !lastTitle.isEmpty else {
            return self.url?.displayURL?.absoluteString ??  ""
        }

        return lastTitle
    }

    var displayFavicon: Favicon? {
        return favicons.max { $0.width! < $1.width! }
    }

    var canGoBack: Bool {
        return webView?.canGoBack ?? false
    }

    var canGoForward: Bool {
        return webView?.canGoForward ?? false
    }

    func goBack() {
        _ = webView?.goBack()
    }

    func goForward() {
        _ = webView?.goForward()
    }

    func goToBackForwardListItem(_ item: WKBackForwardListItem) {
        _ = webView?.go(to: item)
    }

    @discardableResult func loadRequest(_ request: URLRequest) -> WKNavigation? {
        if let webView = webView {
            // Convert about:reader?url=http://example.com URLs to local ReaderMode URLs
            if let url = request.url, let syncedReaderModeURL = url.decodeReaderModeURL, let localReaderModeURL = syncedReaderModeURL.encodeReaderModeURL(WebServer.sharedInstance.baseReaderModeURL()) {
                let readerModeRequest = PrivilegedRequest(url: localReaderModeURL) as URLRequest
                lastRequest = readerModeRequest
                return webView.load(readerModeRequest)
            }
            lastRequest = request
            if let url = request.url, url.isFileURL, request.isPrivileged {
                return webView.loadFileURL(url, allowingReadAccessTo: url)
            }
            return webView.load(request)
        }
        return nil
    }

    func stop() {
        webView?.stopLoading()
    }

    func reload() {
        // If the current page is an error page, and the reload button is tapped, load the original URL
        if let url = webView?.url, let internalUrl = InternalURL(url), let page = internalUrl.originalURLFromErrorPage {
            webView?.replaceLocation(with: page)
            return
        }
        
        if let _ = webView?.reloadFromOrigin() {
            print("reloaded zombified tab from origin")
            return
        }

        if let webView = self.webView {
            print("restoring webView from scratch")
            restore(webView)
        }
    }

    func addContentScript(_ helper: TabContentScript, name: String) {
        contentScriptManager.addContentScript(helper, name: name, forTab: self)
    }

    func getContentScript(name: String) -> TabContentScript? {
        return contentScriptManager.getContentScript(name)
    }

    func hideContent(_ animated: Bool = false) {
        webView?.isUserInteractionEnabled = false
        if animated {
            UIView.animate(withDuration: 0.25, animations: { () -> Void in
                self.webView?.alpha = 0.0
            })
        } else {
            webView?.alpha = 0.0
        }
    }

    func showContent(_ animated: Bool = false) {
        webView?.isUserInteractionEnabled = true
        if animated {
            UIView.animate(withDuration: 0.25, animations: { () -> Void in
                self.webView?.alpha = 1.0
            })
        } else {
            webView?.alpha = 1.0
        }
    }

    func addSnackbar(_ bar: SnackBar) {
        if bars.count > 2 { return } // maximum 3 snackbars allowed on a tab
        bars.append(bar)
        tabDelegate?.tab(self, didAddSnackbar: bar)
    }

    func removeSnackbar(_ bar: SnackBar) {
        if let index = bars.firstIndex(of: bar) {
            bars.remove(at: index)
            tabDelegate?.tab(self, didRemoveSnackbar: bar)
        }
    }

    func removeAllSnackbars() {
        // Enumerate backwards here because we'll remove items from the list as we go.
        bars.reversed().forEach { removeSnackbar($0) }
    }

    func expireSnackbars() {
        // Enumerate backwards here because we may remove items from the list as we go.
        bars.reversed().filter({ !$0.shouldPersist(self) }).forEach({ removeSnackbar($0) })
    }

    func expireSnackbars(withClass snackbarClass: String) {
        bars.reversed().filter({ $0.snackbarClassIdentifier == snackbarClass }).forEach({ removeSnackbar($0) })
    }

    func setScreenshot(_ screenshot: UIImage?) {
        self.screenshot = screenshot
    }

    func toggleChangeUserAgent() {
        changedUserAgent = !changedUserAgent

        if changedUserAgent, let url = url?.withoutMobilePrefix() {
            let request = URLRequest(url: url)
            webView?.load(request)
        } else {
            reload()
        }

        TabEvent.post(.didToggleDesktopMode, for: self)
    }

    func queueJavascriptAlertPrompt(_ alert: JSAlertInfo) {
        alertQueue.append(alert)
    }

    func dequeueJavascriptAlertPrompt() -> JSAlertInfo? {
        guard !alertQueue.isEmpty else {
            return nil
        }
        return alertQueue.removeFirst()
    }

    func cancelQueuedAlerts() {
        alertQueue.forEach { alert in
            alert.cancel()
        }
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        guard let webView = object as? WKWebView, webView == self.webView,
            let path = keyPath, path == KVOConstants.URL.rawValue else {
            return assertionFailure("Unhandled KVO key: \(keyPath ?? "nil")")
        }
        guard let url = self.webView?.url else {
            return
        }

        self.urlDidChangeDelegate?.tab(self, urlDidChangeTo: url)
    }

    func isDescendentOf(_ ancestor: Tab) -> Bool {
        return sequence(first: parent) { $0?.parent }.contains { $0 == ancestor }
    }

    func observeURLChanges(delegate: URLChangeDelegate) {
        self.urlDidChangeDelegate = delegate
    }

    func removeURLChangeObserver(delegate: URLChangeDelegate) {
        if let existing = self.urlDidChangeDelegate, existing === delegate {
            self.urlDidChangeDelegate = nil
        }
    }

    func applyTheme() {
        UITextField.appearance().keyboardAppearance = isPrivate ? .dark : (ThemeManager.instance.currentName == .dark ? .dark : .light)
    }
    
    func getProviderForUrl() -> SearchEngine {
        guard let url = self.webView?.url else {
            return .none
        }
        for provider in SearchEngine.allCases {
            if (url.absoluteString.contains(provider.rawValue)) {
                return provider
            }
        }
        return .none
    }
    
    func updateFaviconCache() {
        guard let displayFavicon = displayFavicon?.url, let faviconUrl = URL(string: displayFavicon), let baseDomain = url?.baseDomain else {
            return
        }

        if currentFaviconUrl == nil {
            currentFaviconUrl = faviconUrl
        } else if !faviconUrl.isEqual(currentFaviconUrl!) {
            return
        }
        
        FaviconFetcher.downloadFaviconAndCache(imageURL: currentFaviconUrl, imageKey: baseDomain)
    }
}

extension Tab: TabWebViewDelegate {
    fileprivate func tabWebView(_ tabWebView: TabWebView, didSelectFindInPageForSelection selection: String) {
        tabDelegate?.tab(self, didSelectFindInPageForSelection: selection)
    }
    fileprivate func tabWebViewSearchWithFirefox(_ tabWebViewSearchWithFirefox: TabWebView, didSelectSearchWithFirefoxForSelection selection: String) {
        tabDelegate?.tab(self, didSelectSearchWithFirefoxForSelection: selection)
    }
}

extension Tab: ContentBlockerTab {
    func currentURL() -> URL? {
        return url
    }

    func currentWebView() -> WKWebView? {
        return webView
    }

    func imageContentBlockingEnabled() -> Bool {
        return noImageMode
    }
}

private class TabContentScriptManager: NSObject, WKScriptMessageHandler {
    private var helpers = [String: TabContentScript]()

    // Without calling this, the TabContentScriptManager will leak.
    func uninstall(tab: Tab) {
        helpers.forEach { helper in
            if let name = helper.value.scriptMessageHandlerName() {
                tab.webView?.configuration.userContentController.removeScriptMessageHandler(forName: name)
            }
        }
    }

    @objc func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        for helper in helpers.values {
            if let scriptMessageHandlerName = helper.scriptMessageHandlerName(), scriptMessageHandlerName == message.name {
                helper.userContentController(userContentController, didReceiveScriptMessage: message)
                return
            }
        }
    }

    func addContentScript(_ helper: TabContentScript, name: String, forTab tab: Tab) {
        if let _ = helpers[name] {
            assertionFailure("Duplicate helper added: \(name)")
        }

        helpers[name] = helper

        // If this helper handles script messages, then get the handler name and register it. The Browser
        // receives all messages and then dispatches them to the right TabHelper.
        if let scriptMessageHandlerName = helper.scriptMessageHandlerName() {
            tab.webView?.configuration.userContentController.addInDefaultContentWorld(scriptMessageHandler: self, name: scriptMessageHandlerName)
        }
    }

    func getContentScript(_ name: String) -> TabContentScript? {
        return helpers[name]
    }
}

private protocol TabWebViewDelegate: AnyObject {
    func tabWebView(_ tabWebView: TabWebView, didSelectFindInPageForSelection selection: String)
    func tabWebViewSearchWithFirefox(_ tabWebViewSearchWithFirefox: TabWebView, didSelectSearchWithFirefoxForSelection selection: String)
}

class TabWebView: WKWebView, MenuHelperInterface {
    fileprivate weak var delegate: TabWebViewDelegate?

    // Updates the `background-color` of the webview to match
    // the theme if the webview is showing "about:blank" (nil).
    func applyTheme() {
        if url == nil {
            let backgroundColor = ThemeManager.instance.current.browser.background.hexString
            evaluateJavascriptInDefaultContentWorld("document.documentElement.style.backgroundColor = '\(backgroundColor)';")
        }
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        return super.canPerformAction(action, withSender: sender) || action == MenuHelper.SelectorFindInPage
    }

    @objc func menuHelperFindInPage() {
        evaluateJavascriptInDefaultContentWorld("getSelection().toString()") { result, _ in
            let selection = result as? String ?? ""
            self.delegate?.tabWebView(self, didSelectFindInPageForSelection: selection)
        }
    }

    @objc func menuHelperSearchWithFirefox() {
        evaluateJavascriptInDefaultContentWorld("getSelection().toString()") { result, _ in
            let selection = result as? String ?? ""
            self.delegate?.tabWebViewSearchWithFirefox(self, didSelectSearchWithFirefoxForSelection: selection)
        }
    }

    internal override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        // The find-in-page selection menu only appears if the webview is the first responder.
        becomeFirstResponder()

        return super.hitTest(point, with: event)
    }
    
    /// Override evaluateJavascript - should not be called directly on TabWebViews any longer
    // We should only be calling evaluateJavascriptInDefaultContentWorld in the future
    @available(*, unavailable, message:"Do not call evaluateJavaScript directly on TabWebViews, should only be called on super class")
    override func evaluateJavaScript(_ javaScriptString: String, completionHandler: ((Any?, Error?) -> Void)? = nil) {
        super.evaluateJavaScript(javaScriptString, completionHandler: completionHandler)
    }
    
}

///
// Temporary fix for Bug 1390871 - NSInvalidArgumentException: -[WKContentView menuHelperFindInPage]: unrecognized selector
//
// This class only exists to contain the swizzledMenuHelperFindInPage. This class is actually never
// instantiated. It only serves as a placeholder for the method. When the method is called, self is
// actually pointing to a WKContentView. Which is not public, but that is fine, we only need to know
// that it is a UIView subclass to access its superview.
//

class TabWebViewMenuHelper: UIView {
    @objc func swizzledMenuHelperFindInPage() {
        if let tabWebView = superview?.superview as? TabWebView {
            tabWebView.evaluateJavascriptInDefaultContentWorld("getSelection().toString()") { result, _ in
                let selection = result as? String ?? ""
                tabWebView.delegate?.tabWebView(tabWebView, didSelectFindInPageForSelection: selection)
            }
        }
    }
}

extension URL {
    /**
    Returns a URL without a mobile prefix (`"m."` or `"mobile."`)
    */
    func withoutMobilePrefix() -> URL {
        let subDomainsToRemove: Set<String> = ["m", "mobile"]

        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: true) else { return self }
        guard let parts = components.host?.split(separator: ".").filter({ !subDomainsToRemove.contains(String($0)) }) else { return self }

        let host = parts.joined(separator: ".")

        guard host != publicSuffix else { return self }
        components.host = host

        return components.url ?? self
    }
}
