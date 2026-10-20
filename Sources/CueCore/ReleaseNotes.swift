import Foundation

/// The update window's notes cover the last few versions, each under a "Version 0.3.4" heading,
/// newest first. Someone who skipped versions sees all they missed; the ones they have are cut.
public enum ReleaseNotes {
    /// The notes for versions newer than `installed`, or nil to show them as they are.
    /// Headings are found anywhere in the text, since rendered Markdown may not keep its line breaks.
    public static func newer(than installed: String, in notes: NSAttributedString) -> NSAttributedString? {
        let text = notes.string
        let headings = text.ranges(of: #/Version \d+(?:\.\d+)+/#)
        guard let cut = headings.first(where: { range in
            let version = text[range].dropFirst("Version ".count)
            return !isNewer(String(version), than: installed)
        }), cut.lowerBound > text.startIndex else { return nil }
        return notes.attributedSubstring(from: NSRange(text.startIndex..<cut.lowerBound, in: text))
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) where (i < x.count ? x[i] : 0) != (i < y.count ? y[i] : 0) {
            return (i < x.count ? x[i] : 0) > (i < y.count ? y[i] : 0)
        }
        return false
    }
}
