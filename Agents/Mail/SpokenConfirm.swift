import Foundation

/// What a listen after the read-back means. STRICT: "send" counts only when
/// every word is from a tiny approval vocabulary, so "send it to Jordan instead"
/// (an edit) never sends. Any cancel word wins over send.
enum SpokenConfirm: Equatable {
    case send, cancel

    private static let cancelWords: Set<String> = [
        "cancel", "no", "don't", "dont", "not", "stop", "wait", "nope",
        "decline", "never", "nevermind", "forget", "discard",
    ]
    private static let sendVocabulary: Set<String> = [
        "send", "it", "yes", "yeah", "yep", "now", "please",
        "okay", "ok", "go", "ahead", "and", "sure",
    ]

    static func parse(_ heard: String?) -> SpokenConfirm? {
        let words = (heard ?? "").lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .components(separatedBy: CharacterSet.letters.union(.init(charactersIn: "'")).inverted)
            .filter { !$0.isEmpty }
        if words.contains(where: cancelWords.contains) { return .cancel }
        guard words.contains("send"), words.allSatisfy(sendVocabulary.contains) else { return nil }
        return .send
    }
}
