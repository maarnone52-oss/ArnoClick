import Foundation
import CoreAudio

/// Ingressi audio del Mac (microfono interno, schede audio): elenco e scelta.
/// La pagina registra dall'ingresso predefinito del Mac, quindi per scegliere un ingresso lo si rende
/// predefinito durante l'ascolto dal vivo e alla fine si rimette quello di prima.
enum AudioInputs {
    private static var previous: AudioDeviceID?

    private static func defaultInput() -> AudioDeviceID? {
        var dev = AudioDeviceID(0), size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMaster)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev) == noErr else { return nil }
        return dev
    }

    private static func setDefaultInput(_ id: AudioDeviceID) -> Bool {
        var dev = id
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMaster)
        return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
                                          UInt32(MemoryLayout<AudioDeviceID>.size), &dev) == noErr
    }

    private static func inputChannels(_ id: AudioDeviceID) -> Int {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                              mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMaster)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let abl = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return abl.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func name(_ id: AudioDeviceID) -> String {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMaster)
        var cf: CFString = "" as CFString, size = UInt32(MemoryLayout<CFString>.size)
        let st = withUnsafeMutablePointer(to: &cf) { AudioObjectGetPropertyData(id, &addr, 0, nil, &size, $0) }
        return st == noErr ? (cf as String) : "?"
    }

    /// JSON: [{"id":..,"name":..,"ch":..,"def":true}]
    static func json() -> String {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMaster)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return "[]" }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return "[]" }
        let def = previous ?? defaultInput()
        var out: [[String: Any]] = []
        for id in ids {
            let ch = inputChannels(id)
            if ch > 0 { out.append(["id": Int(id), "name": name(id), "ch": ch, "def": id == def]) }
        }
        let data = (try? JSONSerialization.data(withJSONObject: out)) ?? Data("[]".utf8)
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    /// Rende predefinito l'ingresso scelto (ricordando quello di prima)
    static func use(_ id: Int) -> Bool {
        if previous == nil { previous = defaultInput() }
        return setDefaultInput(AudioDeviceID(id))
    }

    /// Rimette l'ingresso predefinito che c'era prima dell'ascolto dal vivo
    static func restore() {
        if let p = previous { _ = setDefaultInput(p) }
        previous = nil
    }
}
