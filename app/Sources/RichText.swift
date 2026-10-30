import AppKit

/// Formatted content copied alongside the plain text, so a fix can be pasted back without losing
/// images, links, or styling.
enum RichSource {
    case html(String)
    case attributed(NSAttributedString)

    var kind: String {
        switch self {
        case .html: return "html"
        case .attributed: return "rtf"
        }
    }

    /// Reads the richest usable representation of the current pasteboard contents.
    static func fromPasteboard(_ pasteboard: NSPasteboard = .general) -> RichSource? {
        let types = Set(pasteboard.types ?? [])
        let hasRTF = types.contains(.rtfd) || types.contains(.rtf)
        // Browsers and Electron apps (Outlook on the web, Slack, Teams) round-trip HTML; native text
        // views round-trip RTF, which also carries inline images as attachments.
        let isWeb = types.contains(NSPasteboard.PasteboardType("com.apple.webarchive"))
            || types.contains { $0.rawValue.hasPrefix("org.chromium.") }
        if types.contains(.html), isWeb || !hasRTF, let html = pasteboard.string(forType: .html), !html.isEmpty {
            return .html(html)
        }
        if let data = pasteboard.data(forType: .rtfd), let text = NSAttributedString(rtfd: data, documentAttributes: nil) {
            return .attributed(text)
        }
        if let data = pasteboard.data(forType: .rtf), let text = NSAttributedString(rtf: data, documentAttributes: nil) {
            return .attributed(text)
        }
        return nil
    }
}

/// The formatted version of a fix, ready to put on the pasteboard.
enum RichPayload {
    case html(String)
    case attributed(NSAttributedString)

    func write(to pasteboard: NSPasteboard) {
        switch self {
        case .html(let html):
            pasteboard.setString(html, forType: .html)
        case .attributed(let text):
            let range = NSRange(location: 0, length: text.length)
            if text.containsAttachments, let data = text.rtfd(from: range, documentAttributes: [:]) {
                pasteboard.setData(data, forType: .rtfd)
            }
            if let data = text.rtf(from: range, documentAttributes: [:]) {
                pasteboard.setData(data, forType: .rtf)
            }
        }
    }
}

/// Applies the word-level differences between `original` and `corrected` to formatted content,
/// leaving markup, images, links, and layout exactly as they were.
enum RichPatch {
    /// Returns nil when any fix can't be placed with certainty; callers then paste plain text.
    static func payload(for source: RichSource?, original: String, corrected: String) -> RichPayload? {
        switch source {
        case .html(let html):
            return patchHTML(html, original: original, corrected: corrected).map(RichPayload.html)
        case .attributed(let text):
            return patchAttributed(text, original: original, corrected: corrected).map(RichPayload.attributed)
        case nil:
            return nil
        }
    }

    // MARK: Planning

    struct Word {
        let text: String
        let range: NSRange
    }

    static func words(in text: String) -> [Word] {
        let ns = text as NSString
        return TextDiff.tokenRanges(text).compactMap { range in
            let token = ns.substring(with: range)
            return TextDiff.isLayout(token) ? nil : Word(text: token, range: range)
        }
    }

    /// An edit expressed against the target document's words.
    enum Edit {
        /// Replaces words `first...last`; when `fromEndOf` is set, the range starts at the end of that
        /// earlier word so the spacing before the edit changes too (e.g. "week & the" -> "week, and").
        case replace(first: Int, last: Int, text: String, fromEndOf: Int? = nil, gap: String = "")
        case insertAfter(Int, String)
        case insertBefore(Int, String)
    }

