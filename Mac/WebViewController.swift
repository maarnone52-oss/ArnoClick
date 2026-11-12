import Cocoa
import WebKit

/// Mostra ARNOCLICK (Web/index.html): apre i brani con il pannello del Finder
/// e salva i file esportati con la finestra "Salva con nome".
final class WebViewController: NSViewController, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    private var webView: WKWebView!
    /// La pagina comunica la lingua scelta: i menu si rifanno in quella lingua.
    var onLanguage: ((String) -> Void)?
    /// Cambiata la dimensione dell'interfaccia: il menu Vista rimette il segno di spunta.
    var onScale: (() -> Void)?

    // MARK: - Dimensione dell'interfaccia (rimpicciolisce tutta la pagina per vedere più pannelli)

    static let scaleKey = "arnoclick.uiScale"
    static let scaleSteps: [Double] = [0.5, 0.55, 0.6, 0.67, 0.75, 0.8, 0.85, 0.9, 1.0, 1.1, 1.25]

    /// Valore salvato; la prima volta dipende dallo schermo (sui portatili da 13" parte più piccola).
    static var uiScale: Double {
        let v = UserDefaults.standard.double(forKey: scaleKey)
        if v >= 0.45 && v <= 1.5 { return v }
        let h = NSScreen.main?.visibleFrame.height ?? 900
        return h < 860 ? 0.8 : (h < 1050 ? 0.9 : 1.0)
    }

    func applyScale(_ s: Double) {
        guard let wv = webView else { return }
        if #available(macOS 11.0, *) {
            wv.pageZoom = CGFloat(s)
        } else {
            // macOS 10.13–10.15: lo stesso zoom della pagina che usa Safari (⌘–)
            let sel = NSSelectorFromString("_setPageZoomFactor:")
            if wv.responds(to: sel) {
                typealias SetZoom = @convention(c) (AnyObject, Selector, Double) -> Void
                let f = unsafeBitCast(wv.method(for: sel), to: SetZoom.self)
                f(wv, sel, s)
            } else {
                wv.evaluateJavaScript("document.documentElement.style.zoom='\(s)';window.dispatchEvent(new Event('resize'))", completionHandler: nil)
            }
        }
    }

    /// Voce del menu Vista > Dimensione interfaccia: un valore (0.8…) oppure "+", "-", "=".
    @objc func setUiScale(_ sender: NSMenuItem) {
        let cur = WebViewController.uiScale, steps = WebViewController.scaleSteps
        var s = cur
        if let v = sender.representedObject as? Double { s = v }
        else if let c = sender.representedObject as? String {
            switch c {
            case "+": s = steps.first(where: { $0 > cur + 0.001 }) ?? steps.last!
            case "-": s = steps.last(where: { $0 < cur - 0.001 }) ?? steps.first!
            default: s = 1.0
            }
        }
        UserDefaults.standard.set(s, forKey: WebViewController.scaleKey)
        applyScale(s)
        onScale?()
    }

    override func loadView() {
        let contentController = WKUserContentController()
        contentController.add(self, name: "save")
        contentController.add(self, name: "menuLang")
        contentController.add(self, name: "convert")

        let config = WKWebViewConfiguration()
        config.userContentController = contentController
        if #available(macOS 10.12, *) { config.mediaTypesRequiringUserActionForPlayback = [] }

        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1200, height: 900), configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        if #available(macOS 13.3, *) { webView.isInspectable = true }
        view = webView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        guard let index = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Web") else { return }
        webView.loadFileURL(index, allowingReadAccessTo: index.deletingLastPathComponent())
        applyScale(WebViewController.uiScale)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        applyScale(WebViewController.uiScale)
    }

    /// Voce di menu: esegue il comando nella pagina. Se la voce è stata attivata da un
    /// tasto singolo (senza ⌘) viene passato anche il tasto, così mentre si scrive in un
    /// campo la lettera finisce nel campo invece di far partire il comando.
    @objc func menuCommand(_ sender: NSMenuItem) {
        guard let command = sender.representedObject as? String else { return }
        var keyArg = "null"
        let plain = sender.keyEquivalentModifierMask.intersection([.command, .control, .option]).isEmpty
        if plain, NSApp.currentEvent?.type == .keyDown, let k = sender.keyEquivalent.unicodeScalars.first {
            switch Int(k.value) {
            case NSLeftArrowFunctionKey: keyArg = "'left'"
            case NSRightArrowFunctionKey: keyArg = "'right'"
            case 13: keyArg = "'enter'"
            default: keyArg = "'" + sender.keyEquivalent + "'"
            }
        }
        webView.evaluateJavaScript("window.arnoMenu&&arnoMenu('\(command)',\(keyArg))", completionHandler: nil)
    }

    /// Menu File > Apri brano…: equivale a cliccare sul riquadro di caricamento.
    @objc func openSong(_ sender: Any?) {
        webView.evaluateJavaScript("document.getElementById('file').click();", completionHandler: nil)
    }

    // MARK: - Scelta del file audio (il campo "scegli file" della pagina)

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        // "Apri in ARNOCLICK" dopo una conversione: il file è già scelto
        if let url = pendingOpen {
            pendingOpen = nil
            completionHandler([url])
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedFileTypes = ["wav", "wave", "aif", "aiff", "aifc", "mp3", "m4a", "aac", "caf", "mp4", "m4v", "mov", "webm", "zip"]
        panel.begin { result in
            completionHandler(result == .OK ? panel.urls : nil)
        }
    }

    // MARK: - Salvataggio dei file esportati (MIDI, WAV)

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        if message.name == "menuLang", let l = message.body as? String {
            onLanguage?(l)
            return
        }
        if message.name == "convert", let action = message.body as? String {
            handleConvert(action)
            return
        }
        guard message.name == "save",
              let body = message.body as? [String: Any],
              let name = body["name"] as? String,
              let b64 = body["base64"] as? String,
              let data = Data(base64Encoded: b64) else { return }
        // File grandi (progetti con video): arrivano a pezzi in un file temporaneo
        if let count = (body["count"] as? NSNumber)?.intValue,
           let index = (body["index"] as? NSNumber)?.intValue,
           let id = body["id"] as? String {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("arnoclick-" + id)
            if index == 0 {
                try? FileManager.default.removeItem(at: tmp)
                FileManager.default.createFile(atPath: tmp.path, contents: nil)
                partID = id
            }
            guard partID == id, let handle = try? FileHandle(forWritingTo: tmp) else { return }
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
            if index == count - 1 {
                partID = nil
                askWhereToSave(name: name) { url in
                    try? FileManager.default.removeItem(at: url)
                    try FileManager.default.moveItem(at: tmp, to: url)
                }
            }
            return
        }
        askWhereToSave(name: name) { url in try data.write(to: url, options: .atomic) }
    }

    private var partID: String?

    private func askWhereToSave(name: String, write: @escaping (URL) throws -> Void) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name.replacingOccurrences(of: "/", with: "-")
        panel.canCreateDirectories = true
        let save: (NSApplication.ModalResponse) -> Void = { result in
            guard result == .OK, let url = panel.url else { return }
            do { try write(url) } catch {
                let alert = NSAlert(error: error)
                alert.runModal()
            }
        }
        if let window = view.window {
            panel.beginSheetModal(for: window, completionHandler: save)
        } else {
            save(panel.runModal())
        }
    }

    // MARK: - Convertitore video del Mac (MP4 · H.264 720p · AAC 160 kbps)

    private var converter: VideoConverter?
    private var lastConverted: URL?
    private var pendingOpen: URL?

    private func js(_ code: String) {
        webView.evaluateJavaScript(code, completionHandler: nil)
    }

    private func jsString(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [s])) ?? Data("[\"\"]".utf8)
        let arr = String(data: data, encoding: .utf8) ?? "[\"\"]"
        return String(arr.dropFirst().dropLast())
    }

    private func handleConvert(_ action: String) {
        switch action {
        case "pick": pickAndConvert()
        case "cancel": converter?.cancel()
        case "open":
            guard let url = lastConverted else { return }
            pendingOpen = url
            js("document.getElementById('file').click();")
        default: break
        }
    }

    private func pickAndConvert() {
        guard converter == nil else { return }
        let open = NSOpenPanel()
        open.canChooseFiles = true
        open.canChooseDirectories = false
        open.allowsMultipleSelection = false
        open.allowedFileTypes = ["mov", "mp4", "m4v", "3gp"]
        let afterPick: (NSApplication.ModalResponse) -> Void = { [weak self] r in
            guard let self = self, r == .OK, let src = open.url else { return }
            DispatchQueue.main.async { self.askDestination(for: src) }
        }
        if let window = view.window { open.beginSheetModal(for: window, completionHandler: afterPick) }
        else { afterPick(open.runModal()) }
    }

    private func askDestination(for src: URL) {
        let save = NSSavePanel()
        save.allowedFileTypes = ["mp4"]
        save.canCreateDirectories = true
        save.directoryURL = src.deletingLastPathComponent()
        save.nameFieldStringValue = src.deletingPathExtension().lastPathComponent + "-720p.mp4"
        let afterSave: (NSApplication.ModalResponse) -> Void = { [weak self] r in
            guard let self = self, r == .OK, let dst = save.url else { return }
            if dst.standardizedFileURL == src.standardizedFileURL {
                self.js("window.cvNative&&cvNative('error',\(self.jsString("same")))")
                return
            }
            self.runConversion(src, dst)
        }
        if let window = view.window { save.beginSheetModal(for: window, completionHandler: afterSave) }
        else { afterSave(save.runModal()) }
    }

    private func runConversion(_ src: URL, _ dst: URL) {
        let size = ((try? FileManager.default.attributesOfItem(atPath: src.path)[.size]) as? NSNumber)?.doubleValue ?? 0
        js("window.cvNative&&cvNative('start',\(jsString(src.lastPathComponent)),\(size))")
        let conv = VideoConverter(source: src, destination: dst)
        converter = conv
        conv.start(progress: { [weak self] p in
            self?.js("window.cvNative&&cvNative('progress',\(p))")
        }, done: { [weak self] err in
            guard let self = self else { return }
            self.converter = nil
            if let err = err {
                self.js("window.cvNative&&cvNative('error',\(self.jsString(err)))")
                return
            }
            self.lastConverted = dst
            let out = ((try? FileManager.default.attributesOfItem(atPath: dst.path)[.size]) as? NSNumber)?.doubleValue ?? 0
            let info = "\(Int(conv.outputSize.width))×\(Int(conv.outputSize.height))"
            self.js("window.cvNative&&cvNative('done',\(self.jsString(dst.lastPathComponent)),\(out),\(self.jsString(info)),\(self.jsString(dst.deletingLastPathComponent().path)))")
        })
    }

    // MARK: - Link esterni nel browser, non dentro l'app

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { return decisionHandler(.allow) }
        if url.isFileURL || url.scheme == "blob" || url.scheme == "about" || url.scheme == "data" {
            // Un file trascinato fuori dal riquadro non deve sostituire la pagina.
            if url.isFileURL && url.lastPathComponent != "index.html" {
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        } else {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
        }
    }

    // MARK: - Microfono per il BPM dal vivo (macOS 12 e successivi)

    @available(macOS 12.0, *)
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(type == .microphone ? .grant : .deny)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }
}
