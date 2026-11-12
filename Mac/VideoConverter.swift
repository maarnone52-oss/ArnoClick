import AVFoundation

/// Convertitore video del Mac (AVFoundation, funziona da High Sierra in poi, usa il
/// codificatore H.264 del Mac): MP4 · H.264 con lato corto 720 px · audio AAC 160 kbps.
final class VideoConverter {
    static let shortSide: CGFloat = 720
    static let audioBitRate = 160_000

    private let source: URL
    private let destination: URL
    private var reader: AVAssetReader?
    private var writer: AVAssetWriter?
    private var cancelled = false

    /// Larghezza × altezza come si vede il video (già ruotato), dopo la conversione.
    private(set) var outputSize = CGSize.zero
    private(set) var duration: Double = 0

    init(source: URL, destination: URL) {
        self.source = source
        self.destination = destination
    }

    func cancel() {
        cancelled = true
        reader?.cancelReading()
        writer?.cancelWriting()
    }

    /// progress: 0…1 (chiamato sul thread principale); done: nil se tutto bene, altrimenti il messaggio d'errore.
    func start(progress: @escaping (Double) -> Void, done: @escaping (String?) -> Void) {
        let finish: (String?) -> Void = { msg in DispatchQueue.main.async { done(msg) } }
        let asset = AVURLAsset(url: source)
        guard let vTrack = asset.tracks(withMediaType: .video).first else { return finish("novideo") }
        let aTrack = asset.tracks(withMediaType: .audio).first
        duration = max(0.001, CMTimeGetSeconds(asset.duration))

        // dimensioni: si scala il lato corto a 720 (mai ingrandire), numeri pari
        let nat = vTrack.naturalSize
        let k = min(1, VideoConverter.shortSide / max(1, min(abs(nat.width), abs(nat.height))))
        let w = max(2, Int((abs(nat.width) * k / 2).rounded()) * 2)
        let h = max(2, Int((abs(nat.height) * k / 2).rounded()) * 2)
        let shown = CGSize(width: w, height: h).applying(vTrack.preferredTransform)
        outputSize = CGSize(width: abs(shown.width), height: abs(shown.height))

        do {
            try? FileManager.default.removeItem(at: destination)
            let reader = try AVAssetReader(asset: asset)
            let writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)
            writer.shouldOptimizeForNetworkUse = true
            self.reader = reader
            self.writer = writer

            // --- video
            let vOut = AVAssetReaderTrackOutput(track: vTrack, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            ])
            vOut.alwaysCopiesSampleData = false
            guard reader.canAdd(vOut) else { return finish("reader") }
            reader.add(vOut)
            let fps = vTrack.nominalFrameRate > 0 ? Double(vTrack.nominalFrameRate) : 30
            let bitRate = max(1_000_000, Int(Double(w * h) * 3.0 * min(fps, 60) / 30))
            let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: w,
                AVVideoHeightKey: h,
                AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: bitRate,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                    AVVideoMaxKeyFrameIntervalKey: 30,       // ricerca veloce nel video
                    AVVideoAllowFrameReorderingKey: false
                ]
            ])
            vIn.transform = vTrack.preferredTransform
            vIn.expectsMediaDataInRealTime = false
            guard writer.canAdd(vIn) else { return finish("writer") }
            writer.add(vIn)

            // --- audio (se c'è): AAC stereo 160 kbps
            var aOut: AVAssetReaderAudioMixOutput?
            var aIn: AVAssetWriterInput?
            if let aTrack = aTrack {
                var sr: Double = 48_000
                if let first = aTrack.formatDescriptions.first {
                    let desc = first as! CMAudioFormatDescription
                    if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee,
                       asbd.mSampleRate == 44_100 { sr = 44_100 }
                }
                let o = AVAssetReaderAudioMixOutput(audioTracks: [aTrack], audioSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: sr,
                    AVNumberOfChannelsKey: 2,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false
                ])
                let i = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: sr,
                    AVNumberOfChannelsKey: 2,
                    AVEncoderBitRateKey: VideoConverter.audioBitRate
                ])
                i.expectsMediaDataInRealTime = false
                if reader.canAdd(o) && writer.canAdd(i) {
                    reader.add(o); writer.add(i)
                    aOut = o; aIn = i
                }
            }

            guard reader.startReading() else { return finish(reader.error?.localizedDescription ?? "reader") }
            guard writer.startWriting() else { return finish(writer.error?.localizedDescription ?? "writer") }
            writer.startSession(atSourceTime: .zero)

            let group = DispatchGroup()
            let total = duration
            var lastReport = -1.0

            func pump(_ output: AVAssetReaderOutput, _ input: AVAssetWriterInput, _ queueName: String, isVideo: Bool) {
                group.enter()
                let queue = DispatchQueue(label: queueName)
                var ended = false
                input.requestMediaDataWhenReady(on: queue) {
                    while input.isReadyForMoreMediaData && !ended {
                        if self.cancelled || reader.status != .reading {
                            ended = true
                        } else if let buf = output.copyNextSampleBuffer() {
                            if isVideo {
                                let tSec = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(buf))
                                let p = min(0.99, max(0, tSec / total))
                                if p - lastReport >= 0.01 {
                                    lastReport = p
                                    DispatchQueue.main.async { progress(p) }
                                }
                            }
                            if !input.append(buf) { ended = true }
                        } else {
                            ended = true
                        }
                        if ended {
                            input.markAsFinished()
                            group.leave()
                        }
                    }
                }
            }
            pump(vOut, vIn, "arnoclick.cv.video", isVideo: true)
            if let o = aOut, let i = aIn { pump(o, i, "arnoclick.cv.audio", isVideo: false) }

            group.notify(queue: .global()) {
                if self.cancelled {
                    try? FileManager.default.removeItem(at: self.destination)
                    return finish("cancel")
                }
                if reader.status == .failed {
                    writer.cancelWriting()
                    try? FileManager.default.removeItem(at: self.destination)
                    return finish(reader.error?.localizedDescription ?? "reader")
                }
                writer.finishWriting {
                    if writer.status == .completed {
                        finish(nil)
                    } else {
                        try? FileManager.default.removeItem(at: self.destination)
                        finish(writer.error?.localizedDescription ?? "writer")
                    }
                }
            }
        } catch {
            finish(error.localizedDescription)
        }
    }
}
