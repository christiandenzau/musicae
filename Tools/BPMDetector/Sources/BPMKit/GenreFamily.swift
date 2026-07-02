//
// GenreFamily.swift
//
// Stufe 0 der Genre-Neigung (Phase 5b): das getaggte Genre grob auf wenige
// Familien normalisiert (dance/rock/pop/hiphop/schlager/klassik/…) und als
// **weiches** Zusatzsignal in die Nachbar-Distanz gegeben. Kein DSP, keine
// Re-Analyse — die Tags stehen schon in der DB, hier wird nur ihre Textvielfalt
// eingedampft.
//
// Ehrlichkeitsgesetz: eine *Neigung*, kein Urteil. Fehlt das Tag, ist es
// „Unknown" oder lässt es sich keiner Familie sicher zuordnen, zählt es
// **neutral** (`nil`) — nie behaupten wir eine Familie, die wir nicht sehen.
// Reine Stringlogik, daher wie `MixVersionParser` direkt gegen echte Tags
// testbar.
//

import Foundation

/// Grobe Genre-Familie — die Textvielfalt der Genre-Tags auf wenige, für die
/// Empfehlung relevante Kategorien reduziert. Bewusst schlank gehalten und über
/// die Marker-Listen leicht erweiterbar.
public enum GenreFamily: String, Sendable, CaseIterable {
    case dance
    case hiphop
    case schlager
    case classical
    case jazzBlues
    case rock
    case pop

    /// Geordnete Prüfregeln: die erste Familie, deren Marker im (normalisierten)
    /// Genre-Text als Teilzeichenkette vorkommt, gewinnt. Die Reihenfolge kodiert
    /// die Priorität — `dance` steht bewusst zuerst (der eigentliche Trenner:
    /// „Dance, Rock, Electrónica" ist U96-Techno, kein Rock), `pop` als
    /// Auffangbecken zuletzt.
    private static let rules: [(family: GenreFamily, markers: [String])] = [
        (.dance,     ["dance", "techno", "house", "trance", "rave", "hardcore",
                      "hardstyle", "electro", "electró", "downtempo", "eurobeat"]),
        (.hiphop,    ["hip hop", "hip-hop", "hiphop", "rap", "trap"]),
        (.schlager,  ["schlager", "volksmusik", "volkstümlich"]),
        (.classical, ["klassik", "classical", "orchest", "sinfon", "symphon",
                      "opera", "baroque", "concerto"]),
        (.jazzBlues, ["jazz", "blues", "swing"]),
        (.rock,      ["rock", "grunge", "punk", "metal", "indie", "alternative"]),
        (.pop,       ["pop"]),
    ]

    /// Ordnet ein (rohes) Genre-Tag einer Familie zu.
    ///
    /// - Returns: die grobe Familie, oder `nil`, wenn das Tag leer ist, „Unknown"
    ///   meint oder zu keiner Familie passt — dann zählt es in der Distanz neutral.
    public static func classify(_ raw: String?) -> GenreFamily? {
        guard let text = raw?.lowercased(), !text.isEmpty else { return nil }
        for rule in rules where rule.markers.contains(where: text.contains) {
            return rule.family
        }
        // Kein Marker getroffen (z. B. „Unknown Genre", „Género desconocido"):
        // keine behauptete Familie, neutral.
        return nil
    }
}

extension TrackFingerprint {
    /// Die grobe Genre-Familie dieses Titels — `nil`, wenn das Tag fehlt,
    /// „Unknown" ist oder keiner Familie sicher zuzuordnen ist (dann neutral).
    public var genreFamily: GenreFamily? { GenreFamily.classify(genre) }
}
