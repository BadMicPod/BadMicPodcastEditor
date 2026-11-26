import Foundation

/// The back-and-forth of a Magic session, kept with the project so a follow-up doesn't have to repeat
/// what was already said or done. Newest entries are at the end.
enum MagicConversation {
    struct Turn: Codable, Equatable, Hashable, Identifiable {
        var id = UUID()
        var request: String
        var response: String
        var tab: String
        var date: Date
    }

    static let limit = 12

    static func adding(request: String, response: String, tab: String, to list: [Turn]) -> [Turn] {
        let r = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !r.isEmpty else { return list }
        var list = list
        list.append(Turn(request: r, response: response.trimmingCharacters(in: .whitespacesAndNewlines), tab: tab, date: Date()))
        if list.count > limit { list = Array(list.suffix(limit)) }
        return list
    }
}
