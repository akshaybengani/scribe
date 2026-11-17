import Foundation
import Combine

// Global search across titles, folder paths and every transcript tab.
//
// Layers:
//   Fold           text normalisation (case, diacritics, punctuation) done on UTF-8 bytes
//   SearchService  pure, thread-safe index + query engine (no UI, no MainActor)
//   SearchModel    @MainActor ObservableObject for a command-palette UI
//   findInTranscript  find-bar helper for a single transcript
//
// Matching is substring based on the folded text, so "meet" finds "meeting" and
// Devanagari, Roman Hinglish and English all work the same way. There is no
// transliteration: a Roman query does not find Devanagari text, or the reverse.

// MARK: - Folding

/// Receives folded bytes from `Fold.scan`.
protocol FoldSink {
    var finished: Bool { get }
    mutating func put(_ b: UInt8, orig: Int)
    mutating func checkpoint(orig: Int, space: Bool)
}

extension FoldSink {
    var finished: Bool { false }
    mutating func checkpoint(orig: Int, space: Bool) {}
}

/// Case-, diacritic- and punctuation-insensitive folding.
///
/// Letters, digits and combining vowel signs are kept (lowercased, Latin accents removed,
/// Devanagari nukta removed, chandrabindu treated as anusvara). Apostrophes vanish
/// ("don't" becomes "dont"); every other run of whitespace, punctuation or symbols becomes
/// one space, so phrases match across commas and line breaks.
enum Fold {
    static let sep: UInt32 = 0
    static let drop: UInt32 = 1
    static let tableLimit: UInt32 = 0x3000

    static let table: [UInt32] = (0..<tableLimit).map { compute($0) }

    static let ascii: [UInt8] = (0..<128).map { UInt8(truncatingIfNeeded: compute($0)) }

    static func compute(_ v: UInt32) -> UInt32 {
        guard let s = Unicode.Scalar(v) else { return sep }
        if v < 0x80 {
            switch v {
            case 0x30...0x39, 0x61...0x7A: return v
            case 0x41...0x5A: return v + 32
            case 0x27: return drop
            default: return sep
            }
        }
        switch v {
        case 0x2018, 0x2019, 0x02BC, 0x02B9: return drop
        case 0x00AD, 0x200B...0x200F, 0x2060...0x2064, 0xFEFF: return drop
        case 0x0901: return 0x0902
        case 0x093C, 0x0951...0x0954: return drop
        case 0x00F8, 0x00D8: return 0x6F  // o
        case 0x0141, 0x0142: return 0x6C  // l
        case 0x0110, 0x0111: return 0x64  // d
        case 0x0131: return 0x69          // dotless i
        default: break
        }
        let p = s.properties
        if p.isWhitespace { return sep }
        switch p.generalCategory {
        case .nonspacingMark:
            // Latin/Greek/Cyrillic/Hebrew/Arabic marks are diacritics; Indic marks carry vowels.
            return v < 0x0900 ? drop : v
        case .spacingMark, .enclosingMark:
            return v
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .decimalNumber, .letterNumber, .otherNumber:
            var base = v
            if let f = String(s).decomposedStringWithCanonicalMapping.unicodeScalars.first { base = f.value }
            if let bs = Unicode.Scalar(base) {
                let lower = bs.properties.lowercaseMapping.unicodeScalars
                if lower.count == 1, let l = lower.first { base = l.value }
            }
            return base
        default:
            return sep
        }
    }

    /// One pass over UTF-8 bytes. `from` and `space` let a caller resume at a checkpoint.
    @inline(__always)
    static func scan<S: FoldSink>(_ src: UnsafeBufferPointer<UInt8>, from start: Int = 0, space startSpace: Bool = true,
                                  markEvery: Int = Int.max, sink: inout S) {
        let n = src.count
        var i = start
        var space = startSpace
        var nextMark = markEvery == Int.max ? Int.max : start + markEvery
        table.withUnsafeBufferPointer { tbl in
            ascii.withUnsafeBufferPointer { asc in
                while i < n && !sink.finished {
                    if i >= nextMark {
                        sink.checkpoint(orig: i, space: space)
                        nextMark = i + markEvery
                    }
                    let b = src[i]
                    if b < 0x80 {
                        let c = asc[Int(b)]
                        if c == 0 {
                            if !space { sink.put(0x20, orig: i); space = true }
                        } else if c != 1 {
                            sink.put(c, orig: i); space = false
                        }
                        i += 1
                        continue
                    }
                    var len = 2
                    var scalar: UInt32
                    if b < 0xE0 {
                        scalar = UInt32(b & 0x1F)
                    } else if b < 0xF0 {
                        len = 3; scalar = UInt32(b & 0x0F)
                    } else {
                        len = 4; scalar = UInt32(b & 0x07)
                    }
                    if i + len > n { break }
                    for k in 1..<len { scalar = (scalar << 6) | UInt32(src[i + k] & 0x3F) }
                    let m = scalar < tableLimit ? tbl[Int(scalar)] : compute(scalar)
                    if m == sep {
                        if !space { sink.put(0x20, orig: i); space = true }
                    } else if m != drop {
                        if m < 0x80 {
                            sink.put(UInt8(m), orig: i)
                        } else if m < 0x800 {
                            sink.put(UInt8(0xC0 | (m >> 6)), orig: i)
                            sink.put(UInt8(0x80 | (m & 0x3F)), orig: i)
                        } else if m < 0x10000 {
                            sink.put(UInt8(0xE0 | (m >> 12)), orig: i)
                            sink.put(UInt8(0x80 | ((m >> 6) & 0x3F)), orig: i)
                            sink.put(UInt8(0x80 | (m & 0x3F)), orig: i)
                        } else {
                            sink.put(UInt8(0xF0 | (m >> 18)), orig: i)
                            sink.put(UInt8(0x80 | ((m >> 12) & 0x3F)), orig: i)
                            sink.put(UInt8(0x80 | ((m >> 6) & 0x3F)), orig: i)
                            sink.put(UInt8(0x80 | (m & 0x3F)), orig: i)
                        }
                        space = false
                    }
                    i += len
                }
            }
        }
    }

