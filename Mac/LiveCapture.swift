import Cocoa
import AVFoundation

/// Ascolto dal vivo su macOS dove il motore web dell'app non offre il microfono (prima di macOS 12).
/// L'app cattura l'ingresso predefinito del Mac (microfono o scheda audio, già scelto con AudioInputs)
/// e manda l'audio alla pagina a blocchi; la pagina lo usa come se arrivasse dal microfono.
final class LiveCapture {
    static let shared = LiveCapture()

    private var engine: AVAudioEngine?
    private var run = 0
    private var eval: ((String) -> Void)?

    func handle(_ cmd: String, eval: @escaping (String) -> Void) {
        switch cmd {
        case "start": self.eval = eval; start()
        case "stop": stop()
        default: break
        }
    }

    private func start() {
        stop()
        let token = run
        if #available(macOS 10.14, *) {
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized:
                begin(token)
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .audio) { ok in
                    DispatchQueue.main.async { ok ? self.begin(token) : self.fail(token, "denied") }
                }
            default:
                fail(token, "denied")
            }
        } else {
            begin(token)
        }
    }

    private func begin(_ token: Int) {
        guard token == run else { return }   // nel frattempo l'ascolto è stato fermato
        let eng = AVAudioEngine()
        let input = eng.inputNode
        let fmt = input.outputFormat(forBus: 0)
        guard fmt.sampleRate > 0, fmt.channelCount > 0 else { fail(token, "nodev"); return }
        let rate = fmt.sampleRate
        input.installTap(onBus: 0, bufferSize: 4096, format: fmt) { [weak self] buf, _ in
            guard let self = self, let ch = buf.floatChannelData else { return }
            let n = Int(buf.frameLength), nc = Int(buf.format.channelCount)
            if n == 0 { return }
            let inter = buf.format.isInterleaved
            let st = inter ? nc : 1
            let l = ch[0]
            let r: UnsafeMutablePointer<Float> = nc > 1 ? (inter ? ch[0] + 1 : ch[1]) : ch[0]
            var pcm = [Int16](repeating: 0, count: n * 2)
            for i in 0..<n {
                let a = max(-1, min(1, l[i * st])), b = max(-1, min(1, r[i * st]))
                pcm[2 * i] = Int16(a * 32767)
                pcm[2 * i + 1] = Int16(b * 32767)
            }
            let b64 = pcm.withUnsafeBufferPointer { Data(buffer: $0).base64EncodedString() }
            DispatchQueue.main.async {
                if self.engine === eng { self.eval?("window.__arnoCap&&__arnoCap('\(b64)')") }
            }
        }
        do { try eng.start() } catch {
            input.removeTap(onBus: 0)
            fail(token, "error")
            return
        }
        engine = eng
        eval?("window.__arnoCapStart&&__arnoCapStart(true,\(rate))")
    }

    private func fail(_ token: Int, _ reason: String) {
        guard token == run else { return }
        eval?("window.__arnoCapStart&&__arnoCapStart(false,0,'\(reason)')")
    }

    func stop() {
        run += 1
        if let e = engine {
            e.inputNode.removeTap(onBus: 0)
            e.stop()
        }
        engine = nil
    }
}
