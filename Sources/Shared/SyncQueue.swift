import Foundation

/// What to do with an unsaved local draft once Samsung Cloud can be reached, judged against the note's newest cloud
/// revision. Samsung Notes treats a note changed both on a device and in the cloud the same way: it is set aside as a
/// conflict until the user chooses a version.
enum DraftSync: Equatable {
    /// The cloud copy already has the draft's text; the draft holds nothing to save.
    case upToDate
    /// The draft was made from the newest revision: save it.
    case save
    /// Another device saved a newer revision with different text: the user chooses a version.
    case conflict

    static func decide(_ draft: [String: String], current: CloudDocument) -> DraftSync {
        let styled = draft["styled"].flatMap { try? RichText(encoded: $0) }.map { RichText.numbered($0.styledRuns) }
        if draft["title"] == current.title, draft["body"] == current.body, styled == nil || styled == current.styledBody { return .upToDate }
        return draft["commit"] == current.commit ? .save : .conflict
    }
}

/// How a note changed both on this Mac and on another device is settled, as Samsung Notes offers it.
enum ConflictChoice {
    /// Save this Mac's version over the newer cloud revision (which stays in Backups).
    case keepThisMac
    /// Keep the other device's version; this Mac's draft goes to the draft history.
    case keepOther
    /// Keep the other device's version and save this Mac's as a new note beside it.
    case keepBoth
}