    /// Folded bytes for a short string, without leading or trailing space.
    static func fold(_ string: String) -> [UInt8] {
        var s = string
        var sink = ByteSink()
        s.withUTF8 { scan($0, sink: &sink) }
        while sink.bytes.last == 0x20 { sink.bytes.removeLast() }
        return Array(sink.bytes)
    }
}

struct ByteSink: FoldSink {
    var bytes = ContiguousArray<UInt8>()
    mutating func put(_ b: UInt8, orig: Int) { bytes.append(b) }
}

/// Folded bytes plus the original UTF-8 offset of each one.
struct MapSink: FoldSink {
    var bytes = ContiguousArray<UInt8>()
    var origin = ContiguousArray<Int32>()
    mutating func put(_ b: UInt8, orig: Int) { bytes.append(b); origin.append(Int32(truncatingIfNeeded: orig)) }
}

/// Builds the index entry for one transcript, with a sparse folded-to-original offset map.
struct IndexSink: FoldSink {
    var bytes = ContiguousArray<UInt8>()
    var markFolded: [UInt32] = [0]
    var markOrig: [UInt32] = [0]
    var markSpace: [Bool] = [true]
    mutating func put(_ b: UInt8, orig: Int) { bytes.append(b) }
    mutating func checkpoint(orig: Int, space: Bool) {
        markFolded.append(UInt32(truncatingIfNeeded: bytes.count))
        markOrig.append(UInt32(truncatingIfNeeded: orig))
        markSpace.append(space)
    }
}

/// Finds the original offset of the folded byte at `target`, resuming from a checkpoint.
struct LocateSink: FoldSink {
    var counter: Int
    let target: Int
    var found: Int?
    var finished: Bool { found != nil }
    mutating func put(_ b: UInt8, orig: Int) {
        if counter == target { found = orig }
        counter += 1
    }
}

// MARK: - Byte search

enum Bytes {
    /// Occurrences of `needle` (non-overlapping) and how many start a word.
    static func count(in hay: UnsafeBufferPointer<UInt8>, needle: [UInt8]) -> (total: Int, wordStart: Int) {
        guard !needle.isEmpty, hay.count >= needle.count, let base = hay.baseAddress else { return (0, 0) }
        var total = 0, starts = 0
        needle.withUnsafeBufferPointer { nb in
            let np = UnsafeRawPointer(nb.baseAddress!)
            var offset = 0
            let end = hay.count
            while offset <= end - nb.count {
                guard let p = memmem(UnsafeRawPointer(base + offset), end - offset, np, nb.count) else { break }
                let pos = UnsafeRawPointer(p) - UnsafeRawPointer(base)
                total += 1
                if pos == 0 || base[pos - 1] == 0x20 { starts += 1 }
                offset = pos + nb.count
            }
        }
        return (total, starts)
    }

    static func first(in hay: UnsafeBufferPointer<UInt8>, needle: [UInt8], from: Int = 0) -> Int? {
        guard !needle.isEmpty, from >= 0, hay.count - from >= needle.count, let base = hay.baseAddress else { return nil }
        return needle.withUnsafeBufferPointer { nb in
            guard let p = memmem(UnsafeRawPointer(base + from), hay.count - from, UnsafeRawPointer(nb.baseAddress!), nb.count) else { return nil }
            return UnsafeRawPointer(p) - UnsafeRawPointer(base)
        }
    }

    static func contains(_ hay: [UInt8], _ needle: [UInt8]) -> Bool {
        hay.withUnsafeBufferPointer { first(in: $0, needle: needle) != nil }
    }
}

