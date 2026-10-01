import Foundation

/// A set's Brickset note as display text. Most notes are plain and pass through untouched; ~160 carry
/// markup — only `<a href>` links and `<br>` breaks ever occur — which used to print literally
/// ("<a href='https://…'>BrickLink</a>"). Mirrors Android's `SetNote`: `<br>` is a line break (the note's
/// own line breaks are kept), `<a href>` a tappable link (http(s) only), breaks at the very start/end are
/// dropped, and a bare `<a>` — Brickset's typo for `</a>` — is repaired. Works for the Vietnamese notes
/// too (the translation kept the tags). Hand-parsed rather than run through the HTML importer, which is
/// slow, main-thread-only and restyles the text.
enum NoteMarkup {
    private static let markup = try! NSRegularExpression(pattern: #"<\s*/?\s*(a|br)\b"#, options: .caseInsensitive)
    private static let bareOpen = try! NSRegularExpression(pattern: #"<a\s*>"#, options: .caseInsensitive)
    /// A `<br>`, an opening `<a … href='…'>` (group 2 = the URL), or a closing `</a>`.
    private static let tag = try! NSRegularExpression(
        pattern: #"<br\s*/?>|<a\s[^>]*?href\s*=\s*(["'])(.*?)\1[^>]*>|</a\s*>"#,
        options: [.caseInsensitive, .dotMatchesLineSeparators]
    )

    static func hasMarkup(_ note: String) -> Bool {
        markup.firstMatch(in: note, range: NSRange(note.startIndex..., in: note)) != nil
    }

    /// One stretch of text and the link it belongs to, if any.
    struct Run: Equatable {
        var text: String
        var link: URL?
    }

    static func attributed(_ note: String) -> AttributedString {
        guard hasMarkup(note) else { return AttributedString(note) }
        var out = AttributedString()
        for run in runs(note) {
            var piece = AttributedString(run.text)
            if let link = run.link {
                piece.link = link
                piece.underlineStyle = .single
            }
            out += piece
        }
        return out
    }

    /// The note split into plain and linked runs, with breaks as "\n". Exposed for tests.
    static func runs(_ note: String) -> [Run] {
        let repaired = bareOpen.stringByReplacingMatches(
            in: note, range: NSRange(note.startIndex..., in: note), withTemplate: "</a>"
        )
        let ns = repaired as NSString
        var runs: [Run] = []
        var link: URL?
        var cursor = 0

        func append(_ text: String) {
            guard !text.isEmpty else { return }
            if let last = runs.last, last.link == link {
                runs[runs.count - 1].text += text
            } else {
                runs.append(Run(text: text, link: link))
            }
        }
        /// A line break; HTML ignores the spaces around one, so drop them on both sides.
        func lineBreak() {
            if let last = runs.last, last.link == nil {
                runs[runs.count - 1].text = String(last.text.reversed().drop(while: { $0 == " " || $0 == "\t" }).reversed())
                if runs[runs.count - 1].text.isEmpty { runs.removeLast() }
            }
            append("\n")
        }
        func text(_ raw: String) {
            // Keep the note's own line breaks; spaces right after a break are layout noise.
            let lines = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
                .components(separatedBy: "\n")
            for (i, line) in lines.enumerated() {
                if i > 0 { lineBreak() }
                let atLineStart = runs.last?.text.hasSuffix("\n") ?? true
                append(atLineStart ? String(line.drop(while: { $0 == " " || $0 == "\t" })) : line)
            }
        }

        for match in tag.matches(in: repaired, range: NSRange(location: 0, length: ns.length)) {
            text(ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
            cursor = match.range.location + match.range.length
            let token = ns.substring(with: match.range).lowercased()
            if token.hasPrefix("<br") {
                lineBreak()
            } else if token.hasPrefix("</a") {
                link = nil
            } else {
                // http(s) only: a note is untrusted catalog text, so no custom schemes.
                let href = ns.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
                let url = URL(string: href)
                link = ["http", "https"].contains(url?.scheme?.lowercased() ?? "") ? url : nil
            }
        }
        text(ns.substring(from: cursor))
        return trimmed(runs)
    }

    /// Drops whitespace and breaks at the very start and end (several notes end in "<br/>", which would
    /// leave an empty line under the note).
    private static func trimmed(_ runs: [Run]) -> [Run] {
        var runs = runs
        while let first = runs.first {
            let kept = String(first.text.drop(while: \.isWhitespace))
            if kept.isEmpty { runs.removeFirst() } else { runs[0].text = kept; break }
        }
        while let last = runs.last {
            let kept = String(last.text.reversed().drop(while: \.isWhitespace).reversed())
            if kept.isEmpty { runs.removeLast() } else { runs[runs.count - 1].text = kept; break }
        }
        return runs
    }
}
