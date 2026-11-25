import UIKit
import WebKit
import AVFoundation

/// Mostra ARNOCLICK (Web/index.html) e salva i file esportati con il pannello Condividi.
final class MainViewController: UIViewController, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    /// ultimo ingresso scelto per il Dal vivo (resta selezionato tra un rilevamento e l'altro)
    private var lastInputId = -1
    private var webView: WKWebView!
    private let panelColor = UIColor(red: 0.051, green: 0.055, blue: 0.063, alpha: 1)

    override func loadView() {
        let contentController = WKUserContentController()
        contentController.add(self, name: "save")
        contentController.add(self, name: "mic")
        contentController.add(self, name: "inputs")
        contentController.add(self, name: "outs")
        contentController.add(self, name: "xv")

        let config = WKWebViewConfiguration()
        config.userContentController = contentController
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        // niente selezione del testo, menu Copia/Incolla e lente d'ingrandimento: ARNOCLICK è un'app, non una pagina da leggere
        if #available(iOS 14.5, *) { config.preferences.isTextInteractionEnabled = false }

        webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsLinkPreview = false
        webView.isOpaque = false
        webView.backgroundColor = panelColor
        webView.scrollView.backgroundColor = panelColor
        webView.navigationDelegate = self
        webView.uiDelegate = self
        if #available(iOS 16.4, *) { webView.isInspectable = true }
        view = webView
    }

    /// Spegne le pressioni prolungate di sistema del WKWebView (lente, menu di testo, anteprima dei link).
    /// Gli eventi touch arrivano comunque alla pagina, quindi i gesti di ARNOCLICK continuano a funzionare.
    private func disableSystemLongPress(in v: UIView) {
        for g in v.gestureRecognizers ?? [] where g is UILongPressGestureRecognizer {
            g.isEnabled = false
        }
        for sub in v.subviews { disableSystemLongPress(in: sub) }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        disableSystemLongPress(in: webView)
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
                                  "engine": NativeOut.supported,
                                  "inputs": NativeOut.shared.inOn ? max(NativeOut.shared.inChannels, session.inputNumberOfChannels)
                                                                  : session.maximumInputNumberOfChannels,
                                  "inOn": NativeOut.shared.inOn]
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
            if let body = message.body as? [String: Any] {
                if (body["cmd"] as? String) == "rec" { setupRecCallbacks() }
                NativeOut.shared.handle(body); return }
            NativeOut.shared.onChange = { [weak self] in self?.sendOutputs() }
            NativeOut.shared.onDiag = { [weak self] d in
                if let j = try? JSONSerialization.data(withJSONObject: d), let js = String(data: j, encoding: .utf8) {
                    self?.webView.evaluateJavaScript("window.__natDiag&&__natDiag(\(js))", completionHandler: nil)
                }
            }
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
        // Ingressi per il Dal vivo: l'elenco lo dà iOS (la pagina da sola li vede solo dopo aver aperto il microfono)
        if message.name == "inputs" {
            // identificativi fissi: -1 predefinito, -2 scheda USB, -3 microfono interno, 0… altri ingressi (per nome)
            let session = AVAudioSession.sharedInstance()
            func port(_ id: Int) -> AVAudioSessionPortDescription? {
                let list = session.availableInputs ?? []
                switch id {
                case -2: return list.first { $0.portType == .usbAudio }
                case -3: return list.first { $0.portType == .builtInMic }
                case let k where k >= 0: return list.filter { $0.portType != .usbAudio && $0.portType != .builtInMic }.dropFirst(k).first
                default: return nil
                }
            }
            if let body = message.body as? [String: Any], let id = body["use"] as? Int {
                lastInputId = id
                let p = port(id)
                try? session.setPreferredInput(p)
                // il nome serve alla pagina per aprire proprio quell'ingresso (altrimenti WebKit tiene la scheda USB)
                var nm = "\"\""
                if let n = p?.portName, let d = try? JSONSerialization.data(withJSONObject: [n]), let j = String(data: d, encoding: .utf8) {
                    nm = String(j.dropFirst().dropLast())
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    self.webView.evaluateJavaScript("window.__inputUsed&&__inputUsed(true,\(nm))", completionHandler: nil)
                }
            } else if (message.body as? String) == "restore" {
                // si lascia la scelta: resta valida per il prossimo rilevamento
            } else {
                let list = session.availableInputs ?? []
                var arr: [[String: Any]] = [["id": -1, "name": "Predefinito", "ch": 0, "def": lastInputId == -1]]
                if let m = list.first(where: { $0.portType == .builtInMic }) {
                    arr.append(["id": -3, "name": m.portName, "ch": m.channels?.count ?? 0, "def": lastInputId == -3])
                }
                let usbIn = list.first { $0.portType == .usbAudio }
                let usbOut = session.currentRoute.outputs.first { $0.portType == .usbAudio }
                if let name = usbIn?.portName ?? usbOut?.portName {
                    arr.append(["id": -2, "name": name, "ch": usbIn?.channels?.count ?? 0, "def": lastInputId == -2])
                }
                for (k, p) in list.filter({ $0.portType != .usbAudio && $0.portType != .builtInMic }).enumerated() {
                    arr.append(["id": k, "name": p.portName, "ch": p.channels?.count ?? 0, "def": lastInputId == k])
                }
                if let j = try? JSONSerialization.data(withJSONObject: arr), let js = String(data: j, encoding: .utf8) {
                    webView.evaluateJavaScript("window.__inputs&&__inputs(\(js))", completionHandler: nil)
                }
            }
            return
        }
        if message.name == "mic" {
            let on = (message.body as? Bool) ?? false
            let session = AVAudioSession.sharedInstance()
            NativeOut.shared.micOn = on
            if on {
                try? session.setCategory(.playAndRecord, mode: .measurement,
                                         options: [.defaultToSpeaker, .allowBluetoothA2DP, .mixWithOthers])
            } else {
                try? session.setCategory(.playback, mode: .default, options: [])
            }
            try? session.setActive(true)
            if !on && NativeOut.shared.inOn { NativeOut.shared.prepare() }   // ingressi accesi: resta in registrazione e ascolto
            applyOutputChannels()
            if watchingRoute { sendOutputs() }
            return
        }
        if message.name == "xv", let body = message.body as? [String: Any] { handleExtract(body); return }
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

    // MARK: - Estrazione dell'audio dai video (arriva a pezzi dalla pagina, torna come WAV a pezzi)

    private func xvDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("xv", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func handleExtract(_ body: [String: Any]) {
        guard let id = body["id"] as? String, let index = body["index"] as? Int, let count = body["count"] as? Int,
              let b64 = body["base64"] as? String, let data = Data(base64Encoded: b64) else { return }
        let ext = ((body["name"] as? String).map { ($0 as NSString).pathExtension }).flatMap { $0.isEmpty ? nil : $0 } ?? "mov"
        let src = xvDir().appendingPathComponent(id + "." + ext)
        if index == 0 { FileManager.default.createFile(atPath: src.path, contents: nil) }
        if let fh = try? FileHandle(forWritingTo: src) { fh.seekToEndOfFile(); fh.write(data); fh.closeFile() }
        guard index == count - 1 else { return }
        let dst = xvDir().appendingPathComponent(id + ".wav")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try AudioExtract.toWav(src: src, dst: dst)
                try? FileManager.default.removeItem(at: src)
                let wav = try Data(contentsOf: dst)
                try? FileManager.default.removeItem(at: dst)
                let CH = 3 * 1024 * 1024, n = max(1, (wav.count + CH - 1) / CH)
                for i in 0..<n {
                    let part = wav.subdata(in: (i * CH)..<min(wav.count, (i + 1) * CH)).base64EncodedString()
                    let sem = DispatchSemaphore(value: 0)
                    DispatchQueue.main.async {
                        self?.webView.evaluateJavaScript("window.__xvIn&&__xvIn('\(id)',\(i),\(n),'\(part)')") { _, _ in sem.signal() }
                    }
                    sem.wait()
                }
            } catch {
                try? FileManager.default.removeItem(at: src)
                let msg = (error as? AudioExtract.Fail).map { "\($0)" } ?? error.localizedDescription
                DispatchQueue.main.async {
                    self?.webView.evaluateJavaScript("window.__xvErr&&__xvErr('\(id)',\(String(reflecting: msg)))", completionHandler: nil)
                }
            }
        }
    }

    // MARK: - Registrazione base + suonato: i due WAV si salvano dal menu di condivisione
    private func setupRecCallbacks() {
        NativeOut.shared.onRecError = { [weak self] e in self?.webView.evaluateJavaScript("window.__recDone&&__recDone(false,'\(e)')", completionHandler: nil) }
        NativeOut.shared.onRecorded = { [weak self] mix, dry, _ in
            guard let self = self else { return }
            self.webView.evaluateJavaScript("window.__recDone&&__recDone(true)", completionHandler: nil)
            let sheet = UIActivityViewController(activityItems: [mix, dry], applicationActivities: nil)
            if let popover = sheet.popoverPresentationController {
                popover.sourceView = self.view
                popover.sourceRect = CGRect(x: self.view.bounds.midX, y: self.view.bounds.midY, width: 1, height: 1)
                popover.permittedArrowDirections = []
            }
            self.present(sheet, animated: true)
        }
    }
}
