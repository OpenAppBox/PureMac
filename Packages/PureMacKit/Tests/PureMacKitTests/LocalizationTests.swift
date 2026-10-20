import Foundation
import Testing

/// Every user-facing string ships in English and in every other language PureMac supports. These
/// checks read the source string catalogs, so adding a language means translating all of it, and an
/// untranslated string or a translation that changes its format specifiers fails the tests.
@Suite("Localization")
struct LocalizationTests {
    static let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let catalogs = [
        packageRoot.appendingPathComponent("Sources/PureMacKit/Resources/Localizable.xcstrings"),
        packageRoot.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("PureMac/Resources/Localizable.xcstrings"),
        packageRoot.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("PureMac/Resources/InfoPlist.xcstrings"),
    ]

    /// CLDR plural categories each language must provide when a string varies by count.
    static let pluralCategories: [String: Set<String>] = [
        "ar": ["zero", "one", "two", "few", "many", "other"],
        "ru": ["one", "few", "many", "other"], "pl": ["one", "few", "many", "other"],
        "fr": ["one", "many", "other"], "pt-BR": ["one", "many", "other"], "it": ["one", "many", "other"],
        "ja": ["other"], "ko": ["other"], "zh-Hans": ["other"], "zh-Hant": ["other"],
    ]

    static func strings(_ url: URL) throws -> [String: [String: Any]] {
        let data = try Data(contentsOf: url)
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(root["strings"] as? [String: [String: Any]])
    }

    /// Every text of a translation: its value, or each of its plural forms. Empty when untranslated.
    static func translations(_ entry: [String: Any], _ language: String) -> [String] {
        let localizations = entry["localizations"] as? [String: Any]
        guard let localization = localizations?[language] as? [String: Any] else { return [] }
        if let value = (localization["stringUnit"] as? [String: Any])?["value"] as? String { return [value] }
        let plural = (localization["variations"] as? [String: Any])?["plural"] as? [String: Any] ?? [:]
        return plural.values.compactMap { (($0 as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String }
    }

    static func pluralForms(_ entry: [String: Any], _ language: String) -> Set<String>? {
        let localization = (entry["localizations"] as? [String: Any])?[language] as? [String: Any]
        return ((localization?["variations"] as? [String: Any])?["plural"] as? [String: Any]).map { Set($0.keys) }
    }

    /// Languages translated anywhere in the app or engine catalogs (English is the source).
    static func languages() throws -> Set<String> {
        var found: Set<String> = ["tr"]
        for url in catalogs {
            for entry in try strings(url).values {
                found.formUnion((entry["localizations"] as? [String: Any])?.keys.filter { $0 != "en" } ?? [])
            }
        }
        return found
    }

    /// Format specifier types in argument order. Positional specifiers (`%2$@`) are placed at their
    /// index, so a translation may reorder arguments only that way; reordering `%@` and `%lld`
    /// without positions would read the wrong type at run time.
    static func specifiers(_ s: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: "%(?:(\\d+)\\$)?(lld|ld|d|@|f)")
        let found = regex.matches(in: s, range: NSRange(s.startIndex..., in: s)).map { match in
            (position: Range(match.range(at: 1), in: s).flatMap { Int(s[$0]) }, type: String(s[Range(match.range(at: 2), in: s)!]))
        }
        guard found.contains(where: { $0.position != nil }) else { return found.map(\.type) }
        return found.sorted { ($0.position ?? 0) < ($1.position ?? 0) }.map(\.type)
    }

    @Test(arguments: catalogs)
    func everyStringIsTranslatedIntoEverySupportedLanguage(_ url: URL) throws {
        let entries = try Self.strings(url)
        #expect(!entries.isEmpty)
        for language in try Self.languages().sorted() {
            let missing = entries.filter { key, entry in
                !key.trimmingCharacters(in: .whitespaces).isEmpty && Self.translations(entry, language).isEmpty
            }.keys.sorted()
            #expect(missing.isEmpty, "Untranslated into \(language) in \(url.lastPathComponent): \(missing.prefix(10))")
        }
    }

    @Test(arguments: catalogs)
    func translationsKeepTheirFormatSpecifiers(_ url: URL) throws {
        let languages = try Self.languages()
        for (key, entry) in try Self.strings(url) {
            for language in languages {
                for text in Self.translations(entry, language) {
                    #expect(Self.specifiers(key) == Self.specifiers(text), "Specifiers differ for “\(key)” → \(language) “\(text)”")
                }
            }
        }
    }

    /// Plural forms only on strings with a single count, with every category the language uses.
    @Test(arguments: catalogs)
    func pluralFormsAreComplete(_ url: URL) throws {
        for (key, entry) in try Self.strings(url) {
            for language in try Self.languages() {
                guard let forms = Self.pluralForms(entry, language) else { continue }
                #expect(Self.specifiers(key) == ["lld"], "Plural forms on “\(key)” (\(language)), which has no single count")
                #expect(forms == (Self.pluralCategories[language] ?? ["one", "other"]), "Plural categories for “\(key)” (\(language)): \(forms.sorted())")
            }
        }
    }

    @Test func selectionCountsUseCompletePluralPhrases() throws {
        let appStrings = try Self.strings(Self.catalogs[1])
        for key in ["%lld items selected", "%lld apps selected", "%lld copies selected"] {
            let entry = try #require(appStrings[key])
            for language in try Self.languages().union(["en"]) {
                #expect(Self.pluralForms(entry, language) == (Self.pluralCategories[language] ?? ["one", "other"]),
                        "Selection summary needs full plural forms for \(language): \(key)")
            }
        }
    }

    @Test func everyCleanupRuleTextIsInTheCatalog() throws {
        let rulesURL = Self.packageRoot.appendingPathComponent("Sources/PureMacKit/Resources/CleanupRules.json")
        let root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: rulesURL)) as? [String: Any])
        let rules = try #require(root["rules"] as? [[String: Any]])
        let entries = try Self.strings(Self.catalogs[0])
        for rule in rules {
            for field in ["title", "description", "regenerationImpact", "evidence"] {
                guard let text = rule[field] as? String else { continue }
                #expect(entries[text] != nil, "Rule \(rule["id"] ?? "?") \(field) is not in the catalog")
            }
        }
    }
}
