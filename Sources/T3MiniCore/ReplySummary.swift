import Foundation

/// A two-line digest of a finished agent reply, for Ready cards:
/// one high-signal sentence for what the user needs to do, one short sentence for the situation.
/// Extracted locally from the reply text (no model call).
public struct ReplySummary: Codable, Equatable {
    /// What the agent needs from the user; nil when nothing is needed.
    public var need: String?
    /// Short statement of where things stand.
    public var situation: String?

    public init(need: String?, situation: String?) {
        self.need = need
        self.situation = situation
    }

    static let needLabels = ["need from you", "needs from you", "need from user", "action needed", "action required",
                             "your call", "decision needed", "waiting on you", "to unblock", "what i need"]
    static let skipLabels = needLabels + ["next", "now", "need", "note", "sources", "links", "files", "changes"]
    static let situationLabels = ["answer", "done", "summary", "tl;dr", "tldr", "verdict", "bottom line", "result",
                                  "status", "outcome"]

    /// - Parameter chunks: the assistant messages of the finished run, oldest first.
    public static func from(chunks: [String]) -> ReplySummary {
        let chunks = chunks.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !chunks.isEmpty else { return ReplySummary(need: nil, situation: nil) }
        // The final answer is the last chunk; earlier chunks are usually progress narration, so only fall back
        // to them when the last one has no usable sentence (e.g. it is just a "Need from you" line).
        let last = chunks.last!
        let need = need(in: last) ?? (needLabelled(last) ? nil : chunks.dropLast().reversed().lazy.compactMap { need(in: $0) }.first)
        let situation = situation(in: last) ?? chunks.dropLast().reversed().lazy.compactMap { situation(in: $0) }.first
        return ReplySummary(need: need.map(capitalized), situation: situation.map(capitalized))
    }

    static func capitalized(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }

    // MARK: need

    static func need(in text: String) -> String? {
        let lines = text.components(separatedBy: .newlines).map(clean)
        // 1. An explicit "Need from you:" style line (value on the same line or the next one).
        for (idx, line) in lines.enumerated().reversed() {
            guard let (label, value) = split(line).flatMap({ l, v in needLabels.contains(where: { l.hasPrefix($0) }) ? (l, v) : nil })
                    ?? bareLabel(line, needLabels) else { continue }
            _ = label
            var v = value
            if v.isEmpty, idx + 1 < lines.count { v = lines[idx + 1] }
            if isNothing(v) { return nil }
            return shorten(firstSentence(v), 160)
        }
        // 2. Otherwise the last question the agent asked.
        let sentences = splitSentences(lines.filter { !$0.isEmpty }.joined(separator: " "))
        if let q = sentences.last(where: { $0.hasSuffix("?") }) { return shorten(q, 160) }
        return nil
    }

    /// True when the text has an explicit need line (even one saying "nothing").
    static func needLabelled(_ text: String) -> Bool {
        text.components(separatedBy: .newlines).map(clean).contains { line in
            split(line).map { l, _ in needLabels.contains(where: { l.hasPrefix($0) }) } ?? false
        }
    }

    /// "Need from you — do X" / "Need from you do X" (no colon).
    static func bareLabel(_ line: String, _ labels: [String]) -> (String, String)? {
        let lower = line.lowercased()
        guard let l = labels.first(where: { lower.hasPrefix($0) }) else { return nil }
        let rest = line.dropFirst(l.count).trimmingCharacters(in: CharacterSet(charactersIn: " —–-:.").union(.whitespaces))
        return (l, rest)
    }

    static func isNothing(_ v: String) -> Bool {
        let l = v.lowercased()
        return l.isEmpty || l.hasPrefix("nothing") || l.hasPrefix("none") || l.hasPrefix("no action")
            || l.hasPrefix("n/a") || l.hasPrefix("nothing needed") || l == "no"
    }

    // MARK: situation

    static func situation(in text: String) -> String? {
        var takeNext = false
        var shortFallback: String?
        for raw in text.components(separatedBy: .newlines) {
            let line = clean(raw)
            guard !line.isEmpty, !isTableOrCode(raw) else { continue }
            if takeNext { return shorten(firstSentence(line), 120) }
            // "### TL;DR …" / "Summary" heading: the situation is the line under it.
            if raw.trimmingCharacters(in: .whitespaces).hasPrefix("#"),
               situationLabels.contains(where: { line.lowercased().hasPrefix($0) }) { takeNext = true; continue }
            if let (label, value) = split(line) {
                if situationLabels.contains(where: { label.hasPrefix($0) }), !value.isEmpty {
                    return shorten(firstSentence(value), 120)
                }
                if skipLabels.contains(where: { label.hasPrefix($0) }) { continue }
            }
            // A bare heading-ish line ("Results", "OK") is only a last resort.
            if line.count < 12 && !line.contains(" ") { shortFallback = shortFallback ?? line; continue }
            if raw.trimmingCharacters(in: .whitespaces).hasPrefix("#") { shortFallback = shortFallback ?? line; continue }
            return shorten(firstSentence(line), 120)
        }
        return shortFallback
    }

    // MARK: text helpers

    /// Strip markdown decoration from one line.
    static func clean(_ line: String) -> String {
        var s = line.trimmingCharacters(in: .whitespaces)
        while let f = s.first, "#>-*•+".contains(f) { s.removeFirst(); s = s.trimmingCharacters(in: .whitespaces) }
        if let r = s.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) { s.removeSubrange(r) }
        s = s.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"<[a-z0-9+.-]+://[^>]*>"#, with: "", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: #"\bhttps?://\S+"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "  ", with: " ")
        for token in ["**", "__", "`"] { s = s.replacingOccurrences(of: token, with: "") }
        return s.trimmingCharacters(in: .whitespaces)
    }

    static func isTableOrCode(_ raw: String) -> Bool {
        let t = raw.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("|") || t.hasPrefix("```")
    }

    /// "Need from you: do X" → ("need from you", "do X"). Only short labels count.
    static func split(_ line: String) -> (String, String)? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let label = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
        guard !label.isEmpty, label.count <= 24, !label.contains("http") else { return nil }
        let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        return (label, value)
    }

    static func splitSentences(_ text: String) -> [String] {
        var out: [String] = []
        var cur = ""
        let chars = Array(text)
        for (i, c) in chars.enumerated() {
            cur.append(c)
            if ".!?".contains(c), i + 1 == chars.count || chars[i + 1] == " " {
                // don't split "e.g." / "v1.2" style tokens
                let word = cur.split(separator: " ").last.map(String.init) ?? ""
                if c == ".", word.count <= 4, word.dropLast().contains(".") { continue }
                out.append(cur.trimmingCharacters(in: .whitespaces))
                cur = ""
            }
        }
        let rest = cur.trimmingCharacters(in: .whitespaces)
        if !rest.isEmpty { out.append(rest) }
        return out
    }

    static func firstSentence(_ text: String) -> String { splitSentences(text).first ?? text }

    static func shorten(_ s: String, _ max: Int) -> String {
        guard s.count > max else { return s }
        let cut = s.prefix(max - 1)
        let atWord = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
        return atWord.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces)) + "…"
    }
}