// MARK: - Public value types

/// One query piece after folding: a single word, or a phrase that must match contiguously.
struct SearchPattern: Equatable {
    let bytes: [UInt8]
    let isPhrase: Bool
}

/// `foo bar` needs both words anywhere; `"foo bar"` needs the exact phrase.
struct ParsedQuery: Equatable {
    let patterns: [SearchPattern]
    /// For a multi-word query without quotes: the words in order, joined. Matching it earns the phrase tier.
    let fullPhrase: [UInt8]?
    var isEmpty: Bool { patterns.isEmpty }
    var hasExplicitPhrase: Bool { patterns.contains { $0.isPhrase } }
    var strings: [String] { patterns.map { String(decoding: $0.bytes, as: UTF8.self) } }

    init(patterns: [SearchPattern], fullPhrase: [UInt8]?) {
        self.patterns = patterns
        self.fullPhrase = fullPhrase
    }

    init(_ raw: String) {
        var tokens: [(text: String, quoted: Bool)] = []
        var cur = ""
        var inQuote = false
        func flush(_ quoted: Bool) {
            if !cur.isEmpty { tokens.append((cur, quoted)); cur = "" }
        }
        for ch in raw {
            if ch == "\"" || ch == "\u{201C}" || ch == "\u{201D}" {
                flush(inQuote)
                inQuote.toggle()
            } else if !inQuote && ch.isWhitespace {
                flush(false)
            } else {
                cur.append(ch)
            }
        }
        flush(inQuote)

        var pats: [SearchPattern] = []
        var words: [[UInt8]] = []
        for t in tokens {
            let f = Fold.fold(t.text)
            if f.isEmpty { continue }
            let phrase = f.contains(0x20)
            let p = SearchPattern(bytes: f, isPhrase: phrase)
            if !pats.contains(p) { pats.append(p) }
            words.append(f)
        }
        patterns = pats
        if pats.count >= 2, !pats.contains(where: { $0.isPhrase }) {
            fullPhrase = Array(words.joined(separator: [0x20]))
        } else {
            fullPhrase = nil
        }
    }
}

/// Which tier a hit landed in. Higher always outranks lower, whatever the frequency.
enum SearchTier: Int, Comparable {
    case terms = 1, phrase = 2, title = 3
    static func < (a: SearchTier, b: SearchTier) -> Bool { a.rawValue < b.rawValue }
}

enum SearchField { case title, folder, transcript }

struct SearchHit: Identifiable, Equatable {
    let recordingID: String
    var id: String { recordingID }
    let created: Date
    let title: String
    /// Highlight ranges inside `title`.
    let titleRanges: [Range<String.Index>]
    /// Provider tab the snippet and counts come from; nil when the recording has no transcripts.
    let provider: ProviderKind?
    /// "Standups / Team A", or "Library" at the top level (matches `RecordingStore.path(of:)`).
    let folderPath: String
    /// Highlight ranges inside `folderPath`.
    let folderRanges: [Range<String.Index>]
    /// Text to show under the title. Already collapsed to one line and wrapped in "…" where cut.
    let snippet: String
    /// Highlight ranges inside `snippet`.
    let snippetRanges: [Range<String.Index>]
    /// Where the snippet came from: the transcript, or the title/folder when the transcript has no match.
    let snippetField: SearchField
    /// First (best) match in that tab's original transcript text, for "jump to match".
    let transcriptMatchRange: Range<String.Index>?
    let score: Double
    let tier: SearchTier
    /// Occurrences of the query pieces in the chosen tab plus the title.
    let matchCount: Int
    /// Every tab whose transcript contains a query piece (the chosen tab first).
    let matchingProviders: [ProviderKind]

    /// Snippet with matches marked bold, for SwiftUI `Text(AttributedString)`.
    var attributedSnippet: AttributedString {
        var a = AttributedString(snippet)
        for r in snippetRanges {
            if let ar = Range(r, in: a) { a[ar].inlinePresentationIntent = .stronglyEmphasized }
        }
        return a
    }
}

struct SearchResponse {
    /// Best first, at most `limit`.
    let hits: [SearchHit]
    /// Recordings that matched, before the limit.
    let totalMatches: Int
    let elapsed: TimeInterval
    let query: ParsedQuery
}

struct IndexStats: Equatable {
    var reused = 0
    var rebuilt = 0
    var removed = 0
    var documents = 0
    var foldedBytes = 0
}

// MARK: - Index

final class IndexedTab: @unchecked Sendable {
    let result: TranscriptResult
    let folded: ContiguousArray<UInt8>
    let markFolded: [UInt32]
    let markOrig: [UInt32]
    let markSpace: [Bool]

    var provider: ProviderKind { result.provider }

