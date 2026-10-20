import Foundation

/// Search normalization: Unicode NFC + locale-independent case folding, so that a name written in
/// decomposed form (NFD, as Foundation writes it) matches what the user types.
enum SearchKey {
    static func make(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: nil)
    }
}
