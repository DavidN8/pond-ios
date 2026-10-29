//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Algorithms
import Combine
import Foundation
import MatchaProtocol
import WebKit

/// Runs the Yjs engine bundled from the Android fork (`Resources/MatchaDocs`, the same `engine.js` byte for byte, see
/// `Tools/Scripts/sync-matcha-docs-engine.sh`) in a headless `WKWebView` that exists only while documents are open. The page is
/// served by a custom scheme that only knows the two bundled files, under a content security policy that blocks every load but
/// its own script, so it has no network or file access and can't navigate. It talks to Swift through the `MatchaDocsBridge`
/// object the engine expects, which a user script provides: Swift hands each request over with `callAsyncJavaScript`, and the
/// engine's synchronous answer comes back as that call's result.
final class WebViewYjsEngine: YjsEngineProtocol {
    private var host: Host?
    private var openDocuments = 0
    private var nextDocumentID = 0
    private let stoppedSubject = PassthroughSubject<Void, Never>()
    
    var stoppedPublisher: AnyPublisher<Void, Never> {
        stoppedSubject.eraseToAnyPublisher()
    }
    
    func open() async throws(YjsEngineError) -> YjsDocumentProtocol {
        let host = if let host, host.isAlive {
            host
        } else {
            Host { [weak self] in self?.stoppedSubject.send() }
        }
        self.host = host
        openDocuments += 1
        nextDocumentID += 1
        let document = Document(engine: self, host: host, documentID: "doc-\(nextDocumentID)")
        do {
            _ = try await host.call("open", ["doc": .string(document.documentID)])
        } catch {
            document.close()
            throw error
        }
        return document
    }
    
    #if DEBUG
    /// Ends the engine's web content process, as the system may under memory pressure; for tests.
    func killContentProcessForTesting() {
        host?.killContentProcess()
    }
    #endif
    
    private func release(host: Host, documentID: String) {
        openDocuments -= 1
        if openDocuments <= 0, self.host === host {
            openDocuments = 0
            self.host = nil
            host.destroy()
        } else if host.isAlive {
            Task { _ = try? await host.call("close", ["doc": .string(documentID)]) }
        }
    }
    
    // MARK: - Document
    
    private final class Document: YjsDocumentProtocol {
        let documentID: String
        private weak var engine: WebViewYjsEngine?
        private let host: Host
        private var isClosed = false
        
        init(engine: WebViewYjsEngine, host: Host, documentID: String) {
            self.engine = engine
            self.host = host
            self.documentID = documentID
        }
        
        func apply(_ update: Data) async throws(YjsEngineError) -> Bool {
            try await call("apply", ["update": .string(update.base64EncodedString())]).bool("valid") == true
        }
        
        func applyAll(_ updates: [Data]) async throws(YjsEngineError) -> Int {
            var applied = 0
            // A replay crosses the bridge once per batch; batches keep each call well within the call timeout.
            for batch in updates.chunks(ofCount: WebViewYjsEngine.applyBatchSize) {
                let result = try await call("applyAll", ["updates": .array(batch.map { .string($0.base64EncodedString()) })])
                let count = Int(result.integer("applied") ?? 0)
                applied += count
                if count < batch.count {
                    break
                }
            }
            return applied
        }
        
        func snapshot() async throws(YjsEngineError) -> YjsSnapshot {
            let result = try await call("snapshot", [:])
            return YjsSnapshot(text: result.string("text") ?? "",
                               entries: result.object("entries") ?? [:],
                               isMissingUpdates: result.bool("missing") != false)
        }
        
        func edit(_ changes: [TextChange]) async throws(YjsEngineError) -> Data? {
            let changes = changes.map { change in
                JSONValue.object(["index": .integer(Int64(change.index)), "remove": .integer(Int64(change.remove)), "insert": .string(change.insert)])
            }
            return try await call("edit", ["changes": .array(changes)]).update
        }
        
        func setEntry(key: String, value: JSONObject) async throws(YjsEngineError) -> Data? {
            try await call("setEntry", ["key": .string(key), "value": .object(value)]).update
        }
        
        func merge(_ updates: [Data]) async throws(YjsEngineError) -> Data {
            guard let update = try await call("merge", ["updates": .array(updates.map { .string($0.base64EncodedString()) })]).update else {
                throw .failed(operation: "merge")
            }
            return update
        }
        
