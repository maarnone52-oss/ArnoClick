import Foundation
import AVFoundation
#if os(iOS)
import UIKit
#endif

/// Motore audio "nativo" per le uscite separate: la pagina gli manda musica e click
/// (PCM a 16 bit) e lui li suona sulle uscite scelte della scheda audio (es. musica 1-2, click 3).
/// Il motore della pagina continua a girare in silenzio e tiene il tempo per cursore, LED e loop.
final class NativeOut {
    static let shared = NativeOut()

    /// Un suono caricato: campioni a 16 bit interlacciati.
    final class Slot {
        let sr: Double, ch: Int, frames: Int
        var data: [Int16]
        init(sr: Double, ch: Int, frames: Int, data: [Int16]) { self.sr = sr; self.ch = ch; self.frames = frames; self.data = data }
    }

    private var slots: [String: Slot] = [:]
    private var partial: [String: (id: Int, data: Data, sr: Double, ch: Int, frames: Int)] = [:]

    private let engine = AVAudioEngine()
    private var source: AVAudioNode?
    private(set) var channels = 2
    private var hwRate = 48000.0
    private var observing = false
    /// Chiamata quando cambia la scheda audio o il numero di uscite.
    var onChange: (() -> Void)?

    // Stato della riproduzione (letto dal thread audio: sempre sotto lock)
    private let lockP: UnsafeMutablePointer<os_unfair_lock> = {
        let p = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1); p.initialize(to: os_unfair_lock()); return p
    }()
    private func lock() { os_unfair_lock_lock(lockP) }
    private func unlock() { os_unfair_lock_unlock(lockP) }
    /// Puntatori ai canali d'uscita (preparati una volta: niente allocazioni nel thread audio)
    private let outs = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: 128)
    private var playing = false
    private var mSlot: Slot?, cSlot: Slot?
    private var pos = 0.0                 // in campioni del brano
    private var loopA = -1.0, loopB = -1.0
    private var gm: Float = 1, gc: Float = 1
    private var rM = 0, rMst = true, rC = 2, rCst = false
    private var shot: Slot?, shotPos = 0.0

    // Ingressi della scheda audio (per suonare sulla base): due canali scelti, mandati alle uscite scelte
    private(set) var inOn = false
    private var inA = 0, inB = 1, inGain: Float = 1, inOut = 0, inOutSt = true
    private var sink: AVAudioNode?
    private var needRebuild = false
    private let ringSize = 16384
    private let ringA = UnsafeMutablePointer<Float>.allocate(capacity: 16384)
    private let ringB = UnsafeMutablePointer<Float>.allocate(capacity: 16384)
    private var ringW = 0, ringR = 0
    private let ringLock: UnsafeMutablePointer<os_unfair_lock> = {
        let p = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1); p.initialize(to: os_unfair_lock()); return p
    }()
    /// Numero di canali d'ingresso visti dal motore (0 = nessuno)
    private(set) var inChannels = 0

    static var supported: Bool {
        if #available(macOS 10.15, iOS 13.0, *) { return true }
        return false
    }

    // MARK: - Scheda audio

    /// Prepara il motore con tutte le uscite della scheda attuale.
    @discardableResult
    func prepare() -> Bool {
        guard NativeOut.supported else { return false }
        #if os(iOS)
        let s = AVAudioSession.sharedInstance()
        if inOn {
            if s.category != .playAndRecord {
                try? s.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP])
            }
            try? s.setPreferredIOBufferDuration(0.005)
        }
        try? s.setActive(true)
        if s.maximumOutputNumberOfChannels > 2 { try? s.setPreferredOutputNumberOfChannels(s.maximumOutputNumberOfChannels) }
        if inOn && s.maximumInputNumberOfChannels > 1 { try? s.setPreferredInputNumberOfChannels(s.maximumInputNumberOfChannels) }
        #endif
        let hw = engine.outputNode.outputFormat(forBus: 0)
        let n = max(2, Int(hw.channelCount))
        let rate = hw.sampleRate > 0 ? hw.sampleRate : 48000
        if source != nil && n == channels && rate == hwRate && !needRebuild && (sink != nil) == inOn {
            if !engine.isRunning { try? engine.start() }
            return engine.isRunning
        }
        engine.stop()
        if let old = source { engine.detach(old); source = nil }
        if let old = sink { engine.disconnectNodeInput(old); engine.detach(old); sink = nil }
        needRebuild = false
        channels = n; hwRate = rate
        let fmt: AVAudioFormat?
        if n <= 2 {
            fmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: AVAudioChannelCount(n))
        } else if let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(n)) {
            fmt = AVAudioFormat(standardFormatWithSampleRate: rate, channelLayout: layout)
        } else { fmt = nil }
        guard let format = fmt else { return false }
        if #available(macOS 10.15, iOS 13.0, *) {
            let node = AVAudioSourceNode(format: format) { [unowned self] _, _, frameCount, abl -> OSStatus in
                self.render(Int(frameCount), UnsafeMutableAudioBufferListPointer(abl))
                return noErr
            }
            engine.attach(node)
            engine.connect(node, to: engine.outputNode, format: format)
            source = node
            inChannels = 0
            if inOn {
                let inFmt = engine.inputNode.outputFormat(forBus: 0)
                if inFmt.channelCount > 0 && inFmt.sampleRate > 0 {
                    inChannels = Int(inFmt.channelCount)
                    let sk = AVAudioSinkNode { [unowned self] _, frameCount, abl -> OSStatus in
                        self.capture(Int(frameCount), UnsafePointer(abl))
                        return noErr
                    }
                    engine.attach(sk)
                    engine.connect(engine.inputNode, to: sk, format: inFmt)
                    sink = sk
                    #if os(macOS)
                    // buffer piccolo: meno ritardo tra lo strumento e l'ascolto
                    if let au = engine.outputNode.audioUnit {
                        var frames: UInt32 = 128
                        AudioUnitSetProperty(au, kAudioDevicePropertyBufferFrameSize, kAudioUnitScope_Global, 0,
                                             &frames, UInt32(MemoryLayout<UInt32>.size))
                    }
                    #endif
                }
            }
        }
        if !observing {
            observing = true
            NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
                guard let self = self else { return }
                self.needRebuild = true
                self.prepare()
                self.onChange?()
            }
        }
        engine.prepare()
        do { try engine.start() } catch { return false }
        return true
    }

    // MARK: - Messaggi dalla pagina

    func handle(_ b: [String: Any]) {
        guard let cmd = b["cmd"] as? String else { return }
        let num: (String) -> Double = { (b[$0] as? NSNumber)?.doubleValue ?? 0 }
        switch cmd {
        case "load":
            guard let slot = b["slot"] as? String, let b64 = b["b64"] as? String,
                  let chunk = Data(base64Encoded: b64) else { return }
            let id = Int(num("id")), index = Int(num("index")), count = Int(num("count"))
            if index == 0 {
                partial[slot] = (id, Data(capacity: Int(num("frames")) * Int(num("ch")) * 2), num("sr"), Int(num("ch")), Int(num("frames")))
            }
            guard var p = partial[slot], p.id == id else { return }
            p.data.append(chunk)
            partial[slot] = p
            if index == count - 1 {
                partial[slot] = nil
                var arr = [Int16](repeating: 0, count: p.data.count / 2)
                arr.withUnsafeMutableBufferPointer { dst in _ = p.data.copyBytes(to: dst) }
                let s = Slot(sr: p.sr, ch: max(1, p.ch), frames: p.frames, data: arr)
                lock(); slots[slot] = s; unlock()
            }
        case "route":
            lock()
            rM = Int(num("m")); rMst = (b["mm"] as? String) != "mono"
            rC = Int(num("c")); rCst = (b["cm"] as? String) == "st"
            unlock()
        case "play":
            prepare()
            let ms = slots[(b["m"] as? String) ?? "m"], cs = slots[(b["c"] as? String) ?? "c"]
            lock()
            mSlot = ms; cSlot = cs
            let sr = ms?.sr ?? cs?.sr ?? 48000
            pos = max(0, num("from") * sr)
            if let a = b["la"] as? NSNumber, let z = b["lb"] as? NSNumber, z.doubleValue > a.doubleValue {
                loopA = a.doubleValue * sr; loopB = z.doubleValue * sr
            } else { loopA = -1; loopB = -1 }
            gm = Float(num("gm")); gc = Float(num("gc"))
            playing = ms != nil || cs != nil
            unlock()
        case "stop":
            lock(); playing = false; unlock()
        case "vol":
            lock(); gm = Float(num("gm")); gc = Float(num("gc")); unlock()
        case "shot":
            prepare()
            lock(); shot = slots["t"]; shotPos = 0; unlock()
        case "input":
            let on = (b["on"] as? Bool) ?? false
            inA = max(0, Int(num("a"))); inB = Int(num("b")); inGain = Float(num("gain"))
            inOut = max(0, Int(num("out"))); inOutSt = (b["om"] as? String) != "mono"
            if on != inOn {
                inOn = on
                needRebuild = true
                lockRing(); ringW = 0; ringR = 0; unlockRing()
                if on {
                    #if os(iOS)
                    AVAudioSession.sharedInstance().requestRecordPermission { _ in
                        DispatchQueue.main.async { self.prepare(); self.onChange?() }
                    }
                    #else
                    prepare(); onChange?()
                    #endif
                } else {
                    #if os(iOS)
                    try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
                    #endif
                    prepare(); onChange?()
                }
            }
        case "drop":
            lock(); playing = false; shot = nil; slots.removeAll(); unlock()
            partial.removeAll()
        default: break
        }
    }

    private func lockRing() { os_unfair_lock_lock(ringLock) }
    private func unlockRing() { os_unfair_lock_unlock(ringLock) }

    // MARK: - Thread audio

    /// Riceve l'audio degli ingressi e lo mette da parte per l'uscita.
    private func capture(_ n: Int, _ abl: UnsafePointer<AudioBufferList>) {
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: abl))
        var pa: UnsafeMutablePointer<Float>? = nil, pb: UnsafeMutablePointer<Float>? = nil
        var idx = 0
        // formato non interlacciato: un buffer per canale
        for b in list {
            if idx == inA { pa = b.mData?.assumingMemoryBound(to: Float.self) }
            if idx == inB { pb = b.mData?.assumingMemoryBound(to: Float.self) }
            idx += 1
            if idx > max(inA, inB) { break }
        }
        guard let a = pa else { return }
        let bch = pb
        let mask = ringSize - 1
        os_unfair_lock_lock(ringLock)
        for i in 0..<n {
            let w = (ringW + i) & mask
            ringA[w] = a[i]
            ringB[w] = bch?[i] ?? a[i]
        }
        ringW += n
        if ringW - ringR > ringSize { ringR = ringW - ringSize }
        os_unfair_lock_unlock(ringLock)
    }

    /// Mette l'audio degli ingressi nelle uscite scelte (pochi millisecondi di ritardo).
    private func mixInputs(_ n: Int, _ nOut: Int) {
        guard inOn, sink != nil, os_unfair_lock_trylock(ringLock) else { return }
        defer { os_unfair_lock_unlock(ringLock) }
        var avail = ringW - ringR
        if avail > n * 3 { ringR = ringW - n; avail = n }   // non lasciare crescere il ritardo
        let k = min(n, avail)
        if k <= 0 { return }
        let mask = ringSize - 1
        let o0 = min(inOut, nOut - 1), o1 = min(inOut + 1, nOut - 1)
        let two = inB >= 0 && inB != inA
        for f in 0..<k {
            let r = (ringR + f) & mask
            let va = ringA[r] * inGain, vb = (two ? ringB[r] : ringA[r]) * inGain
            if inOutSt && o1 != o0 { outs[o0][f] += va; outs[o1][f] += vb }
            else { outs[o0][f] += two ? (va + vb) * 0.5 : va }
        }
        ringR += k
    }

    @inline(__always) private func sample(_ s: Slot, _ p: Double, _ c: Int) -> Float {
        let i = Int(p)
        if i < 0 || i >= s.frames { return 0 }
        let f = Float(p - Double(i))
        let ch = min(c, s.ch - 1)
        let a = Float(s.data[i * s.ch + ch])
        let b = i + 1 < s.frames ? Float(s.data[(i + 1) * s.ch + ch]) : a
        return (a + (b - a) * f) * (1.0 / 32768.0)
    }

    private func render(_ n: Int, _ bufs: UnsafeMutableAudioBufferListPointer) {
        var nOut = 0
        for b in bufs where nOut < 128 {
            guard let p = b.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let cnt = Int(b.mDataByteSize) / MemoryLayout<Float>.size
            p.initialize(repeating: 0, count: cnt)
            outs[nOut] = p; nOut += 1
        }
        if nOut > 0 { mixInputs(n, nOut) }
        guard nOut > 0, os_unfair_lock_trylock(lockP) else { return }
        defer { os_unfair_lock_unlock(lockP) }
        let m0 = min(rM, nOut - 1), m1 = min(rM + 1, nOut - 1), c0 = min(rC, nOut - 1), c1 = min(rC + 1, nOut - 1)
        if playing, let ref = mSlot ?? cSlot {
            let step = ref.sr / hwRate
            for f in 0..<n {
                if let m = mSlot {
                    let l = sample(m, pos, 0), r = m.ch > 1 ? sample(m, pos, 1) : l
                    if rMst && m1 != m0 { outs[m0][f] += l * gm; outs[m1][f] += r * gm }
                    else { outs[m0][f] += (l + r) * 0.5 * gm }
                }
                if let c = cSlot {
                    let v = c.ch > 1 ? (sample(c, pos, 0) + sample(c, pos, 1)) * 0.5 : sample(c, pos, 0)
                    outs[c0][f] += v * gc
                    if rCst && c1 != c0 { outs[c1][f] += v * gc }
                }
                pos += step
                if loopB > 0 && pos >= loopB { pos = loopA + (pos - loopB) }
                else if pos >= Double(ref.frames) { playing = false; break }
            }
        }
        if let s = shot {
            let step = s.sr / hwRate
            for f in 0..<n {
                let v = sample(s, shotPos, 0)
                outs[c0][f] += v
                if rCst && c1 != c0 { outs[c1][f] += v }
                shotPos += step
                if shotPos >= Double(s.frames) { shot = nil; break }
            }
        }
    }
}
