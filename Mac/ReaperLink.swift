import Foundation

/// Collegamento con Reaper: lo script «ARNOCLICK - Apri in ARNOCLICK» scrive job.txt in una cartella condivisa
/// e apre l'app; l'app carica il brano, e con «Rimanda a Reaper» scrive i file e result.txt, che lo script importa.
enum ReaperLink {
    static var dir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let d = base.appendingPathComponent("ARNOCLICK-Reaper", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    /// Legge job.txt (righe chiave=valore). Nil se non c'è o è già stato concluso.
    static func job() -> [String: String]? {
        guard let s = try? String(contentsOf: dir.appendingPathComponent("job.txt"), encoding: .utf8) else { return nil }
        var j = [String: String]()
        for line in s.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            guard let eq = line.firstIndex(of: "=") else { continue }
            j[String(line[..<eq])] = String(line[line.index(after: eq)...])
        }
        guard let id = j["id"], !id.isEmpty, j["path"] != nil else { return nil }
        if FileManager.default.fileExists(atPath: dir.appendingPathComponent("result-\(id).txt").path) { return nil }
        return j
    }
    static func outDir(_ id: String) -> URL {
        let d = dir.appendingPathComponent(id, isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    static func safe(_ s: String) -> String {
        String(s.map { "/\\:".contains($0) ? "-" : $0 })
    }
}
