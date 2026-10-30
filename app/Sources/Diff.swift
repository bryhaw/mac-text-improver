import AppKit

enum DiffOp: Equatable {
    case same(String)
    case removed(String)
    case added(String)
}

enum TextDiff {
    private static let tokenPattern = try! NSRegularExpression(
        pattern: #"\s+|[\p{L}\p{N}]+(?:['’][\p{L}\p{N}]+)*|[^\s\p{L}\p{N}]"#)

    static func tokenize(_ text: String) -> [String] {
        let ns = text as NSString
        return tokenPattern.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range) }
    }

    /// Word-level diff (LCS) with consecutive edits grouped as removed-then-added.
    static func diff(_ old: String, _ new: String) -> [DiffOp] {
        let a = tokenize(old)
        let b = tokenize(new)

        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix,
              a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }

        let midA = Array(a[prefix..<(a.count - suffix)])
        let midB = Array(b[prefix..<(b.count - suffix)])

        var ops: [DiffOp] = a[..<prefix].map { .same($0) }
        ops += middleDiff(midA, midB)
        ops += a[(a.count - suffix)...].map { .same($0) }
        return merge(ops)
    }

    private static func middleDiff(_ a: [String], _ b: [String]) -> [DiffOp] {
        if a.isEmpty { return b.map { .added($0) } }
        if b.isEmpty { return a.map { .removed($0) } }
        let n = a.count, m = b.count
        guard n * m <= 4_000_000 else {
            return [.removed(a.joined()), .added(b.joined())]
        }
        var table = [Int32](repeating: 0, count: (n + 1) * (m + 1))
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                table[i * (m + 1) + j] = a[i] == b[j]
                    ? table[(i + 1) * (m + 1) + j + 1] + 1
                    : max(table[(i + 1) * (m + 1) + j], table[i * (m + 1) + j + 1])
            }
        }
        var ops: [DiffOp] = []
        var i = 0, j = 0
        while i < n, j < m {
            if a[i] == b[j] {
                ops.append(.same(a[i])); i += 1; j += 1
            } else if table[(i + 1) * (m + 1) + j] >= table[i * (m + 1) + j + 1] {
                ops.append(.removed(a[i])); i += 1
            } else {
                ops.append(.added(b[j])); j += 1
            }
        }
        while i < n { ops.append(.removed(a[i])); i += 1 }
        while j < m { ops.append(.added(b[j])); j += 1 }
        return ops
    }

    /// Joins runs into readable chunks; a lone space between two edits is folded into the edit.
    private static func merge(_ ops: [DiffOp]) -> [DiffOp] {
        var result: [DiffOp] = []
        var removed = "", added = ""
        func flush() {
            if !removed.isEmpty { result.append(.removed(removed)) }
            if !added.isEmpty { result.append(.added(added)) }
            removed = ""; added = ""
        }
        var index = 0
        while index < ops.count {
            switch ops[index] {
            case .removed(let s): removed += s
            case .added(let s): added += s
            case .same(let s):
                let inEdit = !removed.isEmpty || !added.isEmpty
                let nextIsEdit = index + 1 < ops.count && !ops[index + 1].isSame
                if inEdit, nextIsEdit, s.allSatisfy({ $0 == " " }) {
                    removed += s; added += s
                } else {
                    flush()
                    if case .same(let last)? = result.last {
                        result[result.count - 1] = .same(last + s)
                    } else {
                        result.append(.same(s))
                    }
                }
            }
            index += 1
        }
        flush()
        return result
    }

    static func changeCount(_ ops: [DiffOp]) -> Int {
        var count = 0
        var inChange = false
        for op in ops {
            if case .same = op { inChange = false } else if !inChange { count += 1; inChange = true }
        }
        return count
    }

    static func attributed(_ ops: [DiffOp], font: NSFont) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        let base: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
        for op in ops {
            switch op {
            case .same(let s):
                out.append(NSAttributedString(string: s, attributes: base))
            case .removed(let s):
                var attrs = base
                attrs[.foregroundColor] = NSColor.systemRed
                attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                attrs[.strikethroughColor] = NSColor.systemRed
                attrs[.backgroundColor] = NSColor.systemRed.withAlphaComponent(0.12)
                out.append(NSAttributedString(string: s, attributes: attrs))
            case .added(let s):
                var attrs = base
                attrs[.foregroundColor] = NSColor.systemGreen
                attrs[.backgroundColor] = NSColor.systemGreen.withAlphaComponent(0.16)
                attrs[.font] = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
                out.append(NSAttributedString(string: s, attributes: attrs))
            }
        }
        return out
    }
}

private extension DiffOp {
    var isSame: Bool {
        if case .same = self { return true }
        return false
    }
}
