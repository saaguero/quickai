import Foundation
import SwiftUI

/// A match of a query against a candidate: fzf's score (higher ranks first)
/// plus the character offsets that matched, for highlighting.
struct FuzzyMatch {
    let score: Int
    /// Character-offset ranges inside the original candidate string.
    let ranges: [Range<Int>]
}

// MARK: - fzf scoring constants (junegunn/fzf, src/algo/algo.go)

private let scoreMatch = 16
private let scoreGapStart = -3
private let scoreGapExtension = -1
private let bonusBoundary = scoreMatch / 2
private let bonusNonWord = scoreMatch / 2
private let bonusCamel123 = bonusBoundary + scoreGapExtension
private let bonusConsecutive = -(scoreGapStart + scoreGapExtension)
private let bonusFirstCharMultiplier = 2
private let bonusBoundaryWhite = bonusBoundary + 2
private let bonusBoundaryDelimiter = bonusBoundary + 1

/// fzf's default delimiters for the "boundary after a delimiter" bonus.
private let delimiters: Set<Character> = ["/", ",", ":", ";", "|"]

/// Ordered exactly like fzf's charClass: the bonus table compares by rank.
private enum CharClass: Int, Comparable {
    case white, nonWord, delimiter, lower, upper, letter, number
    static func < (lhs: CharClass, rhs: CharClass) -> Bool { lhs.rawValue < rhs.rawValue }
}

private func charClass(of character: Character) -> CharClass {
    if character.isWhitespace { return .white }
    if delimiters.contains(character) { return .delimiter }
    if character.isNumber { return .number }
    if character.isLowercase { return .lower }
    if character.isUppercase { return .upper }
    if character.isLetter { return .letter }
    return .nonWord
}

private func bonusFor(_ previous: CharClass, _ current: CharClass) -> Int {
    if current > .nonWord {
        switch previous {
        case .white: return bonusBoundaryWhite
        case .delimiter: return bonusBoundaryDelimiter
        case .nonWord: return bonusBoundary
        default: break
        }
    }
    if (previous == .lower && current == .upper) || (previous != .number && current == .number) {
        return bonusCamel123
    }
    switch current {
    case .nonWord, .delimiter: return bonusNonWord
    case .white: return bonusBoundaryWhite
    default: return 0
    }
}

// MARK: - Public entry point

/// fzf-compatible search: FuzzyMatchV2 scoring (Smith-Waterman with fzf's
/// boundary / camelCase / consecutive bonuses and gap penalties), fzf's smart
/// case (case-sensitive only when the term has an uppercase letter) and fzf's
/// diacritic normalization. Whitespace splits the query into terms that must
/// all match, like fzf's extended search, and their scores add up.
///
/// `exact: true` is fzf's exact mode ('term): the term must appear as one
/// contiguous run. Used for long haystacks, where a scattered subsequence
/// match says nothing.
func fuzzyMatch(_ query: String, in candidate: String, exact: Bool = false) -> FuzzyMatch? {
    let terms = query.split(whereSeparator: \.isWhitespace)
    guard !terms.isEmpty else { return FuzzyMatch(score: 0, ranges: []) }
    let haystack = Haystack(candidate)
    var total = 0
    var offsets: [Int] = []
    for term in terms {
        let pattern = Pattern(term)
        guard let result = exact
            ? haystack.exactMatch(pattern)
            : haystack.fuzzyMatchV2(pattern)
        else { return nil }
        total += result.score
        offsets.append(contentsOf: result.positions.map { haystack.origin[$0] })
    }
    return FuzzyMatch(score: total, ranges: ranges(from: offsets))
}

/// Score-only entry point for callers that do not highlight.
func fuzzyScore(_ query: String, in candidate: String, exact: Bool = false) -> Int? {
    fuzzyMatch(query, in: candidate, exact: exact)?.score
}

// MARK: - Normalized inputs

/// One search term, folded like fzf: diacritics removed, plus fzf's smart case
/// (an uppercase letter anywhere in the term makes the term case-sensitive).
private struct Pattern {
    let characters: [Character]
    let isCaseSensitive: Bool

    init<S: StringProtocol>(_ term: S) {
        let folded = fold(String(term))
        isCaseSensitive = folded.contains(where: \.isUppercase)
        characters = isCaseSensitive ? folded : folded.map { Character($0.lowercased()) }
    }
}

/// The candidate, folded the same way, keeping a map back to the offsets of the
/// original string so highlight ranges stay correct even when folding changes a
/// character's width ("ss" for a sharp s, say).
private struct Haystack {
    let characters: [Character]
    let lowered: [Character]
    let origin: [Int]

