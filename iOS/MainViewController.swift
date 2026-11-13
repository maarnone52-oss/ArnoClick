import UIKit
import WebKit
import AVFoundation

/// Mostra ARNOCLICK (Web/index.html) e salva i file esportati con il pannello Condividi.
final class MainViewController: UIViewController, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    private var webView: WKWebView!
    private let panelColor = UIColor(red: 0.051, green: 0.055, blue: 0.063, alpha: 1)

    override func loadView() {
        let contentController = WKUserContentController()
        contentController.add(self, name: "save")
        contentController.add(self, name: "mic")
        contentController.add(self, name: "outs")

        let config = WKWebViewConfiguration()
        config.userContentController = contentController
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = panelColor
        webView.scrollView.backgroundColor = panelColor
        webView.navigationDelegate = self
        webView.uiDelegate = self
        if #available(iOS 16.4, *) { webView.isInspectable = true }
        view = webView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        guard let index = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Web") else { return }
        webView.loadFileURL(index, allowingReadAccessTo: index.deletingLastPathComponent())
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    // MARK: - Uscite audio multiple (scheda audio USB)

    private var watchingRoute = false

    private func applyOutputChannels() {
        let session = AVAudioSession.sharedInstance()
        let maxOut = session.maximumOutputNumberOfChannels
        if maxOut > 2 { try? session.setPreferredOutputNumberOfChannels(maxOut) }
    }

    private func sendOutputs() {
        let session = AVAudioSession.sharedInstance()
        let name = session.currentRoute.outputs.first?.portName ?? ""
        let obj: [String: Any] = ["name": name,
                                  "channels": max(session.outputNumberOfChannels, 2),
                                  "max": session.maximumOutputNumberOfChannels,
                                  "engine": NativeOut.supported]
        guard let d = try? JSONSerialization.data(withJSONObject: obj),
              let json = String(data: d, encoding: .utf8) else { return }
        webView?.evaluateJavaScript("window.arnoOuts&&arnoOuts(\(json))", completionHandler: nil)
    }

    // MARK: - Salvataggio dei file esportati (MIDI, WAV)

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        // Ascolto dal vivo: la sessione audio passa a "registrazione e ascolto" (altoparlante, non auricolare)
        // e torna alla sola riproduzione quando l'ascolto finisce.
        if message.name == "outs" {
            if let body = message.body as? [String: Any] { NativeOut.shared.handle(body); return }
            NativeOut.shared.onChange = { [weak self] in self?.sendOutputs() }
            // Uscite audio: con una scheda audio USB chiede tutte le sue uscite (non solo 2)
            // e manda alla pagina il nome e il numero di uscite; si ripete a ogni cambio di collegamento.
            applyOutputChannels()
            sendOutputs()
            if !watchingRoute {
                watchingRoute = true
                NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification,
                                                       object: nil, queue: .main) { [weak self] _ in
                    self?.applyOutputChannels()
                    self?.sendOutputs()
                }
            }
            return
        }
        if message.name == "mic" {
            let on = (message.body as? Bool) ?? false
            let session = AVAudioSession.sharedInstance()
            if on {
                try? session.setCategory(.playAndRecord, mode: .measurement,
                                         options: [.defaultToSpeaker, .allowBluetoothA2DP, .mixWithOthers])
            } else {
                try? session.setCategory(.playback, mode: .default, options: [])
            }
            try? session.setActive(true)
            applyOutputChannels()
            if watchingRoute { sendOutputs() }
            return
        }
        guard message.name == "save",
              let body = message.body as? [String: Any],
              let name = body["name"] as? String,
              let b64 = body["base64"] as? String,
              let data = Data(base64Encoded: b64) else { return }
        let safeName = name.replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(safeName)
        // File grandi (progetti con video): arrivano a pezzi e si scrivono in coda
        if let count = (body["count"] as? NSNumber)?.intValue,
           let index = (body["index"] as? NSNumber)?.intValue,
           let id = body["id"] as? String {
            if index == 0 {
                try? FileManager.default.removeItem(at: url)
                FileManager.default.createFile(atPath: url.path, contents: nil)
                partID = id
            }
            guard partID == id, let handle = try? FileHandle(forWritingTo: url) else { return }
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
            if index == count - 1 {
                partID = nil
                presentShare(url)
            }
            return
        }
        do { try data.write(to: url, options: .atomic) } catch { return }
        presentShare(url)
    }

    private var partID: String?

    private func presentShare(_ url: URL) {
        let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
            popover.permittedArrowDirections = []
        }
        present(sheet, animated: true)
    }

    // MARK: - Link esterni nel browser, non dentro l'app

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { return decisionHandler(.allow) }
        if url.isFileURL || url.scheme == "blob" || url.scheme == "about" || url.scheme == "data" {
            decisionHandler(.allow)
        } else {
            UIApplication.shared.open(url)
            decisionHandler(.cancel)
        }
    }

    // MARK: - Microfono per il BPM dal vivo: il permesso di sistema basta, niente seconda richiesta

    @available(iOS 15.0, *)
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(type == .microphone ? .grant : .deny)
    }

    // Se il sistema chiude il motore della pagina (poca memoria), la ricarica.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }
}
