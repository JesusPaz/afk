import Foundation

/// Mirrors edits of a native text field into the terminal line as they happen.
public enum TerminalLineEdit {
    /// Backspaces for what changed after the common prefix, then the new tail.
    /// Line editors such as zle and readline erase one code point per DEL.
    public static func bytes(from old: String, to new: String) -> Data {
        let kept = zip(old, new).prefix { $0 == $1 }.count
        var data = Data(repeating: 0x7f, count: old.dropFirst(kept).unicodeScalars.count)
        data.append(Data(String(new.dropFirst(kept)).utf8))
        return data
    }
    /// iOS smart punctuation would turn `--` and quotes into characters a shell rejects.
    public static func plain(_ text: String) -> String {
        var text = text
        for (smart, ascii) in [("“", "\""), ("”", "\""), ("„", "\""), ("‘", "'"), ("’", "'"), ("—", "--"), ("–", "-")] {
            text = text.replacingOccurrences(of: smart, with: ascii)
        }
        return text
    }
}
