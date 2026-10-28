// Licensed under GPL-3.0-only with an additional term under section 7(b); see LICENSE and NOTICE.md.

import Foundation

/// How a note list is ordered, as Samsung Notes offers it: by date modified, date created or name, either way round,
/// optionally with favourites first. Dates put the newest first and names go from A to Z unless `reversed`.
struct NoteSort: Codable, Equatable {
    enum Key: String, Codable, CaseIterable, Identifiable {
        case modified, created, name
        var id: String { rawValue }
        var label: String {
            switch self {
            case .modified: return "Date Modified"
            case .created: return "Date Created"
            case .name: return "Name"
            }
        }
    }
    var key = Key.modified
    var reversed = false
    var favoritesFirst = false

    /// `notes` in this order. Notes that tie are ordered by date modified, newest first, then by id, so the order is
    /// always the same. A note whose creation date is unknown counts as created when it was last modified.
    func sorted(_ notes: [NoteRecord]) -> [NoteRecord] {
        func compare<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult { a < b ? .orderedAscending : a > b ? .orderedDescending : .orderedSame }
        return notes.sorted { a, b in
            if favoritesFirst, a.isFavorite != b.isFavorite { return a.isFavorite }
            var result: ComparisonResult
            switch key {
            case .modified: result = compare(b.modified, a.modified)
            case .created: result = compare(b.created ?? b.modified, a.created ?? a.modified)
            case .name: result = a.title.localizedStandardCompare(b.title)
            }
            if reversed { result = result == .orderedAscending ? .orderedDescending : result == .orderedDescending ? .orderedAscending : .orderedSame }
            if result == .orderedSame { result = compare(b.modified, a.modified) }
            return result == .orderedSame ? a.id < b.id : result == .orderedAscending
        }
    }
}
