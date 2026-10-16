import XCTest
@testable import AFKCore

final class LocalizationTests: XCTestCase {
    func testRegionalLanguagesAndFallback() {
        XCTAssertEqual(L10n.language(for: ["es-CO"]), "es")
        XCTAssertEqual(L10n.language(for: ["es-MX", "en-US"]), "es")
        XCTAssertEqual(L10n.language(for: ["en-GB", "es"]), "en")
        XCTAssertEqual(L10n.language(for: ["fr-FR"]), "en")
        XCTAssertEqual(L10n.language(for: []), "en")
    }
    func testTranslationsLoadFromPackagedResources() {
        XCTAssertEqual(L10n.text("Vincular iPhone", language: "en-US"), "Pair iPhone")
        XCTAssertEqual(L10n.text("Vincular iPhone", language: "es-CO"), "Vincular iPhone")
        XCTAssertEqual(L10n.text("Vista compartida", language: "fr"), "Shared view")
        XCTAssertEqual(L10n.text("server.invalid or expired pairing", language: "es"), "El código o la contraseña no son válidos o han vencido. Genera otra contraseña en el Mac.")
        XCTAssertEqual(String(format: L10n.text("Copiar %@", language: "en"), "Mac code"), "Copy Mac code")
        XCTAssertEqual(String(format: L10n.text("Terminal %lld", language: "es"), 12), "Terminal 12")
        XCTAssertEqual(L10n.text("my-custom-session", language: "es"), "my-custom-session")
    }
    func testCatalogsHaveMatchingKeysAndFormatArguments() throws {
        let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/AFKCore/Resources")
        func catalog(_ language: String) throws -> [String: String] {
            let data = try Data(contentsOf: resources.appendingPathComponent("\(language).lproj/Localizable.strings"))
            return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
        }
        let english = try catalog("en"), spanish = try catalog("es")
        XCTAssertEqual(Set(english.keys), Set(spanish.keys))
        XCTAssertGreaterThan(english.count, 140)
        let regex = try NSRegularExpression(pattern: "%(@|lld|d)")
        func placeholders(_ text: String) -> [String] {
            regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { (text as NSString).substring(with: $0.range) }
        }
        for (key, value) in english {
            XCTAssertFalse(value.isEmpty, key)
            XCTAssertEqual(placeholders(value), placeholders(spanish[key]!), key)
            XCTAssertEqual(L10n.text(key, language: "en"), value, key)
            XCTAssertEqual(L10n.text(key, language: "es"), spanish[key], key)
        }
    }
}
