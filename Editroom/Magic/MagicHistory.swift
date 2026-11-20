import Foundation

/// The prompts sent with Magic, newest first: the last 20, each once, kept on this Mac only.
enum MagicHistory {
    struct Entry: Codable, Equatable, Identifiable {
        var text: String
        /// The Magic tab it was sent from (claude, chatgpt, local).
        var tab: String
        var date: Date
        var id: String { text }
    }

    static let key = "magicHistory"
    static let limit = 20

    static var entries: [Entry] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        return list
    }

    /// A prompt just sent goes to the top (moved there if it was sent before).
    static func add(_ text: String, tab: MagicAgent.Tab) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        var list = entries.filter { $0.text != t }
        list.insert(Entry(text: t, tab: tab.rawValue, date: Date()), at: 0)
        if let data = try? JSONEncoder().encode(Array(list.prefix(limit))) { UserDefaults.standard.set(data, forKey: key) }
    }

}