    static func plan(original: String, corrected: String, target: [String]) -> [Edit]? {
        let old = words(in: original), new = words(in: corrected)
        let oldNS = original as NSString, newNS = corrected as NSString
        guard let toTargetPairs = lcsPairs(old.map(\.text), target),
              let pairs = lcsPairs(old.map(\.text), new.map(\.text)) else { return nil }
        var toTarget = [Int?](repeating: nil, count: old.count)
        for (i, t) in toTargetPairs { toTarget[i] = t }

        func newText(from start: Int, to end: Int) -> String {
            newNS.substring(with: NSRange(location: start, length: end - start))
        }
        func flattenLines(_ s: String) -> String {
            s.replacingOccurrences(of: #"[\s\p{Cf}]*[\n\r\x{2028}\x{2029}][\s\p{Cf}]*"#, with: " ", options: .regularExpression)
        }
        func hasNewline(_ s: String) -> Bool {
            s.unicodeScalars.contains { "\n\r\u{2028}\u{2029}".unicodeScalars.contains($0) }
        }

        var edits: [Edit] = []
        var prevI = -1, prevK = -1
        for (i, k) in pairs + [(old.count, new.count)] {
            defer { prevI = i; prevK = k }
            let removed = (prevI + 1)..<i, added = (prevK + 1)..<k
            if removed.isEmpty && added.isEmpty { continue }

            if removed.isEmpty {
                let firstAdded = new[added.lowerBound], lastAdded = new[added.upperBound - 1]
                let gapBefore = prevK >= 0
                    ? newText(from: NSMaxRange(new[prevK].range), to: firstAdded.range.location) : "\n"
                if prevI >= 0, !hasNewline(gapBefore) || i == old.count {
                    guard let t = toTarget[prevI] else { return nil }
                    edits.append(.insertAfter(t, flattenLines(newText(from: NSMaxRange(new[prevK].range), to: NSMaxRange(lastAdded.range)))))
                } else if i < old.count {
                    guard let t = toTarget[i] else { return nil }
                    edits.append(.insertBefore(t, flattenLines(newText(from: firstAdded.range.location, to: new[k].range.location))))
                } else {
                    return nil
                }
                continue
            }

            let targets = removed.map { toTarget[$0] }
            guard let firstTarget = targets.first ?? nil,
                  targets.enumerated().allSatisfy({ $0.element == firstTarget + $0.offset }) else { return nil }

            // Keep each original line's fix on that line, so text never moves between paragraphs.
            var segments: [Range<Int>] = []
            var segmentStart = removed.lowerBound
            for i in removed.dropFirst() {
                let gap = oldNS.substring(with: NSRange(location: NSMaxRange(old[i - 1].range),
                                                        length: old[i].range.location - NSMaxRange(old[i - 1].range)))
                if hasNewline(gap) { segments.append(segmentStart..<i); segmentStart = i }
            }
            segments.append(segmentStart..<removed.upperBound)

            // If the fix changes the spacing before its first word, include that gap in the edit.
            var leadingFrom: Int?
            if prevI >= 0, prevK >= 0, let previousTarget = toTarget[prevI], previousTarget == firstTarget - 1, !added.isEmpty {
                let oldGap = oldNS.substring(with: NSRange(location: NSMaxRange(old[prevI].range),
                                                           length: old[removed.lowerBound].range.location - NSMaxRange(old[prevI].range)))
                let newGap = newText(from: NSMaxRange(new[prevK].range), to: new[added.lowerBound].range.location)
                if oldGap != newGap, !hasNewline(oldGap), !hasNewline(newGap) { leadingFrom = previousTarget }
            }

            var consumed = 0, addedCursor = added.lowerBound
            for segment in segments {
                consumed += segment.count
                let share = segment == segments.last
                    ? added.upperBound
                    : added.lowerBound + Int((Double(added.count) * Double(consumed) / Double(removed.count)).rounded())
                let first = firstTarget + (segment.lowerBound - removed.lowerBound)
                let last = first + segment.count - 1
                let text = addedCursor < share
                    ? flattenLines(newText(from: new[addedCursor].range.location, to: NSMaxRange(new[share - 1].range)))
                    : ""
                if segment == segments.first, let leadingFrom, !text.isEmpty {
                    let gap = newText(from: NSMaxRange(new[prevK].range), to: new[addedCursor].range.location)
                    edits.append(.replace(first: first, last: last, text: text, fromEndOf: leadingFrom, gap: gap))
                } else {
                    edits.append(.replace(first: first, last: last, text: text))
                }
                addedCursor = max(addedCursor, share)
            }
        }
        return edits
    }

    /// Longest-common-subsequence index pairs, or nil if the inputs are too large to align.
    static func lcsPairs(_ a: [String], _ b: [String]) -> [(Int, Int)]? {
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix,
              a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        let n = a.count - prefix - suffix, m = b.count - prefix - suffix
        guard n * m <= 4_000_000 else { return nil }

        var pairs = (0..<prefix).map { ($0, $0) }
        if n > 0, m > 0 {
            var table = [Int32](repeating: 0, count: (n + 1) * (m + 1))
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    table[i * (m + 1) + j] = a[prefix + i] == b[prefix + j]
                        ? table[(i + 1) * (m + 1) + j + 1] + 1
                        : max(table[(i + 1) * (m + 1) + j], table[i * (m + 1) + j + 1])
                }
            }
            var i = 0, j = 0
            while i < n, j < m {
                if a[prefix + i] == b[prefix + j] {
                    pairs.append((prefix + i, prefix + j)); i += 1; j += 1
                } else if table[(i + 1) * (m + 1) + j] >= table[i * (m + 1) + j + 1] {
                    i += 1
                } else {
                    j += 1
                }
            }
        }
        pairs += (0..<suffix).map { (a.count - suffix + $0, b.count - suffix + $0) }
        return pairs
    }

    /// Converts edits into (range, replacement, insertAfterWord) against the target's own word ranges.
    private static func resolve(_ edits: [Edit], words: [Word], in text: NSString) -> [(NSRange, String, Bool)] {
        edits.map { edit in
            switch edit {
            case .replace(let first, let last, var replacement, let fromEndOf, let newGap):
                var start = words[first].range.location
                if let previous = fromEndOf {
                    let gapStart = NSMaxRange(words[previous].range)
                    let gap = text.substring(with: NSRange(location: gapStart, length: start - gapStart))
                    // Only absorb ordinary spaces; never line breaks or images.
                    if gap.unicodeScalars.allSatisfy({ $0 == " " || $0 == "\u{00A0}" || $0 == "\t" }) {
                        start = gapStart
                        replacement = newGap + replacement
                    }
                }
                var range = NSRange(location: start, length: NSMaxRange(words[last].range) - start)
                if replacement.isEmpty { range = widenedDeletion(range, in: text) }
                return (range, replacement, false)
            case .insertAfter(let index, let insertion):
                return (NSRange(location: NSMaxRange(words[index].range), length: 0), insertion, true)
            case .insertBefore(let index, let insertion):
                return (NSRange(location: words[index].range.location, length: 0), insertion, false)
            }
        }
        .sorted { $0.0.location > $1.0.location }
    }

    /// Deleting a word also removes one neighboring space so no double space is left behind.
    private static func widenedDeletion(_ range: NSRange, in text: NSString) -> NSRange {
        guard range.length > 0,
              let first = text.substring(with: range).unicodeScalars.first,
              CharacterSet.alphanumerics.contains(first) else { return range }
        let spaces: Set<unichar> = [0x20, 0xA0]
        if range.location > 0, spaces.contains(text.character(at: range.location - 1)) {
            return NSRange(location: range.location - 1, length: range.length + 1)
        }
        if NSMaxRange(range) < text.length, spaces.contains(text.character(at: NSMaxRange(range))) {
            return NSRange(location: range.location, length: range.length + 1)
        }
        return range
    }

    /// When the target's words are exactly the original's, the patched words must be exactly the fix.
    private static func verified(target: [String], patched: String, original: String, corrected: String) -> Bool {
        guard target == words(in: original).map(\.text) else { return true }
        return words(in: patched).map(\.text) == words(in: corrected).map(\.text)
    }

    // MARK: Attributed text (RTF / RTFD)

    static func patchAttributed(_ source: NSAttributedString, original: String, corrected: String) -> NSAttributedString? {
        let text = NSMutableAttributedString(attributedString: source)
        let targetWords = words(in: text.string)
        guard let edits = plan(original: original, corrected: corrected, target: targetWords.map(\.text)) else { return nil }
        for (range, replacement, _) in resolve(edits, words: targetWords, in: text.string as NSString) {
            // Inserted text inherits the attributes of the neighboring character, so links and styles carry over.
            text.replaceCharacters(in: range, with: replacement)
        }
        guard verified(target: targetWords.map(\.text), patched: text.string, original: original, corrected: corrected),
              attachmentCount(text) == attachmentCount(source) else { return nil }
        return text
    }

    private static func attachmentCount(_ text: NSAttributedString) -> Int {
        var count = 0
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            if value != nil { count += 1 }
        }
        return count
    }

    // MARK: HTML

    private struct Piece {
        var raw: String
        var text: String?      // decoded text for text nodes; nil for markup
        var separator: String  // what markup contributes to the visible text
        var modified = false
    }

    static func patchHTML(_ html: String, original: String, corrected: String) -> String? {
        var pieces = parseHTML(html)
        let (flat, spans) = flatten(pieces)
        let flatNS = flat as NSString
        let targetWords = words(in: flat)
        guard !targetWords.isEmpty,
              let edits = plan(original: original, corrected: corrected, target: targetWords.map(\.text)) else { return nil }

        for (range, replacement, afterWord) in resolve(edits, words: targetWords, in: flatNS) {
            guard apply(range, replacement, afterWord: afterWord, to: &pieces, spans: spans) else { return nil }
        }
        let patchedFlat = flatten(pieces).0
        guard verified(target: targetWords.map(\.text), patched: patchedFlat, original: original, corrected: corrected) else { return nil }
        return pieces.map { $0.modified ? escapeHTML($0.text ?? "") : $0.raw }.joined()
    }

    /// Replaces `range` of the flattened text inside the text nodes it covers.
    private static func apply(_ range: NSRange, _ replacement: String, afterWord: Bool,
                              to pieces: inout [Piece], spans: [(piece: Int, start: Int, length: Int)]) -> Bool {
        let lo = range.location, hi = NSMaxRange(range)
        if range.length == 0 {
            let span = spans.first { afterWord ? ($0.start < lo && lo <= $0.start + $0.length)
                                               : ($0.start <= lo && lo < $0.start + $0.length) }
            guard let span else { return false }
            let text = pieces[span.piece].text! as NSString
            pieces[span.piece].text = text.replacingCharacters(in: NSRange(location: lo - span.start, length: 0), with: replacement)
            pieces[span.piece].modified = true
            return true
        }
        var placed = false
        for span in spans {
            let start = max(lo, span.start), end = min(hi, span.start + span.length)
            guard start < end else { continue }
            let text = pieces[span.piece].text! as NSString
            let local = NSRange(location: start - span.start, length: end - start)
            pieces[span.piece].text = text.replacingCharacters(in: local, with: placed ? "" : replacement)
            pieces[span.piece].modified = true
            placed = true
        }
        return placed
    }

    /// Visible text of the document plus where each text node sits in it (UTF-16 offsets).
    private static func flatten(_ pieces: [Piece]) -> (String, [(piece: Int, start: Int, length: Int)]) {
        var flat = ""
        var offset = 0
        var spans: [(piece: Int, start: Int, length: Int)] = []
        for (index, piece) in pieces.enumerated() {
            let part = piece.text ?? piece.separator
            let length = (part as NSString).length
            if piece.text != nil { spans.append((index, offset, length)) }
            flat += part
            offset += length
        }
        return (flat, spans)
    }

    private static let blockTags: Set<String> = [
        "br", "p", "div", "li", "ul", "ol", "tr", "td", "th", "table", "tbody", "thead", "h1", "h2", "h3",
        "h4", "h5", "h6", "blockquote", "pre", "hr", "section", "article", "header", "footer", "dd", "dt",
    ]
    private static let opaqueTags: Set<String> = ["style", "script", "title", "head", "template", "xml"]

    private static func parseHTML(_ html: String) -> [Piece] {
        var pieces: [Piece] = []
        var index = html.startIndex
        func markup(_ end: String.Index, separator: String = "") {
            pieces.append(Piece(raw: String(html[index..<end]), text: nil, separator: separator))
            index = end
        }
        while index < html.endIndex {
            if html[index] == "<" {
                let rest = html[index...]
                if rest.hasPrefix("<!--") {
                    let end = rest.range(of: "-->")?.upperBound ?? html.endIndex
                    markup(end); continue
                }
                let next = html.index(after: index)
                if next < html.endIndex, html[next].isLetter || "/!?".contains(html[next]) {
                    let end = tagEnd(html, from: index)
                    let tag = String(html[index..<end])
                    let name = tagName(tag)
                    if opaqueTags.contains(name), !tag.hasPrefix("</"),
                       let close = html.range(of: "</\(name)", options: [.caseInsensitive], range: end..<html.endIndex) {
                        markup(tagEnd(html, from: close.lowerBound)); continue
                    }
                    markup(end, separator: blockTags.contains(name) ? "\n" : (name == "img" ? "\u{FFFC}" : ""))
                    continue
                }
            }
            let end = html[html.index(after: index)...].firstIndex(of: "<") ?? html.endIndex
            let raw = String(html[index..<end])
            pieces.append(Piece(raw: raw, text: decodeEntities(raw), separator: ""))
            index = end
        }
        return pieces
    }

    private static func tagEnd(_ html: String, from start: String.Index) -> String.Index {
        var quote: Character?
        var index = html.index(after: start)
        while index < html.endIndex {
            let c = html[index]
            if let q = quote { if c == q { quote = nil } }
            else if c == "\"" || c == "'" { quote = c }
            else if c == ">" { return html.index(after: index) }
            index = html.index(after: index)
        }
        return html.endIndex
    }

    private static func tagName(_ tag: String) -> String {
        String(tag.drop { $0 == "<" || $0 == "/" }.prefix { $0.isLetter || $0.isNumber }).lowercased()
    }

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
        "rsquo": "\u{2019}", "lsquo": "\u{2018}", "rdquo": "\u{201D}", "ldquo": "\u{201C}",
        "mdash": "\u{2014}", "ndash": "\u{2013}", "hellip": "\u{2026}", "bull": "\u{2022}",
        "middot": "\u{00B7}", "copy": "\u{00A9}", "reg": "\u{00AE}", "trade": "\u{2122}",
        "zwj": "\u{200D}", "zwnj": "\u{200C}", "shy": "\u{00AD}", "ensp": "\u{2002}", "emsp": "\u{2003}", "thinsp": "\u{2009}",
    ]
    private static let entityPattern = try! NSRegularExpression(pattern: "&(#[0-9]+|#[xX][0-9a-fA-F]+|[A-Za-z]+);")

    static func decodeEntities(_ raw: String) -> String {
        guard raw.contains("&") else { return raw }
        let ns = raw as NSString
        var out = ""
        var last = 0
        for match in entityPattern.matches(in: raw, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            let body = ns.substring(with: match.range(at: 1))
            var decoded: String?
            if body.hasPrefix("#x") || body.hasPrefix("#X") {
                decoded = UInt32(body.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else if body.hasPrefix("#") {
                decoded = UInt32(body.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else {
                decoded = namedEntities[body]
            }
            out += decoded ?? ns.substring(with: match.range)
            last = NSMaxRange(match.range)
        }
        out += ns.substring(from: last)
        return out
    }

    static func escapeHTML(_ text: String) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\u{00A0}": out += "&nbsp;"
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }
}