    init(_ string: String) {
        var characters: [Character] = []
        var origin: [Int] = []
        for (offset, character) in string.enumerated() {
            for folded in fold(String(character)) {
                characters.append(folded)
                origin.append(offset)
            }
        }
        self.characters = characters
        self.lowered = characters.map { Character($0.lowercased()) }
        self.origin = origin
    }

    private func character(at index: Int, caseSensitive: Bool) -> Character {
        caseSensitive ? characters[index] : lowered[index]
    }

    /// Port of fzf's FuzzyMatchV2: same four phases, same constants, same
    /// backtrace, so ranking and highlight positions match what fzf shows.
    func fuzzyMatchV2(_ pattern: Pattern) -> (score: Int, positions: [Int])? {
        let patternCharacters = pattern.characters
        let caseSensitive = pattern.isCaseSensitive
        let patternCount = patternCharacters.count
        let count = characters.count
        guard patternCount > 0 else { return (0, []) }
        guard count >= patternCount else { return nil }

        // Phase 1: cheap forward scan for the first index a whole match can
        // start at (fzf's asciiFuzzyIndex).
        var start = -1
        var matched = 0
        for index in 0..<count {
            guard character(at: index, caseSensitive: caseSensitive) == patternCharacters[matched] else { continue }
            if start < 0 { start = index }
            matched += 1
            if matched == patternCount { break }
        }
        guard matched == patternCount, start >= 0 else { return nil }

        // Phase 2: first-row scores, per-character bonuses, and the first
        // occurrence of each pattern character.
        var firstRow = [Int](repeating: 0, count: count)
        var firstRowConsecutive = [Int](repeating: 0, count: count)
        var bonus = [Int](repeating: 0, count: count)
        var firstOccurrence = [Int](repeating: 0, count: patternCount)

        var maxScore = 0
        var maxScorePosition = 0
        var patternIndex = 0
        var lastIndex = 0
        let firstPatternCharacter = patternCharacters[0]
        var expected = firstPatternCharacter
        var previousScore = 0
        var previousClass: CharClass = start > 0 ? charClass(of: characters[start - 1]) : .white
        var inGap = false

        for index in start..<count {
            let current = charClass(of: characters[index])
            let folded = character(at: index, caseSensitive: caseSensitive)
            let currentBonus = bonusFor(previousClass, current)
            bonus[index] = currentBonus
            previousClass = current

            if folded == expected {
                if patternIndex < patternCount {
                    firstOccurrence[patternIndex] = index
                    patternIndex += 1
                    expected = patternCharacters[min(patternIndex, patternCount - 1)]
                }
                lastIndex = index
            }

            if folded == firstPatternCharacter {
                let score = scoreMatch + currentBonus * bonusFirstCharMultiplier
                firstRow[index] = score
                firstRowConsecutive[index] = 1
                if patternCount == 1, score > maxScore {
                    maxScore = score
                    maxScorePosition = index
                    if currentBonus >= bonusBoundary { break }
                }
                inGap = false
            } else {
                firstRow[index] = max(previousScore + (inGap ? scoreGapExtension : scoreGapStart), 0)
                firstRowConsecutive[index] = 0
                inGap = true
            }
            previousScore = firstRow[index]
        }
        guard patternIndex == patternCount else { return nil }
        if patternCount == 1 { return (maxScore, [maxScorePosition]) }

        // Phase 3: fill the score matrix over the window that can hold a match.
        let first = firstOccurrence[0]
        let width = lastIndex - first + 1
        var scores = [Int](repeating: 0, count: patternCount * width)
        var consecutives = [Int](repeating: 0, count: patternCount * width)
        for offset in 0..<width {
            scores[offset] = firstRow[first + offset]
            consecutives[offset] = firstRowConsecutive[first + offset]
        }

        for patternIndex in 1..<patternCount {
            let rowStart = firstOccurrence[patternIndex]
            let expected = patternCharacters[patternIndex]
            let row = patternIndex * width
            let previousRow = row - width
            var inGap = false
            for column in rowStart...lastIndex {
                let offset = column - first
                var matchScore = 0
                var consecutive = 0
                let gapScore = scores[row + offset - 1] + (inGap ? scoreGapExtension : scoreGapStart)
                if character(at: column, caseSensitive: caseSensitive) == expected {
                    matchScore = scores[previousRow + offset - 1] + scoreMatch
                    var currentBonus = bonus[column]
                    consecutive = consecutives[previousRow + offset - 1] + 1
                    if consecutive > 1 {
                        let runStartBonus = bonus[column - consecutive + 1]
                        // a boundary inside the run restarts the run there
                        if currentBonus >= bonusBoundary, currentBonus > runStartBonus {
                            consecutive = 1
                        } else {
                            currentBonus = max(currentBonus, max(bonusConsecutive, runStartBonus))
                        }
                    }
                    if matchScore + currentBonus < gapScore {
                        matchScore += bonusConsecutive
                        consecutive = 0
                    } else {
                        matchScore += currentBonus
                    }
                }
                consecutives[row + offset] = consecutive
                inGap = matchScore < gapScore
                let score = max(max(matchScore, gapScore), 0)
                if patternIndex == patternCount - 1, score > maxScore {
                    maxScore = score
                    maxScorePosition = column
                }
                scores[row + offset] = score
            }
        }

        // Phase 4: backtrace the matched positions.
        var positions: [Int] = []
        var row = patternCount - 1
        var column = maxScorePosition
        var preferMatch = true
        while true {
            let rowOffset = row * width
            let offset = column - first
            let score = scores[rowOffset + offset]
            var diagonal = 0
            var left = 0
            if row > 0, column >= firstOccurrence[row] { diagonal = scores[rowOffset - width + offset - 1] }
            if column > firstOccurrence[row] { left = scores[rowOffset + offset - 1] }
            if score > diagonal, score > left || (score == left && preferMatch) {
                positions.append(column)
                if row == 0 { break }
                row -= 1
            }
            let below = rowOffset + width + offset + 1
            preferMatch = consecutives[rowOffset + offset] > 1
                || (below < consecutives.count && consecutives[below] > 0)
            column -= 1
            if column < first { break }
        }
        return (maxScore, positions)
    }