    init(_ result: TranscriptResult) {
        self.result = result
        var text = result.text
        var sink = IndexSink()
        sink.bytes.reserveCapacity(text.utf8.count + 16)
        text.withUTF8 { Fold.scan($0, markEvery: 2048, sink: &sink) }
        folded = sink.bytes
        markFolded = sink.markFolded
        markOrig = sink.markOrig
        markSpace = sink.markSpace
    }

    /// Original UTF-8 offset of the folded byte at `target` (or the text length past the end).
    func originalOffset(ofFolded target: Int) -> Int {
        var text = result.text
        return text.withUTF8 { src in
            if target >= folded.count { return src.count }
            var lo = 0, hi = markFolded.count - 1
            while lo < hi {
                let mid = (lo + hi + 1) / 2
                if Int(markFolded[mid]) <= target { lo = mid } else { hi = mid - 1 }
            }
            var sink = LocateSink(counter: Int(markFolded[lo]), target: target)
            Fold.scan(src, from: Int(markOrig[lo]), space: markSpace[lo], sink: &sink)
            return sink.found ?? src.count
        }
    }
}

final class IndexedDoc: @unchecked Sendable {
    let source: Recording
    let folderPath: String
    let titleFold: [UInt8]
    let folderFold: [UInt8]
    let tabs: [IndexedTab]

    var id: String { source.id }

    init(source: Recording, folderPath: String, folderIsRoot: Bool, tabs: [IndexedTab]) {
        self.source = source
        self.folderPath = folderPath
        titleFold = Fold.fold(source.title)
        folderFold = folderIsRoot ? [] : Fold.fold(folderPath)
        self.tabs = tabs
    }
}

final class IndexSnapshot: @unchecked Sendable {
    let docs: [IndexedDoc]
    let version: Int
    let averageTabLength: Double
    init(docs: [IndexedDoc], version: Int) {
        self.docs = docs
        self.version = version
        var total = 0, count = 0
        for d in docs { for t in d.tabs { total += t.folded.count; count += 1 } }
        averageTabLength = count == 0 ? 1 : max(1, Double(total) / Double(count))
    }
}

// MARK: - Service

