import Foundation

public struct SessionGroup: Codable, Identifiable, Equatable {
    public static let colors = ["blue", "purple", "teal", "orange", "pink", "gray"]
    public static let symbols = ["diamond", "square", "hexagon", "circle", "triangle", "folder"]
    public var id: String
    public var name: String
    public var symbol: String
    public var color: String
    public init(id: String = UUID().uuidString, name: String, symbol: String = "folder", color: String = "blue") {
        self.id = id; self.name = name; self.symbol = symbol; self.color = color
    }
}

public enum SessionMetadata {
    public static func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let scalars = value.unicodeScalars.prefix(2048).filter {
            !CharacterSet.controlCharacters.contains($0) && !CharacterSet.newlines.contains($0)
                && !(0x202A...0x202E).contains($0.value) && !(0x2066...0x2069).contains($0.value)
                && $0.value != 0x200E && $0.value != 0x200F && $0.value != 0x061C
        }
        let text = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines)
        let bounded = String(text.prefix(120))
        return bounded.isEmpty ? nil : bounded
    }
}
