import Foundation

struct TextNormalizer {
    func normalize(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: "[\\t ]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    func meaningfulChunks(from text: String) -> [String] {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 4 }

        var chunks = [normalize(text)]
        chunks.append(contentsOf: lines.map(normalize))

        if lines.count > 1 {
            chunks.append(contentsOf: zip(lines, lines.dropFirst()).map {
                normalize("\($0.0) \($0.1)")
            })
        }

        var seen = Set<String>()
        return chunks.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
