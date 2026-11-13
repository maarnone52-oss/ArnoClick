import Foundation
import CoreAudio

/// Legge la scheda audio di uscita attuale del Mac (nome e numero di uscite)
/// e avvisa quando cambia, così la pagina può mostrare la mappa delle uscite.
enum AudioOutputs {
    private static var listening = false

    /// Nome e numero di canali di uscita del dispositivo di uscita predefinito.
    static func current() -> (name: String, channels: Int) {
        var dev = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: 0)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev) == noErr,
              dev != 0 else { return ("", 2) }

        var name = ""
        var nameRef: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        addr.mSelector = kAudioObjectPropertyName
        if AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &nameRef) == noErr, let n = nameRef {
            name = n.takeRetainedValue() as String
        }

        var channels = 0
        addr.mSelector = kAudioDevicePropertyStreamConfiguration
        addr.mScope = kAudioDevicePropertyScopeOutput
        size = 0
        if AudioObjectGetPropertyDataSize(dev, &addr, 0, nil, &size) == noErr, size > 0 {
            let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                       alignment: MemoryLayout<AudioBufferList>.alignment)
            defer { raw.deallocate() }
            if AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, raw) == noErr {
                let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
                for b in list { channels += Int(b.mNumberChannels) }
            }
        }
        return (name, max(channels, 2))
    }

    /// Numero di canali d'ingresso dell'ingresso predefinito del Mac (0 = nessuno).
    static func inputChannels() -> Int {
        var dev = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: 0)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev) == noErr,
              dev != 0 else { return 0 }
        var channels = 0
        addr.mSelector = kAudioDevicePropertyStreamConfiguration
        addr.mScope = kAudioDevicePropertyScopeInput
        size = 0
        if AudioObjectGetPropertyDataSize(dev, &addr, 0, nil, &size) == noErr, size > 0 {
            let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                       alignment: MemoryLayout<AudioBufferList>.alignment)
            defer { raw.deallocate() }
            if AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, raw) == noErr {
                let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
                for b in list { channels += Int(b.mNumberChannels) }
            }
        }
        return channels
    }

    /// Chiama `changed` sul thread principale quando cambia l'uscita predefinita del Mac.
    static func listen(_ changed: @escaping () -> Void) {
        guard !listening else { return }
        listening = true
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: 0)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main) { _, _ in
            changed()
        }
    }

    /// Testo JSON per la pagina: {"name":"…","channels":N}
    static func json() -> String {
        let c = current()
        let obj: [String: Any] = ["name": c.name, "channels": c.channels]
        if let d = try? JSONSerialization.data(withJSONObject: obj), let s = String(data: d, encoding: .utf8) { return s }
        return "{}"
    }
}
