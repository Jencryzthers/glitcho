#if canImport(SwiftUI)
import SwiftUI

/// Manages the ordered list of user-defined category names for pinned channels.
///
/// Categories are persisted in `UserDefaults` as a JSON-encoded `[String]` under
/// the key `"channelCategories"`. The list contains only the user-created names;
/// "Uncategorized" is implicit and never stored here.
final class ChannelCategoryManager: ObservableObject {

    // MARK: - Storage

    @AppStorage("channelCategories") private var categoriesJSON: String = "[]"

    // MARK: - Public API

    /// Returns the current ordered list of category names.
    func categories() -> [String] {
        guard let data = categoriesJSON.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return decoded
    }

    /// Appends a new category if the name is non-empty and not already present (case-insensitive).
    ///
    /// - Parameter name: The display name of the category to add.
    func addCategory(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var current = categories()
        let alreadyExists = current.contains { $0.localizedCaseInsensitiveCompare(trimmed) == .orderedSame }
        guard !alreadyExists else { return }
        current.append(trimmed)
        persist(current)
    }

    /// Removes a category by name (case-insensitive match).
    ///
    /// - Parameter name: The display name of the category to remove.
    func removeCategory(_ name: String) {
        var current = categories()
        current.removeAll { $0.localizedCaseInsensitiveCompare(name) == .orderedSame }
        persist(current)
    }

    // MARK: - Private

    private func persist(_ list: [String]) {
        guard let data = try? JSONEncoder().encode(list),
              let json = String(data: data, encoding: .utf8) else { return }
        categoriesJSON = json
        objectWillChange.send()
    }
}

#endif