        func close() {
            guard !isClosed else { return }
            isClosed = true
            engine?.release(host: host, documentID: documentID)
        }
        
        private func call(_ operation: String, _ arguments: JSONObject) async throws(YjsEngineError) -> JSONObject {
            guard !isClosed else { throw .documentClosed }
            var arguments = arguments
            arguments["doc"] = .string(documentID)
            return try await host.call(operation, arguments)
        }
    }
    
    // MARK: - Host
    
    /// The web view and its bridge. Requests are answered in order by the page's single JavaScript thread.
    fileprivate final class Host: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        private(set) var isAlive = true
        private var isReady = false
        private var readyWaiters: [CheckedContinuation<Bool, Never>] = []
        private var pending: [Int: CheckedContinuation<Result<String, YjsEngineError>, Never>] = [:]
        private var timeouts: [Int: Task<Void, Never>] = [:]
        private var nextRequestID = 0
        private var readyTimeout: Task<Void, Never>?
        /// Called once when the web content process ends.
        private let onTerminate: () -> Void
        private var webView: WKWebView?
        
        init(onTerminate: @escaping () -> Void) {
            self.onTerminate = onTerminate
            super.init()
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            configuration.setURLSchemeHandler(SchemeHandler(), forURLScheme: WebViewYjsEngine.scheme)
            configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
            configuration.dataDetectorTypes = []
            let contentController = WKUserContentController()
            contentController.add(WeakScriptMessageHandler(self), name: WebViewYjsEngine.readyMessage)
            contentController.addUserScript(WKUserScript(source: WebViewYjsEngine.bridgeScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
            configuration.userContentController = contentController
            
            let webView = WKWebView(frame: .zero, configuration: configuration)
            webView.navigationDelegate = self
            self.webView = webView
            webView.load(URLRequest(url: WebViewYjsEngine.pageURL))
            readyTimeout = Task { [weak self] in
                try? await Task.sleep(for: WebViewYjsEngine.readyTimeout)
                guard let self, !Task.isCancelled, !isReady else { return }
                MXLog.error("The Matcha notes engine did not start")
                destroy()
            }
        }
        
        func call(_ operation: String, _ arguments: JSONObject) async throws(YjsEngineError) -> JSONObject {
            guard await awaitReady(), let webView else { throw .stopped }
            nextRequestID += 1
            let requestID = nextRequestID
            var request = arguments
            request["op"] = .string(operation)
            let requestJSON = JSONValue.object(request).jsonString
            
            let answer = await withCheckedContinuation { continuation in
                pending[requestID] = continuation
                timeouts[requestID] = Task { [weak self] in
                    try? await Task.sleep(for: WebViewYjsEngine.callTimeout)
                    guard !Task.isCancelled else { return }
                    self?.finish(requestID, .failure(.timedOut(operation: operation)))
                }
                webView.callAsyncJavaScript(WebViewYjsEngine.callScript,
                                            arguments: ["id": requestID, "request": requestJSON],
                                            in: nil,
                                            in: .page) { [weak self] result in
                    switch result {
                    case .success(let value as String):
                        self?.finish(requestID, .success(value))
                    case .success, .failure:
                        self?.finish(requestID, .failure(.failed(operation: operation)))
                    }
                }
            }
            
            // The page's error message may quote its input, which can be document text: it is never logged.
            guard let json = try JSONValue(json: answer.get())?.objectValue, json["error"] == nil, let result = json.object("result") else {
                throw .failed(operation: operation)
            }
            return result
        }
        
        #if DEBUG
        /// Asks WebKit to end the web content process and reports the end as WebKit does.
        ///
        /// ponytail: on the simulator WebKit's kill can fail ("Client not entitled") without a word, so the end is reported here
        /// too; a report from WebKit after it is ignored, as `destroy()` runs once.
        func killContentProcess() {
            guard let webView else { return }
            webView.perform(NSSelectorFromString("_killWebContentProcess"))
            webViewWebContentProcessDidTerminate(webView)
        }
        #endif
        
        func destroy() {
            guard isAlive else { return }
            isAlive = false
            readyTimeout?.cancel()
            readyWaiters.forEach { $0.resume(returning: false) }
            readyWaiters = []
            for requestID in Array(pending.keys) {
                finish(requestID, .failure(.stopped))
            }
            webView?.configuration.userContentController.removeAllScriptMessageHandlers()
            webView?.stopLoading()
            webView?.navigationDelegate = nil
            webView = nil
        }
        
        // MARK: WKNavigationDelegate
        
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            navigationAction.request.url == WebViewYjsEngine.pageURL ? .allow : .cancel
        }
        
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: any Error) {
            MXLog.error("The Matcha notes engine failed to load: \(error)")
            destroy()
        }
        
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation?, withError error: any Error) {
            MXLog.error("The Matcha notes engine failed to load: \(error)")
            destroy()
        }
        
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            MXLog.warning("The Matcha notes engine stopped")
            let wasAlive = isAlive
            destroy()
            if wasAlive {
                onTerminate()
            }
        }
        
        // MARK: WKScriptMessageHandler
        
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == WebViewYjsEngine.readyMessage, isAlive else { return }
            isReady = true
            readyTimeout?.cancel()
            readyWaiters.forEach { $0.resume(returning: true) }
            readyWaiters = []
        }
        
        // MARK: Private
        
        private func awaitReady() async -> Bool {
            guard isAlive else { return false }
            guard !isReady else { return true }
            return await withCheckedContinuation { readyWaiters.append($0) }
        }
        
        private func finish(_ requestID: Int, _ result: Result<String, YjsEngineError>) {
            timeouts.removeValue(forKey: requestID)?.cancel()
            pending.removeValue(forKey: requestID)?.resume(returning: result)
        }
    }
    
    /// Serves the two bundled files of the engine and nothing else.
    private final class SchemeHandler: NSObject, WKURLSchemeHandler {
        func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
            let url = urlSchemeTask.request.url
            let file: (name: String, type: String)? = switch url {
            case WebViewYjsEngine.pageURL: ("engine.html", "text/html")
            case WebViewYjsEngine.scriptURL: ("engine.js", "text/javascript")
            default: nil
            }
            guard let url, let file,
                  let fileURL = Bundle.main.url(forResource: file.name, withExtension: nil),
                  let data = try? Data(contentsOf: fileURL),
                  let response = HTTPURLResponse(url: url,
                                                 statusCode: 200,
                                                 httpVersion: "HTTP/1.1",
                                                 headerFields: ["Content-Type": "\(file.type); charset=utf-8",
                                                                "Content-Security-Policy": WebViewYjsEngine.contentSecurityPolicy]) else {
                urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
                return
            }
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
        }
        
        func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) { }
    }
    
    /// The content controller keeps its handlers alive, so it holds the host weakly.
    private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
        private weak var handler: WKScriptMessageHandler?
        
        init(_ handler: WKScriptMessageHandler) {
            self.handler = handler
        }
        
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            handler?.userContentController(userContentController, didReceive: message)
        }
    }
    
    // MARK: - Constants
    
    private static let scheme = "matcha-docs"
    private static let pageURL = URL(string: "matcha-docs://engine/engine.html")!
    private static let scriptURL = URL(string: "matcha-docs://engine/engine.js")!
    private static let contentSecurityPolicy = "default-src 'none'; script-src matcha-docs:"
    private static let readyMessage = "matchaDocsReady"
    private static let applyBatchSize = 100
    private static let readyTimeout: Duration = .seconds(10)
    private static let callTimeout: Duration = .seconds(30)
    
    /// The bridge the bundled engine calls: it pulls a request with `request(id)` and answers with `respond(id, json)`, both
    /// within `matchaDocs.handle(id)`, so `__matchaDocsCall` returns the answer.
    private static let bridgeScript = """
    (() => {
        const requests = new Map();
        const responses = new Map();
        window.MatchaDocsBridge = {
            request(id) {
                const request = requests.get(id);
                requests.delete(id);
                return request === undefined ? "{}" : request;
            },
            respond(id, response) {
                responses.set(id, response);
            },
            ready() {
                window.webkit.messageHandlers.\(readyMessage).postMessage(null);
            },
        };
        window.__matchaDocsCall = (id, request) => {
            requests.set(id, request);
            matchaDocs.handle(id);
            const response = responses.get(id);
            responses.delete(id);
            return response === undefined ? null : response;
        };
    })();
    """
    
    private static let callScript = "return window.__matchaDocsCall(id, request);"
}

private extension JSONObject {
    /// The update an engine call produced, nil when it changed nothing.
    var update: Data? {
        string("update").flatMap { Data(base64Encoded: $0) }
    }
}