    /// fzf's exact mode: the term as one contiguous run, scored with the same
    /// match and bonus constants so it stays comparable to fuzzy scores.
    func exactMatch(_ pattern: Pattern) -> (score: Int, positions: [Int])? {
        let patternCharacters = pattern.characters
        let caseSensitive = pattern.isCaseSensitive
        let patternCount = patternCharacters.count
        guard patternCount > 0 else { return (0, []) }
        guard characters.count >= patternCount else { return nil }

        var best: (score: Int, start: Int)?
        for start in 0...(characters.count - patternCount) {
            var isMatch = true
            for offset in 0..<patternCount
            where character(at: start + offset, caseSensitive: caseSensitive) != patternCharacters[offset] {
                isMatch = false
                break
            }
            guard isMatch else { continue }
            let previousClass: CharClass = start > 0 ? charClass(of: characters[start - 1]) : .white
            let startBonus = bonusFor(previousClass, charClass(of: characters[start]))
            let score = scoreMatch * patternCount
                + startBonus * bonusFirstCharMultiplier
                + bonusConsecutive * (patternCount - 1)
            if best == nil || score > best!.score {
                best = (score, start)
            }
        }
        guard let best else { return nil }
        return (best.score, Array(best.start..<(best.start + patternCount)))
    }
}

private func fold(_ text: String) -> [Character] {
    Array(text.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil))
}

/// Turns matched offsets into sorted, collapsed ranges.
private func ranges(from offsets: [Int]) -> [Range<Int>] {
    var result: [Range<Int>] = []
    for offset in offsets.sorted() {
        if let last = result.last, offset <= last.upperBound {
            result[result.count - 1] = last.lowerBound..<max(last.upperBound, offset + 1)
        } else {
            result.append(offset..<(offset + 1))
        }
    }
    return result
}

// MARK: - Rendering

/// Renders `string` with the matched offsets tinted, for search result rows.
/// Attributes ride on the string itself so no enclosing button or list style
/// can flatten the colors back to the label's foreground.
func highlighted(_ string: String, ranges: [Range<Int>], color: Color) -> Text {
    guard !ranges.isEmpty else { return Text(verbatim: string) }
    var attributed = AttributedString(string)
    let count = string.count
    for range in ranges {
        let start = min(max(range.lowerBound, 0), count)
        let end = min(range.upperBound, count)
        guard start < end else { continue }
        let from = attributed.index(attributed.startIndex, offsetByCharacters: start)
        let to = attributed.index(attributed.startIndex, offsetByCharacters: end)
        attributed[from..<to].foregroundColor = color
        attributed[from..<to].inlinePresentationIntent = .stronglyEmphasized
    }
    return Text(attributed)
}

/// One shared tint for every search highlight (history rows, model browser).
enum SearchHighlight {
    static let color = Color(nsColor: .systemOrange)
}
