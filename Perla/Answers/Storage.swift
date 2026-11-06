import Foundation

struct CachedAnswer: Codable, Sendable {
    var text: String
    var engine: String
    var date: Date
}

/// Answers saved on the phone, so a page you already prepared opens instantly.
@MainActor
final class AnswerStore {
    static let shared = AnswerStore()

    private var items: [String: CachedAnswer] = [:]
    private let fileURL: URL
    private var saveTask: Task<Void, Never>?

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("answers.json")
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([String: CachedAnswer].self, from: data) {
            // Only keep answers you wrote or picked; generated ones from earlier versions are dropped.
            items = saved.filter { $0.value.engine == "Your answer" || $0.value.engine == "From the paragraph" }
            if items.count != saved.count { save() }
        }
    }

    var count: Int { items.count }

    func get(_ key: String) -> CachedAnswer? { items[key] }

    func set(_ key: String, text: String, engine: String) {
        items[key] = CachedAnswer(text: text, engine: engine, date: Date())
        if items.count > 4000 {
            let oldest = items.sorted { $0.value.date < $1.value.date }.prefix(items.count - 3500)
            for (k, _) in oldest { items[k] = nil }
        }
        save()
    }

    func remove(_ key: String) {
        guard items[key] != nil else { return }
        items[key] = nil
        save()
    }

    func clear() {
        items = [:]
        save()
    }

    private func save() {
        saveTask?.cancel()
        let snapshot = items
        let url = fileURL
        saveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 800_000_000)
            if Task.isCancelled { return }
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }
}
