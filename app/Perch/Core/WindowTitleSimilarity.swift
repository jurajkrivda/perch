import Foundation

enum WindowTitleSimilarity {
    static func normalize(_ title: String) -> String {
        title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func score(candidate: String, target: String) -> Double {
        let candidateTitle = normalize(candidate)
        let targetTitle = normalize(target)

        guard !candidateTitle.isEmpty, !targetTitle.isEmpty else {
            return candidateTitle == targetTitle ? 1 : 0
        }

        if candidateTitle == targetTitle {
            return 1
        }

        if candidateTitle.contains(targetTitle) || targetTitle.contains(candidateTitle) {
            let shorter = Double(min(candidateTitle.count, targetTitle.count))
            let longer = Double(max(candidateTitle.count, targetTitle.count))
            return max(0.72, shorter / longer)
        }

        let tokenScore = tokenOverlapScore(candidateTitle, targetTitle)
        let editScore = editSimilarity(candidateTitle, targetTitle)

        return (tokenScore * 0.62) + (editScore * 0.38)
    }

    private static func tokenOverlapScore(_ lhs: String, _ rhs: String) -> Double {
        let lhsTokens = Set(lhs.split(separator: " ").map(String.init))
        let rhsTokens = Set(rhs.split(separator: " ").map(String.init))

        guard !lhsTokens.isEmpty, !rhsTokens.isEmpty else {
            return 0
        }

        let overlap = lhsTokens.intersection(rhsTokens).count
        let total = lhsTokens.union(rhsTokens).count

        guard total > 0 else {
            return 0
        }

        return Double(overlap) / Double(total)
    }

    private static func editSimilarity(_ lhs: String, _ rhs: String) -> Double {
        let lhsCharacters = Array(lhs)
        let rhsCharacters = Array(rhs)

        guard !lhsCharacters.isEmpty, !rhsCharacters.isEmpty else {
            return lhsCharacters.isEmpty == rhsCharacters.isEmpty ? 1 : 0
        }

        let distance = levenshteinDistance(lhsCharacters, rhsCharacters)
        let longest = max(lhsCharacters.count, rhsCharacters.count)

        guard longest > 0 else {
            return 1
        }

        return max(0, 1 - (Double(distance) / Double(longest)))
    }

    private static func levenshteinDistance(_ lhs: [Character], _ rhs: [Character]) -> Int {
        var previous = Array(0...rhs.count)
        var current = Array(repeating: 0, count: rhs.count + 1)

        for lhsIndex in 1...lhs.count {
            current[0] = lhsIndex

            for rhsIndex in 1...rhs.count {
                let substitutionCost = lhs[lhsIndex - 1] == rhs[rhsIndex - 1] ? 0 : 1
                current[rhsIndex] = min(
                    previous[rhsIndex] + 1,
                    current[rhsIndex - 1] + 1,
                    previous[rhsIndex - 1] + substitutionCost
                )
            }

            swap(&previous, &current)
        }

        return previous[rhs.count]
    }
}