/// Pure search engine. All methods are thread safe; `search` runs on the calling thread
/// (and fans out across cores), so call it off the main actor for large libraries.
final class SearchService: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot = IndexSnapshot(docs: [], version: 0)
    private var cache: (version: Int, patterns: [SearchPattern], matched: [Int])?

    init() {}

    var documentCount: Int { current().docs.count }
    var indexVersion: Int { current().version }

    private func current() -> IndexSnapshot {
        lock.lock(); defer { lock.unlock() }
        return snapshot
    }

    /// Display path for a folder id, identical to `RecordingStore.path(of:)`.
    static func folderPath(of id: String?, in folders: [String: Folder]) -> String {
        var parts: [String] = []
        var current = id
        var steps = 0
        while let c = current, let f = folders[c], steps < 200 {
            parts.insert(f.name, at: 0)
            current = f.parentID
            steps += 1
        }
        return parts.isEmpty ? "Library" : parts.joined(separator: " / ")
    }

    /// Brings the index in line with the store. Unchanged recordings and transcript tabs are reused,
    /// so editing one title or adding one transcript does not refold the library.
    @discardableResult
    func sync(recordings: [Recording], folders: [Folder]) -> IndexStats {
        let old = current()
        var oldByID: [String: IndexedDoc] = [:]
        for d in old.docs { oldByID[d.id] = d }
        let folderByID = Dictionary(folders.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var pathCache: [String?: String] = [:]
        func path(_ id: String?) -> String {
            if let p = pathCache[id] { return p }
            let p = Self.folderPath(of: id, in: folderByID)
            pathCache[id] = p
            return p
        }

        let n = recordings.count
        var docs = [IndexedDoc?](repeating: nil, count: n)
        var stats = IndexStats()
        var todo: [Int] = []
        var paths = [String](repeating: "", count: n)
        var roots = [Bool](repeating: true, count: n)
        for (i, r) in recordings.enumerated() {
            let p = path(r.folderID)
            paths[i] = p
            roots[i] = folderByID[r.folderID ?? ""] == nil
            if let o = oldByID[r.id], o.source == r, o.folderPath == p {
                docs[i] = o
                stats.reused += 1
            } else {
                todo.append(i)
            }
        }

        if !todo.isEmpty {
            docs.withUnsafeMutableBufferPointer { out in
                let outPtr = out
                DispatchQueue.concurrentPerform(iterations: todo.count) { k in
                    let i = todo[k]
                    let r = recordings[i]
                    let previous = oldByID[r.id]
                    let tabs = r.results.map { res -> IndexedTab in
                        if let t = previous?.tabs.first(where: { $0.result == res }) { return t }
                        return IndexedTab(res)
                    }
                    outPtr[i] = IndexedDoc(source: r, folderPath: paths[i], folderIsRoot: roots[i], tabs: tabs)
                }
            }
            stats.rebuilt = todo.count
        }

        let newIDs = Set(recordings.map(\.id))
        stats.removed = old.docs.filter { !newIDs.contains($0.id) }.count
        let final = docs.compactMap { $0 }
        stats.documents = final.count
        stats.foldedBytes = final.reduce(0) { $0 + $1.tabs.reduce(0) { $0 + $1.folded.count } }

        if stats.rebuilt > 0 || stats.removed > 0 || final.count != old.docs.count || !zip(final, old.docs).allSatisfy({ $0 === $1 }) {
            lock.lock()
            snapshot = IndexSnapshot(docs: final, version: old.version + 1)
            cache = nil
            lock.unlock()
        }
        return stats
    }

    // MARK: Query

    func search(_ raw: String, limit: Int = 100, snippetLength: Int = 160) -> SearchResponse {
        let started = DispatchTime.now().uptimeNanoseconds
        let q = ParsedQuery(raw)
        let snap = current()
        guard !q.isEmpty else {
            return SearchResponse(hits: [], totalMatches: 0, elapsed: 0, query: q)
        }

        // Typing "meet" then "meeting" can only narrow the previous matches.
        var candidates: [Int]?
        lock.lock()
        if let c = cache, c.version == snap.version,
           c.patterns.allSatisfy({ old in q.patterns.contains { Bytes.contains($0.bytes, old.bytes) } }) {
            candidates = c.matched
        }
        lock.unlock()
        let indexes = candidates ?? Array(0..<snap.docs.count)

        // Evaluate in chunks across cores.
        let chunk = 16
        let chunks = (indexes.count + chunk - 1) / chunk
        var partial = [[DocMatch]](repeating: [], count: chunks)
        partial.withUnsafeMutableBufferPointer { out in
            let outPtr = out
            DispatchQueue.concurrentPerform(iterations: chunks) { c in
                var local: [DocMatch] = []
                for k in (c * chunk)..<min(indexes.count, (c + 1) * chunk) {
                    if let m = Self.evaluate(snap.docs[indexes[k]], index: indexes[k], q, avgLen: snap.averageTabLength) {
                        local.append(m)
                    }
                }
                outPtr[c] = local
            }
        }
        var matches = partial.flatMap { $0 }

        lock.lock()
        cache = (snap.version, q.patterns, matches.map(\.docIndex))
        lock.unlock()

        matches.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            let a = snap.docs[$0.docIndex].source, b = snap.docs[$1.docIndex].source
            if a.created != b.created { return a.created > b.created }
            return a.id < b.id
        }
        let top = matches.prefix(max(0, limit))
        let hits = top.map { Self.makeHit($0, snap.docs[$0.docIndex], q, snippetLength: snippetLength) }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9
        return SearchResponse(hits: hits, totalMatches: matches.count, elapsed: elapsed, query: q)
    }

    // MARK: Evaluation

    struct DocMatch {
        var docIndex: Int
        var tabIndex: Int?
        var score: Double
        var tier: SearchTier
        var matchCount: Int
        var providers: [ProviderKind]
        var tabCounts: [Int]
        var titleCounts: [Int]
        var folderCounts: [Int]
    }

    static func evaluate(_ doc: IndexedDoc, index: Int, _ q: ParsedQuery, avgLen: Double) -> DocMatch? {
        let np = q.patterns.count
        var inTitle = [Int](repeating: 0, count: np)
        var inFolder = [Int](repeating: 0, count: np)
        doc.titleFold.withUnsafeBufferPointer { t in
            for i in 0..<np { inTitle[i] = Bytes.count(in: t, needle: q.patterns[i].bytes).total }
        }
        doc.folderFold.withUnsafeBufferPointer { t in
            for i in 0..<np { inFolder[i] = Bytes.count(in: t, needle: q.patterns[i].bytes).total }
        }
        let covered = (0..<np).map { inTitle[$0] > 0 || inFolder[$0] > 0 }
        let titleHits = inTitle.filter { $0 > 0 }.count
        let allInTitle = titleHits == np
        let titleTotal = inTitle.reduce(0, +)

        func score(counts: [Int], starts: [Int], tabLen: Int, phraseCount: Int, phraseOK: Bool) -> (Double, SearchTier) {
            // BM25-flavoured term frequency, word starts count in full, mid-word hits at 30%.
            let k1 = 1.2, b = 0.75
            let norm = k1 * (1 - b + b * Double(max(tabLen, 1)) / avgLen)
            var tf = 0.0
            for i in 0..<np where counts[i] > 0 {
                let w = Double(starts[i]) + 0.3 * Double(counts[i] - starts[i])
                tf += w * (k1 + 1) / (w + norm)
            }
            let tfUnit = min(1, tf / ((k1 + 1) * Double(np)))
            let titleBonus = 100 * Double(titleHits) / Double(np)
            let folderBonus = inFolder.contains { $0 > 0 } ? 50.0 : 0

            if allInTitle {
                var within = 600.0
                let joined = q.fullPhrase ?? q.patterns[0].bytes
                if np == 1 || q.fullPhrase != nil {
                    if doc.titleFold == joined { within = 900 }
                    else if doc.titleFold.starts(with: joined) { within = 800 }
                    else if Bytes.contains([0x20] + doc.titleFold, [0x20] + joined) { within = 700 }
                }
                return (3000 + min(999, within + 99 * tfUnit), .title)
            }
            if phraseOK {
                let bonus = min(300, 100 * log2(1 + Double(phraseCount)))
                return (2000 + min(999, 300 + bonus + 250 * tfUnit + titleBonus * 0.5 + folderBonus), .phrase)
            }
            return (1000 + min(999, 450 * tfUnit + titleBonus + folderBonus + (titleHits > 0 ? 50 : 0)), .terms)
        }

        if doc.tabs.isEmpty {
            guard covered.allSatisfy({ $0 }) else { return nil }
            let zeros = [Int](repeating: 0, count: np)
            let (s, tier) = score(counts: zeros, starts: zeros, tabLen: 1, phraseCount: 0, phraseOK: false)
            return DocMatch(docIndex: index, tabIndex: nil, score: s, tier: tier, matchCount: titleTotal,
                            providers: [], tabCounts: zeros, titleCounts: inTitle, folderCounts: inFolder)
        }

        var best: DocMatch?
        var matching: [(Int, ProviderKind)] = []
        let explicit = q.patterns.indices.filter { q.patterns[$0].isPhrase }
        for (ti, tab) in doc.tabs.enumerated() {
            var counts = [Int](repeating: 0, count: np)
            var starts = [Int](repeating: 0, count: np)
            var ok = true
            var phraseCount = 0
            tab.folded.withUnsafeBufferPointer { buf in
                for i in 0..<np {
                    let c = Bytes.count(in: buf, needle: q.patterns[i].bytes)
                    counts[i] = c.total
                    starts[i] = c.wordStart
                    if c.total == 0 && !covered[i] { ok = false; break }
                }
                if ok, let full = q.fullPhrase { phraseCount = Bytes.count(in: buf, needle: full).total }
            }
            guard ok else { continue }
            let any = counts.contains { $0 > 0 }
            if any { matching.append((ti, tab.provider)) }
            var phraseOK = false
            if !explicit.isEmpty {
                phraseOK = explicit.allSatisfy { counts[$0] > 0 }
                phraseCount = explicit.reduce(0) { $0 + counts[$1] }
            } else if q.fullPhrase != nil {
                phraseOK = phraseCount > 0
            }
            let (s, tier) = score(counts: counts, starts: starts, tabLen: tab.folded.count, phraseCount: phraseCount, phraseOK: phraseOK)
            if best == nil || s > best!.score {
                best = DocMatch(docIndex: index, tabIndex: ti, score: s, tier: tier,
                                matchCount: counts.reduce(0, +) + titleTotal, providers: [],
                                tabCounts: counts, titleCounts: inTitle, folderCounts: inFolder)
            }
        }
        guard var b = best else { return nil }
        // Chosen tab first, then the others that matched.
        var provs: [ProviderKind] = []
        if let bt = b.tabIndex, matching.contains(where: { $0.0 == bt }) { provs.append(doc.tabs[bt].provider) }
        for (ti, p) in matching where ti != b.tabIndex && !provs.contains(p) { provs.append(p) }
        b.providers = provs
        return b
    }

    // MARK: Hits and snippets

    static func makeHit(_ m: DocMatch, _ doc: IndexedDoc, _ q: ParsedQuery, snippetLength: Int) -> SearchHit {
        let titleRanges = highlightRanges(in: doc.source.title, patterns: q.patterns)
        let folderRanges = highlightRanges(in: doc.folderPath, patterns: doc.folderFold.isEmpty ? [] : q.patterns)
        var snippet = doc.source.title
        var snippetRanges = titleRanges
        var field = SearchField.title
        var matchRange: Range<String.Index>?
        var provider: ProviderKind?

        if let ti = m.tabIndex {
            let tab = doc.tabs[ti]
            provider = tab.provider
            if m.tabCounts.contains(where: { $0 > 0 }) {
                if let s = transcriptSnippet(tab, q, length: snippetLength) {
                    snippet = s.text; snippetRanges = s.ranges; matchRange = s.match; field = .transcript
                }
            } else if titleRanges.isEmpty && !folderRanges.isEmpty {
                snippet = doc.folderPath; snippetRanges = folderRanges; field = .folder
            }
        } else if titleRanges.isEmpty && !folderRanges.isEmpty {
            snippet = doc.folderPath; snippetRanges = folderRanges; field = .folder
        }

        return SearchHit(recordingID: doc.id, created: doc.source.created, title: doc.source.title, titleRanges: titleRanges,
                         provider: provider, folderPath: doc.folderPath, folderRanges: folderRanges,
                         snippet: snippet, snippetRanges: snippetRanges, snippetField: field,
                         transcriptMatchRange: matchRange, score: m.score, tier: m.tier, matchCount: m.matchCount,
                         matchingProviders: m.providers)
    }

    /// Highlight ranges (in `text`) for every occurrence of every pattern, overlaps merged.
    static func highlightRanges(in text: String, patterns: [SearchPattern]) -> [Range<String.Index>] {
        guard !patterns.isEmpty, !text.isEmpty else { return [] }
        var s = text
        var sink = MapSink()
        s.withUTF8 { Fold.scan($0, sink: &sink) }
        var spans: [(Int, Int)] = []   // folded byte spans
        sink.bytes.withUnsafeBufferPointer { buf in
            for p in patterns {
                var from = 0
                while let pos = Bytes.first(in: buf, needle: p.bytes, from: from) {
                    spans.append((pos, pos + p.bytes.count))
                    from = pos + p.bytes.count
                }
            }
        }
        guard !spans.isEmpty else { return [] }
        spans.sort { $0.0 < $1.0 }
        var merged: [(Int, Int)] = []
        for sp in spans {
            if let last = merged.last, sp.0 <= last.1 { merged[merged.count - 1].1 = max(last.1, sp.1) } else { merged.append(sp) }
        }
        let utf8 = text.utf8
        let total = utf8.count
        return merged.map { sp in
            let lo = Int(sink.origin[sp.0])
            let hi = sp.1 < sink.origin.count ? Int(sink.origin[sp.1]) : total
            return utf8.index(utf8.startIndex, offsetBy: lo)..<utf8.index(utf8.startIndex, offsetBy: hi)
        }
    }

    private static func transcriptSnippet(_ tab: IndexedTab, _ q: ParsedQuery, length: Int)
        -> (text: String, ranges: [Range<String.Index>], match: Range<String.Index>?)? {
        // Anchor on the phrase if there is one, otherwise the densest cluster of query pieces.
        var anchor: Int?
        var anchorLen = 0
        let window = max(40, length)    // bytes; about one snippet wide
        tab.folded.withUnsafeBufferPointer { buf in
            var phrases: [[UInt8]] = q.patterns.filter { $0.isPhrase }.map(\.bytes)
            if let f = q.fullPhrase { phrases.append(f) }
            var best: (pos: Int, len: Int)?
            for p in phrases {
                if let pos = Bytes.first(in: buf, needle: p), best == nil || pos < best!.pos { best = (pos, p.count) }
            }
            if let b = best { anchor = b.pos; anchorLen = b.len; return }

            var points: [(pos: Int, pat: Int)] = []
            for (pi, p) in q.patterns.enumerated() {
                var from = 0
                var n = 0
                while n < 40, let pos = Bytes.first(in: buf, needle: p.bytes, from: from) {
                    points.append((pos, pi)); from = pos + p.bytes.count; n += 1
                }
            }
            guard !points.isEmpty else { return }
            points.sort { $0.pos < $1.pos }
            var bestCount = 0
            var bestPos = points[0].pos
            var bestPat = points[0].pat
            var hi = 0
            for lo in points.indices {
                while hi < points.count && points[hi].pos < points[lo].pos + window { hi += 1 }
                let distinct = Set(points[lo..<hi].map(\.pat)).count
                if distinct > bestCount { bestCount = distinct; bestPos = points[lo].pos; bestPat = points[lo].pat }
                if bestCount == q.patterns.count { break }
            }
            anchor = bestPos
            anchorLen = q.patterns[bestPat].bytes.count
        }
        guard let a = anchor else { return nil }

        var text = tab.result.text
        return text.withUTF8 { src -> (String, [Range<String.Index>], Range<String.Index>?)? in
            let n = src.count
            let lead = max(0, (length / 4))
            let startFolded = max(0, a - lead)
            let endFolded = min(tab.folded.count, a + anchorLen + max(0, length - lead - anchorLen))
            var os = tab.originalOffset(ofFolded: startFolded)
            var oe = endFolded >= tab.folded.count ? n : tab.originalOffset(ofFolded: endFolded)
            let anchorStart = tab.originalOffset(ofFolded: a)
            let anchorEnd = (a + anchorLen) >= tab.folded.count ? n : tab.originalOffset(ofFolded: a + anchorLen)

            func isSpace(_ b: UInt8) -> Bool { b == 0x20 || b == 0x0A || b == 0x09 || b == 0x0D }
            // Pull the edges in to word boundaries, never into the match.
            if os > 0 { while os < anchorStart && !isSpace(src[os - 1]) { os += 1 } }
            if oe < n { while oe > anchorEnd && !isSpace(src[oe]) { oe -= 1 } }
            if os > oe { os = anchorStart; oe = anchorEnd }

            var body = String(decoding: UnsafeBufferPointer(rebasing: src[os..<oe]), as: UTF8.self)
            body = body.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            let snippet = (os > 0 ? "… " : "") + body + (oe < n ? " …" : "")
            let ranges = highlightRanges(in: snippet, patterns: q.patterns)

            let utf8 = tab.result.text.utf8
            let mr = utf8.index(utf8.startIndex, offsetBy: anchorStart)..<utf8.index(utf8.startIndex, offsetBy: max(anchorStart, anchorEnd))
            return (snippet, ranges, mr)
        }
    }
}

