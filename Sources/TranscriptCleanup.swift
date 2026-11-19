import Foundation

/// Removes whisper's hallucinated lines from local transcripts.
///
/// On long Hinglish calls whisper sometimes emits a line of mixed Korean, Japanese, Chinese, Arabic or
/// Cyrillic fragments, for example "여人向に向向僕の皆來権のcia途光 작업陽に 걸 هذا mucho劃我". Scribe's calls are
/// Hindi and English, so real text is only ever Latin (English, romanised Hindi) or Devanagari.
///
///   - A line where at least `dropShare` of the letters are in another script is dropped whole.
///   - In any other line, stray letters from another script and broken characters (U+FFFD) are removed.
enum TranscriptCleanup {
    static let dropShare = 0.25

    /// Latin, Latin accents and combining marks, and Devanagari (with its extended block).
    static func isAllowedLetter(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x0000...0x024F, 0x0300...0x036F, 0x1E00...0x1EFF: return true   // Latin
        case 0x0900...0x097F, 0xA8E0...0xA8FF: return true                    // Devanagari
        default: return false
        }
    }

    /// True for a letter of a script a Hindi or English call never uses.
    static func isForeignLetter(_ s: Unicode.Scalar) -> Bool {
        s.properties.isAlphabetic && !isAllowedLetter(s)
    }

    /// The line without hallucinated text, or nil when the whole line should go.
    static func clean(line: String) -> String? {
        var allowed = 0, foreign = 0
        for s in line.unicodeScalars where s.properties.isAlphabetic {
            if isAllowedLetter(s) { allowed += 1 } else { foreign += 1 }
        }
        guard foreign > 0 || line.unicodeScalars.contains("\u{FFFD}") else { return line }
        let letters = allowed + foreign
        if letters > 0, Double(foreign) / Double(letters) >= dropShare { return nil }
        var kept = String.UnicodeScalarView()
        for s in line.unicodeScalars where s != "\u{FFFD}" && !isForeignLetter(s) { kept.append(s) }
        let out = String(kept).split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return out.trimmingCharacters(in: .whitespaces).isEmpty ? nil : out
    }

    /// Cleans every line. Returns the text and how many lines were dropped.
    static func clean(_ text: String) -> (text: String, dropped: Int) {
        var out: [String] = []
        var dropped = 0
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if let line = clean(line: String(raw)) { out.append(line) } else { dropped += 1 }
        }
        return (out.joined(separator: "\n"), dropped)
    }
}
