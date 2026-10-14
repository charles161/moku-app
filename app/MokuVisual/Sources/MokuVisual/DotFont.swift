import AppKit
import CoreText

/// Tetsu's lettering: a dot-matrix font drawn for its LED display (docs/specs/next-wave.md §7), so it talks the way its
/// face looks. Capitals are 5×7 dots; small letters sit on a 5-dot x-height with 2-dot descenders; widths vary, with a
/// dot between letters. Rows count down from the top of a capital: 0…6 is the cap height (6 sits on the baseline),
/// 7…8 the descender, and accents sit above (-2…-1 over a capital or a tall letter, -1…0 over a small one, with a dark
/// row between). Letters it doesn't have are drawn from the system font into the same grid (emoji, Greek, Cyrillic,
/// symbols); text it can't spell well in dots (right-to-left, CJK and other scripts) is set in type instead.
enum DotFont {
    struct Dot: Equatable, Sendable { var x: Int; var y: Int; var level: Float = 1 }
    struct Glyph: Equatable, Sendable {
        var width: Int
        var dots: [Dot]
        static let space = Glyph(width: 2, dots: [])
    }
    /// A line's height in dots, the gap included: the descender and the next line's accents share the gap.
    static let lineRows = 10
    /// The text block's rows run from `topRow` (a capital's accent) to the last line's descender.
    static let topRow = -2

    static func glyph(_ character: Character) -> Glyph? {
        let character = aliases[character] ?? character
        if character == " " { return .space }
        if let glyph = table[character] { return glyph }
        // An accented letter: its base letter with the marks drawn over (or under) it.
        let scalars = Array(String(character).decomposedStringWithCanonicalMapping.unicodeScalars)
        guard scalars.count > 1, var base = scalars.first.map(Character.init) else { return nil }
        if base == "i" { base = "ı" } else if base == "j" { base = "ȷ" }
        guard var glyph = table[base] else { return nil }
        let tall = base.isUppercase || base.isNumber || "bdfhklt".contains(base)
        for mark in scalars.dropFirst() {
            let art: [String], top: Int
            if let above = marksAbove[mark.value] { art = above; top = (tall ? 0 : 1) - art.count }
            else if let below = marksBelow[mark.value] { art = below; top = 7 }
            else { return nil }
            let markWidth = art[0].count
            var left = (glyph.width - markWidth) / 2
            if left < 0 { glyph.dots = glyph.dots.map { Dot(x: $0.x - left, y: $0.y, level: $0.level) }; glyph.width = markWidth; left = 0 }
            for (row, line) in art.enumerated() { for (column, cell) in line.enumerated() where cell == "#" { glyph.dots.append(Dot(x: left + column, y: top + row)) } }
        }
        return glyph
    }