// MARK: - Find bar

/// Every occurrence of `query` in `text`, as ranges into `text`, in order.
/// Case-, diacritic- and punctuation-insensitive. The whole query is one phrase
/// (words in order), which is what a find bar expects. Quotes are ignored.
func findInTranscript(_ text: String, query: String) -> [Range<String.Index>] {
    let needle = Fold.fold(query.replacingOccurrences(of: "\"", with: " "))
    guard !needle.isEmpty, !text.isEmpty else { return [] }
    var s = text
    var sink = MapSink()
    s.withUTF8 { Fold.scan($0, sink: &sink) }
    let utf8 = text.utf8
    let total = utf8.count
    var out: [Range<String.Index>] = []
    sink.bytes.withUnsafeBufferPointer { buf in
        var from = 0
        while let pos = Bytes.first(in: buf, needle: needle, from: from) {
            let end = pos + needle.count
            let lo = Int(sink.origin[pos])
            let hi = end < sink.origin.count ? Int(sink.origin[end]) : total
            out.append(utf8.index(utf8.startIndex, offsetBy: lo)..<utf8.index(utf8.startIndex, offsetBy: hi))
            from = end
        }
    }
    return out
}

// MARK: - Observable model

/// Command-palette model: set `query`, read `results`. Debounces typing, searches off the main
/// thread, and keeps its index in step with the store (new recordings, edits, renames, folder moves).
@MainActor
final class SearchModel: ObservableObject {
    @Published var query: String = "" {
        didSet { if query != oldValue { queryChanged() } }
    }
    @Published private(set) var results: [SearchHit] = []
    /// True from the moment the query changes until its results land.
    @Published private(set) var isSearching = false
    /// Recordings matched before the `limit` cut.
    @Published private(set) var totalMatches = 0
    @Published private(set) var isIndexing = false
    @Published private(set) var lastElapsed: TimeInterval = 0

