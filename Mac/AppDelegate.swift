import Cocoa
import WebKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow!
    private let controller = WebViewController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.onLanguage = { [weak self] state in
            guard let self = self else { return }
            let parts = state.split(separator: "|").map(String.init)
            let l = parts.first ?? "it", u = parts.count > 1 ? parts[1] : self.ui
            let th = parts.count > 2 ? parts[2] : self.theme
            let li = parts.count > 3 ? parts[3] : self.light
            let vl = parts.count > 4 ? parts[4] : self.vlite
            guard l != self.lang || u != self.ui || th != self.theme || li != self.light || vl != self.vlite else { return }
            self.vlite = vl
            self.light = li
            self.lang = l
            self.ui = u
            self.theme = th
            self.buildMenu()
        }
        controller.onScale = { [weak self] in self?.buildMenu() }
        buildMenu()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 780),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "ARNOCLICK"
        // niente barra delle schede (che ripeteva il nome ARNOCLICK sotto il titolo)
        NSWindow.allowsAutomaticWindowTabbing = false
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 1000, height: 600)
        window.backgroundColor = NSColor(red: 0.051, green: 0.055, blue: 0.063, alpha: 1)
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 1280, height: 780))
        window.setFrameAutosaveName("ArnoClickWindow")
        window.center()
        window.delegate = self
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // MARK: - Menu a tendina (in italiano o inglese, come la lingua scelta nell'app)

    private var lang = "it"
    private var ui = "daw"
    private var theme = "dark"
    private var light = "full"
    private var vlite = "vfull"

    private func tr(_ it: String, _ en: String) -> String { lang == "it" ? it : en }

    /// Una voce che esegue un comando della pagina (vedi arnoMenu in index.html).
    @discardableResult
    private func add(_ menu: NSMenu, _ it: String, _ en: String, _ command: String,
                     _ key: String = "", _ mods: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let item = NSMenuItem(title: tr(it, en), action: #selector(WebViewController.menuCommand(_:)), keyEquivalent: key)
        item.keyEquivalentModifierMask = key.isEmpty ? [] : mods
        item.representedObject = command
        item.target = controller
        menu.addItem(item)
        return item
    }

    private func submenu(_ parent: NSMenu, _ it: String, _ en: String, _ fill: (NSMenu) -> Void) {
        let item = NSMenuItem(title: tr(it, en), action: nil, keyEquivalent: "")
        let menu = NSMenu(title: item.title)
        fill(menu)
        item.submenu = menu
        parent.addItem(item)
    }

    private func top(_ main: NSMenu, _ it: String, _ en: String, _ fill: (NSMenu) -> Void) -> NSMenu {
        let item = NSMenuItem()
        let menu = NSMenu(title: tr(it, en))
        fill(menu)
        item.submenu = menu
        main.addItem(item)
        return menu
    }

    private func key(_ scalar: Int) -> String { String(Character(UnicodeScalar(scalar)!)) }

    private func buildMenu() {
        let main = NSMenu()
        let left = key(NSLeftArrowFunctionKey), right = key(NSRightArrowFunctionKey)

        _ = top(main, "ARNOCLICK", "ARNOCLICK") { m in
            m.addItem(withTitle: tr("Informazioni su ARNOCLICK", "About ARNOCLICK"),
                      action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
            m.addItem(.separator())
            submenu(m, "Lingua", "Language") { l in
                add(l, "Italiano", "Italiano", "langIt").state = lang == "it" ? .on : .off
                add(l, "English", "English", "langEn").state = lang == "en" ? .on : .off
            }
            m.addItem(.separator())
            m.addItem(withTitle: tr("Nascondi ARNOCLICK", "Hide ARNOCLICK"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
            m.addItem(.separator())
            m.addItem(withTitle: tr("Esci da ARNOCLICK", "Quit ARNOCLICK"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        }

        _ = top(main, "File", "File") { m in
            add(m, "Apri brano, video o progetto…", "Open song, video or project…", "open", "o")
            add(m, "Recenti", "Recent", "recent", "r", [.command, .shift])
            m.addItem(.separator())
            add(m, "Salva progetto (.zip)…", "Save project (.zip)…", "exProj", "s")
            m.addItem(.separator())
            add(m, "Converti video…", "Convert video…", "convert")
            m.addItem(withTitle: tr("Chiudi finestra", "Close window"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        }

        _ = top(main, "Modifica", "Edit") { m in
            m.addItem(withTitle: tr("Annulla", "Undo"), action: Selector(("undo:")), keyEquivalent: "z")
            m.addItem(.separator())
            m.addItem(withTitle: tr("Taglia", "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
            m.addItem(withTitle: tr("Copia", "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
            m.addItem(withTitle: tr("Incolla", "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
            m.addItem(withTitle: tr("Seleziona tutto", "Select all"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
            m.addItem(.separator())
            add(m, "Imposta BPM…", "Set BPM…", "setBpm", "b")
            add(m, "Raddoppia BPM", "Double BPM", "dbl", "]")
            add(m, "Dimezza BPM", "Halve BPM", "half", "[")
            add(m, "BPM automatico", "Automatic BPM", "auto", "b", [.command, .option])
            m.addItem(.separator())
        }

        _ = top(main, "Trasporto", "Transport") { m in
            add(m, "Play / Pausa", "Play / Pause", "play", " ", [])
            add(m, "Torna all'inizio", "Back to start", "start", "\r", [])
            add(m, "Battuta precedente", "Previous bar", "prevBar", left, [])
            add(m, "Battuta successiva", "Next bar", "nextBar", right, [])
        }

        // i marker servono ormai solo per il loop: un unico menu Loop
        _ = top(main, "Loop", "Loop") { m in
            add(m, "Loop tra Inizio e Fine (acceso / spento)", "Loop between Start and End (on / off)", "loop", "l", [])
            m.addItem(.separator())
            add(m, "Inizio qui", "Start here", "mkStart", "i", [])
            add(m, "Fine qui", "End here", "mkEnd", "f", [])
            add(m, "Elimina marker selezionato", "Delete selected marker", "mkDel", key(NSBackspaceCharacter))
            m.addItem(.separator())
            submenu(m, "Aggancio (snap)", "Snap") { s in
                add(s, "Battuta", "Bar", "snap:bar"); add(s, "1/4", "1/4", "snap:4"); add(s, "1/8", "1/8", "snap:8")
                add(s, "1/8 terzina", "1/8 triplet", "snap:8T"); add(s, "1/16", "1/16", "snap:16"); add(s, "1/32", "1/32", "snap:32")
                add(s, "Libero", "Off", "snap:off")
            }
        }

        _ = top(main, "Traccia", "Track") { m in
            submenu(m, "Tempi della battuta", "Beats per bar") { s in
                for n in 1...7 { add(s, "\(n)", "\(n)", "bpb:\(n)") }
            }
            add(m, "Accento sì / no", "Accent on / off", "accent", "1")
            submenu(m, "Suono del click", "Click sound") { s in
                add(s, "Classico", "Classic", "sound:classic"); add(s, "Legnetto", "Woodblock", "sound:wood")
                add(s, "Campanaccio", "Cowbell", "sound:cow"); add(s, "Bacchette", "Sticks", "sound:sticks")
                add(s, "Charleston", "Hi-hat", "sound:hat"); add(s, "Elettronico", "Electronic", "sound:electro")
            }
            add(m, "Prova il suono", "Test the sound", "test", "t", [])
            m.addItem(.separator())
            add(m, "Ruota il video di 90°", "Rotate the video 90°", "rotate", "r")
            add(m, "Anteprima a tempo fisso", "Fixed-tempo preview", "warp", "t", [.command, .option])
        }

        _ = top(main, "Esporta", "Export") { m in
            add(m, "Click MIDI (.mid)…", "MIDI click (.mid)…", "exMidi", "e")
            add(m, "Brano mixato con click (.wav)…", "Song mixed with click (.wav)…", "exMix", "e", [.command, .shift])
            add(m, "Solo click (.wav)…", "Click only (.wav)…", "exClick", "e", [.command, .option])
            add(m, "Musica sx + click dx (.wav)…", "Music L + click R (.wav)…", "exStereo")
            m.addItem(.separator())
            add(m, "Brano a tempo fisso/tempo post-prodotto (.wav)…", "Song at fixed tempo/post-produced tempo (.wav)…", "exWarp")
            m.addItem(.separator())
            add(m, "Progetto completo (.zip)…", "Full project (.zip)…", "exProj")
        }

        _ = top(main, "Vista", "View") { m in
            add(m, "Zoom avanti", "Zoom in", "zoomIn", "+")
            add(m, "Zoom indietro", "Zoom out", "zoomOut", "-")
            add(m, "Tutto il brano", "Whole song", "zoomFit", "0")
            m.addItem(.separator())
            add(m, "Mostra / nascondi video", "Show / hide video", "video", "1", [.command, .option])
            m.addItem(.separator())
            add(m, "Interfaccia a pannelli", "Panel layout", "uiDaw").state = ui == "daw" ? .on : .off
            add(m, "Interfaccia classica", "Classic layout", "uiClassic").state = ui == "classic" ? .on : .off
            add(m, "Ripristina tracce", "Reset tracks", "trackReset")
            submenu(m, "Dimensione interfaccia", "Interface size") { s in
                let cur = WebViewController.uiScale
                func sc(_ it: String, _ en: String, _ obj: Any, _ key: String = "") {
                    let item = NSMenuItem(title: tr(it, en), action: #selector(WebViewController.setUiScale(_:)), keyEquivalent: key)
                    item.keyEquivalentModifierMask = key.isEmpty ? [] : [.command, .control]
                    item.representedObject = obj
                    item.target = controller
                    if let v = obj as? Double { item.state = abs(v - cur) < 0.001 ? .on : .off }
                    s.addItem(item)
                }
                sc("Più piccola (si vede di più)", "Smaller (see more)", "-", "-")
                sc("Più grande", "Larger", "+", "+")
                sc("Dimensione normale (100%)", "Normal size (100%)", "=", "0")
                s.addItem(.separator())
                for v in WebViewController.scaleSteps { sc("\(Int((v * 100).rounded()))%", "\(Int((v * 100).rounded()))%", v) }
            }
            add(m, "Modalità leggera (Mac vecchi)", "Light mode (old Macs)", "lightToggle").state = light == "light" ? .on : .off
            add(m, "Video leggero (a fotogrammi)", "Light video (frames)", "vliteToggle").state = vlite == "vlite" ? .on : .off
            m.addItem(.separator())
            submenu(m, "Tema", "Theme") { s in
                add(s, "Nero", "Black", "themeDark").state = theme == "dark" ? .on : .off
                add(s, "Grigio", "Grey", "themeGrey").state = theme == "grey" ? .on : .off
                s.addItem(.separator())
                add(s, "Grigio più chiaro", "Lighter grey", "greyUp", "=", [.command, .option])
                add(s, "Grigio più scuro", "Darker grey", "greyDown", "-", [.command, .option])
            }
        }

        let winMenu = top(main, "Finestra", "Window") { m in
            add(m, "Video in una finestra separata", "Video in a separate window", "detach", "v", [.command, .option])
            m.addItem(.separator())
            m.addItem(withTitle: tr("Contrai", "Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
            m.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
            let full = m.addItem(withTitle: tr("Schermo intero", "Full screen"), action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
            full.keyEquivalentModifierMask = [.command, .control]
        }
        NSApp.windowsMenu = winMenu

        let helpMenu = top(main, "Aiuto", "Help") { m in
            add(m, "Guida di ARNOCLICK", "ARNOCLICK Help", "help", "?")
        }
        NSApp.helpMenu = helpMenu

        NSApp.mainMenu = main
    }
}
