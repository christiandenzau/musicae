//
// MixVersion.swift
//
// Erkennt die Mix-/Versionsangabe eines Titels (Extended, Radio Edit, Club Mix,
// Remix …). Bei Eurodance steckt diese identitätsstiftende Information fast
// immer im Klammerzusatz des Titels — ein strukturiertes Feld dafür gibt es in
// den Tags nicht. Reine Stringlogik, daher direkt gegen echte Titel testbar.
//

import Foundation

public enum MixVersionParser {
    /// Schlüsselwörter, die einen Klammerzusatz als Mix-/Versionsangabe
    /// ausweisen (und ihn von reinen Untertiteln wie „(Live in Berlin)" oder
    /// Feature-Credits trennen — wobei „live" hier bewusst mitzählt).
    private static let keywords: Set<String> = [
        "mix", "remix", "edit", "version", "dub", "instrumental", "extended",
        "radio", "club", "vocal", "original", "remaster", "remastered",
        "bootleg", "rework", "edit.", "re-edit", "reprise", "single", "album",
        "cut", "mixshow", "megamix", "maxi"
    ]

    /// Erkennt die Mix-Version im Titel.
    ///
    /// - Returns: den getrimmten Klammerzusatz, der eine Versionsangabe trägt
    ///   (z. B. „House mix", „radio edit"), oder `nil`, wenn der Titel keine
    ///   Version nennt. Bei mehreren Klammern gewinnt die hinterste — die
    ///   Versionsangabe steht konventionell am Titelende.
    public static func parse(title: String) -> String? {
        for expression in bracketedExpressions(in: title).reversed() where containsKeyword(expression) {
            let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    // MARK: - Intern

    /// Inhalte aller runden und eckigen Klammerpaare, in Reihenfolge ihres
    /// Auftretens. Verschachtelung wird flach behandelt (für Titel selten relevant).
    private static func bracketedExpressions(in title: String) -> [String] {
        var results: [String] = []
        var depth = 0
        var current = ""
        for character in title {
            switch character {
            case "(", "[":
                depth += 1
                if depth == 1 { current = "" }
            case ")", "]":
                if depth >= 1 {
                    depth -= 1
                    if depth == 0 { results.append(current) }
                }
            default:
                if depth >= 1 { current.append(character) }
            }
        }
        return results
    }

    private static func containsKeyword(_ expression: String) -> Bool {
        // In Wort-Token zerlegen, damit „mix" in „remix" nicht fälschlich ein
        // eigenständiges Treffen erzeugt — aber „remix" als Token sehr wohl.
        let tokens = expression.lowercased().split { !$0.isLetter && $0 != "-" && $0 != "." }
        for token in tokens where keywords.contains(String(token)) {
            return true
        }
        return false
    }
}
