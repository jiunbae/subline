import Foundation

/// On-device romanization for lyrics and captions: Korean (Revised Romanization with the common
/// sound-change rules), Japanese (readings from the system tokenizer, Hepburn-style) and Chinese
/// (Hanyu Pinyin with tone marks).
public enum Romanizer {
    public enum Script: Sendable { case korean, japanese, chinese }

    /// The script a line needs romanizing for, if any. `japanese` hints that Han characters
    /// without kana are Japanese (whole-song language), not Chinese.
    public static func script(of s: String, japanese: Bool = false) -> Script? {
        var han = false
        for u in s.unicodeScalars {
            switch u.value {
            case 0xAC00...0xD7A3, 0x1100...0x11FF, 0x3130...0x318F: return .korean
            case 0x3040...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9F: return .japanese
            case 0x4E00...0x9FFF, 0x3400...0x4DBF: han = true
            default: break
            }
        }
        return han ? (japanese ? .japanese : .chinese) : nil
    }

    /// Romanized text, or nil when the line has nothing to romanize.
    public static func romanize(_ s: String, japanese: Bool = false) -> String? {
        guard let sc = script(of: s, japanese: japanese) else { return nil }
        let out: String
        switch sc {
        case .korean: out = korean(s)
        case .japanese: out = japaneseReading(s)
        case .chinese: out = pinyin(s)
        }
        let t = out.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        return t.isEmpty || t == s ? nil : t
    }

    // MARK: Korean (Revised Romanization of Korean)

    private static let initials = ["g", "kk", "n", "d", "tt", "r", "m", "b", "pp", "s", "ss", "", "j", "jj", "ch", "k", "t", "p", "h"]
    private static let vowels = ["a", "ae", "ya", "yae", "eo", "e", "yeo", "ye", "o", "wa", "wae", "oe", "yo", "u", "wo", "we", "wi", "yu", "eu", "ui", "i"]
    /// Final consonant (index 1…27) → its sound at the end of a syllable.
    private static let finals = ["", "k", "k", "k", "n", "n", "n", "t", "l", "k", "m", "l", "l", "l", "p", "l", "m", "p", "p", "t", "t", "ng", "t", "t", "k", "t", "p", "t"]
    /// Final consonant → (part kept, initial index carried to a following ㅇ-syllable). Linking (연음).
    private static let linking: [Int: (String, Int)] = [
        1: ("", 0), 2: ("", 1), 3: ("k", 9), 4: ("", 2), 5: ("n", 12), 6: ("", 2), 7: ("", 3), 8: ("", 5),
        9: ("l", 0), 10: ("l", 6), 11: ("l", 7), 12: ("l", 9), 13: ("l", 16), 14: ("l", 17), 15: ("", 5),
        16: ("", 6), 17: ("", 7), 18: ("p", 9), 19: ("", 9), 20: ("", 10), 22: ("", 12), 23: ("", 14),
        24: ("", 15), 25: ("", 16), 26: ("", 17), 27: ("", 18),
    ]

    static func korean(_ s: String) -> String {
        // Decompose into (initial, vowel, final) per syllable; other characters pass through.
        enum Piece { case syl(Int, Int, Int), other(Character) }
        let pieces: [Piece] = s.map { ch in
            guard let u = ch.unicodeScalars.first, ch.unicodeScalars.count == 1, (0xAC00...0xD7A3).contains(u.value) else { return .other(ch) }
            let i = Int(u.value - 0xAC00)
            return .syl(i / 588, (i % 588) / 28, i % 28)
        }
        var out = ""
        var carry: Int? // initial index replacing the next syllable's silent ㅇ
        for (n, p) in pieces.enumerated() {
            guard case let .syl(ini, v, fin) = p else {
                if case let .other(ch) = p { out.append(ch) }
                carry = nil
                continue
            }
            let carried = carry != nil
            let initial = carry ?? ini
            carry = nil
            // ㄹ after a final ㄹ/ㄴ reads as l (e.g. 별로 byeollo, 신라 silla).
            var onset = initials[initial]
            if !carried, ini == 5, n > 0, case let .syl(_, _, pf) = pieces[n - 1], [4, 8].contains(pf) { onset = "l" }
            out += onset + vowels[v]
            guard fin > 0 else { continue }
            if n + 1 < pieces.count, case let .syl(nextIni, _, _) = pieces[n + 1] {
                if nextIni == 11 { // next syllable starts silent: the final moves over
                    if fin == 27 { continue } // ㅎ before a vowel is silent
                    if fin == 21 { out += "ng"; continue }
                    if let (keep, moved) = linking[fin] { out += keep; carry = moved; continue }
                }
                if fin == 8 && nextIni == 5 { out += "l"; continue } // ㄹ+ㄹ → ll
                if fin == 4 && nextIni == 5 { out += "l"; continue } // ㄴ+ㄹ → ll
            }
            out += finals[fin]
        }
        return out
    }

    // MARK: Japanese / Chinese (system transforms)

    static func japaneseReading(_ s: String) -> String {
        let cf = s as CFString
        let range = CFRange(location: 0, length: CFStringGetLength(cf))
        guard let tok = CFStringTokenizerCreate(nil, cf, range, kCFStringTokenizerUnitWordBoundary, Locale(identifier: "ja") as CFLocale) else { return s }
        var parts: [String] = []
        var type = CFStringTokenizerAdvanceToNextToken(tok)
        while type != [] {
            let r = CFStringTokenizerGetCurrentTokenRange(tok)
            let piece = (s as NSString).substring(with: NSRange(location: r.location, length: r.length))
            if let latin = CFStringTokenizerCopyCurrentTokenAttribute(tok, kCFStringTokenizerAttributeLatinTranscription) as? String, !latin.isEmpty {
                parts.append(latin)
            } else if !piece.trimmingCharacters(in: .whitespaces).isEmpty {
                // Kana the tokenizer didn't transcribe, punctuation, Latin words.
                let m = NSMutableString(string: piece)
                CFStringTransform(m, nil, kCFStringTransformToLatin, false)
                parts.append(m as String)
            }
            type = CFStringTokenizerAdvanceToNextToken(tok)
        }
        return parts.joined(separator: " ").replacingOccurrences(of: #" ([,.!?、。！？」』)])"#, with: "$1", options: .regularExpression)
    }

    static func pinyin(_ s: String) -> String {
        let m = NSMutableString(string: s)
        CFStringTransform(m, nil, kCFStringTransformMandarinLatin, false)
        return m as String
    }
}