    var limit = 100
    var debounce: Duration = .milliseconds(80)

    let service = SearchService()
    private weak var store: RecordingStore?
    private var cancellables = Set<AnyCancellable>()
    private var searchTask: Task<Void, Never>?
    private var syncTask: Task<Void, Never>?
    private var syncPending = false
    private var generation = 0

    init(store: RecordingStore) {
        self.store = store
        Publishers.Merge(store.$recordings.map { _ in () }, store.$folders.map { _ in () })
            .sink { [weak self] in self?.scheduleSync() }
            .store(in: &cancellables)
    }

    /// Re-reads the store now (normally automatic).
    func reindex() { scheduleSync() }

    private func scheduleSync() {
        guard !syncPending else { return }
        syncPending = true
        // @Published fires before the value changes; hop once so we read the new state.
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.syncPending = false
            guard let store = self.store else { return }
            let recs = store.recordings, folders = store.folders
            let service = self.service
            let previous = self.syncTask
            self.isIndexing = true
            self.syncTask = Task { @MainActor [weak self] in
                await previous?.value
                await Task.detached(priority: .userInitiated) { _ = service.sync(recordings: recs, folders: folders) }.value
                guard let self else { return }
                if !self.syncPending { self.isIndexing = false }
                if !self.query.trimmingCharacters(in: .whitespaces).isEmpty { self.runSearch(delay: false) }
            }
        }
    }

    private func queryChanged() {
        searchTask?.cancel()
        generation += 1
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            results = []; totalMatches = 0; isSearching = false
            return
        }
        runSearch(delay: true)
    }

    private func runSearch(delay: Bool) {
        searchTask?.cancel()
        generation += 1
        let gen = generation
        let q = query, limit = limit, service = service, wait = debounce
        isSearching = true
        searchTask = Task { @MainActor [weak self] in
            if delay { try? await Task.sleep(for: wait) }
            if Task.isCancelled { return }
            // Make sure the index has caught up with the store before searching.
            if let pending = self?.syncTask { await pending.value }
            if Task.isCancelled { return }
            let response = await Task.detached(priority: .userInitiated) { service.search(q, limit: limit) }.value
            guard let self, !Task.isCancelled, gen == self.generation else { return }
            self.results = response.hits
            self.totalMatches = response.totalMatches
            self.lastElapsed = response.elapsed
            self.isSearching = false
        }
    }
}
