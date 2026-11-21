import Foundation
import AVFoundation

/// Estrae la traccia audio di un video (qualsiasi formato che l'iPhone sa leggere) in un WAV 16 bit stereo.
/// Lavora a pezzi: non carica mai il video intero in memoria.
enum AudioExtract {
    enum Fail: Error { case noAudio, reader(String) }

    static func toWav(src: URL, dst: URL) throws {
        let asset = AVURLAsset(url: src)
        guard let track = asset.tracks(withMediaType: .audio).first else { throw Fail.noAudio }
        var sr: Double = 44_100
        if let first = track.formatDescriptions.first {
            let desc = first as! CMAudioFormatDescription
            if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee, asbd.mSampleRate >= 8_000 {
                sr = asbd.mSampleRate
            }
        }
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sr,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ])
        guard reader.canAdd(out) else { throw Fail.reader("output") }
        reader.add(out)
        guard reader.startReading() else { throw Fail.reader(reader.error?.localizedDescription ?? "start") }

        FileManager.default.createFile(atPath: dst.path, contents: nil)
        let fh = try FileHandle(forWritingTo: dst)
        defer { fh.closeFile() }
        fh.write(Data(count: 44))
        var bytes: UInt32 = 0
        while let sb = out.copyNextSampleBuffer() {
            if let bb = CMSampleBufferGetDataBuffer(sb) {
                let len = CMBlockBufferGetDataLength(bb)
                var d = Data(count: len)
                d.withUnsafeMutableBytes { p in _ = CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: len, destination: p.baseAddress!) }
                fh.write(d)
                bytes &+= UInt32(len)
            }
        }
        if reader.status == .failed { throw Fail.reader(reader.error?.localizedDescription ?? "read") }

        // intestazione WAV
        var h = Data()
        func s(_ x: String) { h.append(x.data(using: .ascii)!) }
        func u32(_ v: UInt32) { var x = v.littleEndian; h.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; h.append(Data(bytes: &x, count: 2)) }
        let rate = UInt32(sr.rounded())
        s("RIFF"); u32(36 &+ bytes); s("WAVE"); s("fmt "); u32(16); u16(1); u16(2); u32(rate); u32(rate * 4); u16(4); u16(16)
        s("data"); u32(bytes)
        fh.seek(toFileOffset: 0)
        fh.write(h)
    }
}