    /// Whether the text can be shown in dots: every letter is in the font (accents included) or can be drawn into the
    /// grid (emoji, Greek, Cyrillic, punctuation and symbols). Right-to-left and other scripts are set in type.
    static func spells(_ text: String) -> Bool {
        text.allSatisfy { character in
            if character.isNewline || glyph(character) != nil || isEmoji(character) { return true }
            return character.unicodeScalars.allSatisfy { scalar in
                let v = scalar.value
                return (0x370...0x3FF).contains(v) || (0x400...0x4FF).contains(v) || (0x2000...0x2BFF).contains(v)
                    || (0xFE00...0xFE0F).contains(v) || scalar.properties.isWhitespace || scalar.properties.generalCategory == .nonspacingMark && v < 0x370
            }
        }
    }
    static func isEmoji(_ character: Character) -> Bool {
        character.unicodeScalars.contains { $0.properties.isEmojiPresentation || $0.properties.isEmoji && $0.value > 0x238C }
    }
    /// Whether the text reads right to left (its first strong letter does).
    static func readsRightToLeft(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            let v = scalar.value
            if (0x590...0x8FF).contains(v) || (0xFB1D...0xFDFF).contains(v) || (0xFE70...0xFEFF).contains(v) { return true }
            if scalar.properties.isAlphabetic { return false }
        }
        return false
    }

    /// A letter the font doesn't have, drawn from the system font into the grid (an emoji keeps its light parts, so a
    /// face keeps its eyes): the same rows as the font's own, at 1, ½ or ¼ brightness.
    @MainActor static func drawn(_ character: Character) -> Glyph {
        let emoji = isEmoji(character)
        let font = emoji ? (NSFont(name: "AppleColorEmoji", size: 9) ?? .systemFont(ofSize: 9)) : NSFont.systemFont(ofSize: 10, weight: .medium)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: String(character), attributes: [.font: font, .foregroundColor: NSColor.white]))
        let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        let width = max(1, Int(ceil(bounds.width)) + 1), rows = 12   // the grid's rows -2…9, top first in memory
        var pixels = [UInt8](repeating: 0, count: width * rows * 4)
        let drew = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: rows, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            // The baseline under row 6 (three rows up from the bottom); an emoji sits a row lower, into the descender.
            context.textPosition = CGPoint(x: -bounds.minX, y: emoji ? 2 : 3)
            CTLineDraw(line, context)
            return true
        }
        guard drew else { return Glyph(width: 3, dots: []) }
        var dots: [Dot] = [], total: Float = 0, light: Float = 0
        for row in 0..<rows { for column in 0..<width {
            let i = (row * width + column) * 4, alpha = Float(pixels[i + 3]) / 255
            guard alpha > 0.1 else { continue }
            let luma = (0.299 * Float(pixels[i]) + 0.587 * Float(pixels[i + 1]) + 0.114 * Float(pixels[i + 2])) / 255 / alpha
            let value = emoji ? alpha * min(1, max(0, (luma - 0.22) / 0.45)) : alpha
            total += alpha; light += value
            dots.append(Dot(x: column, y: row - 2, level: value))
        }}
        // A dark emoji (a black heart) shows its shape instead.
        if emoji && light < total * 0.2 { dots = dots.map { Dot(x: $0.x, y: $0.y, level: 1) } }
        return Glyph(width: width, dots: dots.compactMap { dot in
            let level: Float = dot.level >= 0.55 ? 1 : dot.level >= 0.3 ? 0.5 : dot.level >= 0.14 ? 0.25 : 0
            return level > 0 ? Dot(x: dot.x, y: dot.y, level: level) : nil
        })
    }

    static let aliases: [Character: Character] = [
        "’": "'", "ʼ": "'", "′": "'", "″": "\"", "‚": ",", "„": "\"", "−": "-", "‐": "-", "‑": "-", "‒": "–",
        "\u{00A0}": " ", "\u{2009}": " ", "\u{202F}": " ", "«": "<", "»": ">", "‹": "<", "›": ">", "❤": "♥", "\t": " ",
    ]
    /// Accents over a letter (grave, acute, circumflex, tilde, diaeresis, ring, caron, macron, dot, breve, double acute).
    static let marksAbove: [UInt32: [String]] = [
        0x300: ["#.", ".#"], 0x301: [".#", "#."], 0x302: [".#.", "#.#"], 0x303: [".#.#", "#.#."], 0x308: ["#.#"],
        0x30A: ["##", "##"], 0x30C: ["#.#", ".#."], 0x304: ["###"], 0x307: ["#"], 0x306: ["#..#", ".##."], 0x30B: [".#.#", "#.#."],
    ]
    /// Marks under a letter (cedilla, ogonek).
    static let marksBelow: [UInt32: [String]] = [0x327: [".#", "#."], 0x328: ["#.", ".#"]]

    static let table: [Character: Glyph] = source.mapValues { art in
        let rows = art.split(separator: " ")
        return Glyph(width: rows.first?.count ?? 0, dots: rows.enumerated().flatMap { row, line in
            line.enumerated().compactMap { column, cell in cell == "#" ? Dot(x: column, y: row) : nil }
        })
    }
    /// The art, drawn dot by dot: rows from the top of a capital, '#' lit.
    private static let source: [Character: String] = [
        "A": ".###. #...# #...# ##### #...# #...# #...#",
        "B": "####. #...# #...# ####. #...# #...# ####.",
        "C": ".###. #...# #.... #.... #.... #...# .###.",
        "D": "####. #...# #...# #...# #...# #...# ####.",
        "E": "##### #.... #.... ####. #.... #.... #####",
        "F": "##### #.... #.... ####. #.... #.... #....",
        "G": ".###. #...# #.... #.### #...# #...# .####",
        "H": "#...# #...# #...# ##### #...# #...# #...#",
        "I": "### .#. .#. .#. .#. .#. ###",
        "J": "..### ...#. ...#. ...#. ...#. #..#. .##..",
        "K": "#...# #..#. #.#.. ##... #.#.. #..#. #...#",
        "L": "#.... #.... #.... #.... #.... #.... #####",
        "M": "#...# ##.## #.#.# #.#.# #...# #...# #...#",
        "N": "#...# #...# ##..# #.#.# #..## #...# #...#",
        "O": ".###. #...# #...# #...# #...# #...# .###.",
        "P": "####. #...# #...# ####. #.... #.... #....",
        "Q": ".###. #...# #...# #...# #.#.# #..#. .##.#",
        "R": "####. #...# #...# ####. #.#.. #..#. #...#",
        "S": ".#### #.... #.... .###. ....# ....# ####.",
        "T": "##### ..#.. ..#.. ..#.. ..#.. ..#.. ..#..",
        "U": "#...# #...# #...# #...# #...# #...# .###.",
        "V": "#...# #...# #...# #...# #...# .#.#. ..#..",
        "W": "#...# #...# #...# #.#.# #.#.# #.#.# .#.#.",
        "X": "#...# #...# .#.#. ..#.. .#.#. #...# #...#",
        "Y": "#...# #...# .#.#. ..#.. ..#.. ..#.. ..#..",
        "Z": "##### ....# ...#. ..#.. .#... #.... #####",
        "a": ".... .... .##. ...# .### #..# .###",
        "b": "#... #... ###. #..# #..# #..# ###.",
        "c": ".... .... .### #... #... #... .###",
        "d": "...# ...# .### #..# #..# #..# .###",
        "e": ".... .... .##. #..# #### #... .###",
        "f": ".## #.. ### #.. #.. #.. #..",
        "g": ".... .... .### #..# #..# #..# .### ...# .##.",
        "h": "#... #... ###. #..# #..# #..# #..#",
        "i": "# . # # # # #",
        "j": "..# ... ..# ..# ..# ..# ..# ..# ##.",
        "k": "#... #... #..# #.#. ##.. #.#. #..#",
        "l": "#. #. #. #. #. #. .#",
        "m": "..... ..... ##.#. #.#.# #.#.# #.#.# #.#.#",
        "n": ".... .... ###. #..# #..# #..# #..#",
        "o": ".... .... .##. #..# #..# #..# .##.",
        "p": ".... .... ###. #..# #..# #..# ###. #... #...",
        "q": ".... .... .### #..# #..# #..# .### ...# ...#",
        "r": ".... .... #.## ##.. #... #... #...",
        "s": ".... .... .### #... .##. ...# ###.",
        "t": "... .#. ### .#. .#. .#. ..#",
        "u": ".... .... #..# #..# #..# #..# .###",
        "v": "..... ..... #...# #...# #...# .#.#. ..#..",
        "w": "..... ..... #...# #...# #.#.# #.#.# .#.#.",
        "x": "..... ..... #...# .#.#. ..#.. .#.#. #...#",
        "y": ".... .... #..# #..# #..# #..# .### ...# .##.",
        "z": ".... .... #### ..#. .#.. #... ####",
        "ı": ". . # # # # #",
        "ȷ": "... ... ..# ..# ..# ..# ..# ..# ##.",
        "0": ".###. #...# #..## #.#.# ##..# #...# .###.",
        "1": ".#. ##. .#. .#. .#. .#. ###",
        "2": ".###. #...# ....# ...#. ..#.. .#... #####",
        "3": "####. ....# ....# .###. ....# ....# ####.",
        "4": "...#. ..##. .#.#. #..#. ##### ...#. ...#.",
        "5": "##### #.... ####. ....# ....# #...# .###.",
        "6": "..##. .#... #.... ####. #...# #...# .###.",
        "7": "##### ....# ...#. ..#.. .#... .#... .#...",
        "8": ".###. #...# #...# .###. #...# #...# .###.",
        "9": ".###. #...# #...# .#### ....# ...#. .##..",
        "!": "# # # # # . #",
        "?": ".###. #...# ....# ...#. ..#.. ..... ..#..",
        ".": ". . . . . . #",
        ",": ".. .. .. .. .. .# .# #. ..",
        ":": ". . # . . # .",
        ";": ".. .. .# .. .. .# .# #. ..",
        "'": ".# .# #. .. .. .. ..",
        "‘": ".# #. #. .. .. .. ..",
        "\"": "#.# #.# ... ... ... ... ...",
        "“": ".#.# #.#. #.#. .... .... .... ....",
        "”": ".#.# .#.# #.#. .... .... .... ....",
        "-": "... ... ... ### ... ... ...",
        "–": ".... .... .... #### .... .... ....",
        "—": "...... ...... ...... ###### ...... ...... ......",
        "(": ".# #. #. #. #. #. .#",
        ")": "#. .# .# .# .# .# #.",
        "[": "## #. #. #. #. #. ##",
        "]": "## .# .# .# .# .# ##",
        "{": ".## .#. .#. #.. .#. .#. .##",
        "}": "##. .#. .#. ..# .#. .#. ##.",
        "/": "....# ....# ...#. ..#.. .#... #.... #....",
        "\\": "#.... #.... .#... ..#.. ...#. ....# ....#",
        "&": ".##.. #..#. #.#.. .#... #.#.# #..#. .##.#",
        "@": ".###. #...# #.### #.#.# #.### #.... .###.",
        "#": ".#.#. .#.#. ##### .#.#. ##### .#.#. .#.#.",
        "$": "..#.. .#### #.#.. .###. ..#.# ####. ..#..",
        "%": "##... ##..# ...#. ..#.. .#... #..## ...##",
        "+": "..... ..#.. ..#.. ##### ..#.. ..#.. .....",
        "=": "..... ..... ##### ..... ##### ..... .....",
        "*": "..... ..#.. #.#.# .###. #.#.# ..#.. .....",
        "<": "...# ..#. .#.. #... .#.. ..#. ...#",
        ">": "#... .#.. ..#. ...# ..#. .#.. #...",
        "_": "..... ..... ..... ..... ..... ..... ..... ##### .....",
        "~": "..... ..... .##.# #.##. ..... ..... .....",
        "^": "..#.. .#.#. #...# ..... ..... ..... .....",
        "`": "#. .# .. .. .. .. ..",
        "|": "# # # # # # #",
        "…": "..... ..... ..... ..... ..... ..... #.#.#",
        "•": ".. .. .. ## ## .. ..",
        "·": ". . . # . . .",
        "♥": "..... .#.#. ##### ##### .###. ..#.. .....",
        "°": ".#. #.# .#. ... ... ... ...",
        "×": "..... #...# .#.#. ..#.. .#.#. #...# .....",
        "→": "..... ..#.. ...#. ##### ...#. ..#.. .....",
        "←": "..... ..#.. .#... ##### .#... ..#.. .....",
        "€": "..### .#... ####. .#... ####. .#... ..###",
        "£": "..##. .#..# .#... ###.. .#... .#... #####",
        "¡": ". . # . # # # # #",
        "¿": "..#.. ..... ..#.. .#... #.... #...# .###.",
        "ß": ".##. #..# #..# #.#. #..# #..# #.#.",
        "æ": "...... ...... .##.#. ...#.# .####. #..#.. .##.##",
        "Æ": ".#### #.#.. #.#.. ##### #.#.. #.#.. #.###",
        "ø": ".... .... .### #.## #..# ##.# ###.",
        "Ø": ".###.# #..##. #.#.#. #.#.#. #.#.#. ##..#. #.###.",
        "œ": "...... ...... .#.##. #.#..# #.#### #.#... .#.###",
        "ł": "#.. #.. #.# ##. #.. #.. .#.",
        "Ł": "#.... #.... #.#.. ##... #.... #.... #####",    ]
}
