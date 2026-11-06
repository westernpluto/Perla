import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @AppStorage(Prefs.Key.highlight) private var highlight = true
    @AppStorage(Prefs.Key.textScale) private var textScale = 1.0
    @AppStorage(Prefs.Key.serif) private var serif = false

    @State private var saved = AnswerStore.shared.count
    @State private var imported = ImportedAnswers.shared.count
    @State private var importing = false
    @State private var importMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Reading") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Text size")
                            Spacer()
                            Text("\(Int((textScale * 100).rounded()))%").foregroundStyle(.secondary)
                        }
                        HStack(spacing: 12) {
                            Image(systemName: "textformat.size.smaller")
                            Slider(value: $textScale, in: 0.8...1.8, step: 0.05)
                            Image(systemName: "textformat.size.larger")
                        }
                    }
                    Toggle("Serif font", isOn: $serif)
                }

                Section {
                    Toggle("Highlight answers in the text", isOn: $highlight)
                } header: {
                    Text("Answers")
                } footer: {
                    Text("Tap an answer box to write your own answer. The sentence in each paragraph that answers the question is highlighted, and you can use it as your answer.")
                }

                Section {
                    Button {
                        importing = true
                    } label: {
                        Label("Import answers file", systemImage: "square.and.arrow.down")
                    }
                    Button {
                        pasteAnswers()
                    } label: {
                        Label("Paste answers", systemImage: "doc.on.clipboard")
                    }
                    if let importMessage {
                        Text(importMessage).font(.footnote).foregroundStyle(.secondary)
                    }
                    if imported > 0 {
                        Button("Remove imported answers (\(imported))", role: .destructive) {
                            ImportedAnswers.shared.clear()
                            imported = 0
                        }
                    }
                } header: {
                    Text("Answers file")
                } footer: {
                    Text("Import a Perla answers file (JSON with \"question\" and \"answer\" pairs) from Files, or copy it and tap Paste. The answers appear in the matching answer boxes.")
                }

                Section {
                    Button("Clear saved answers (\(saved))", role: .destructive) {
                        AnswerStore.shared.clear()
                        saved = 0
                    }
                    .disabled(saved == 0)
                } footer: {
                    Text("For personal use. Publications are downloaded from jw.org.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .answersImporter(isPresented: $importing) { message in
                importMessage = message
                imported = ImportedAnswers.shared.count
            }
        }
    }

    private func pasteAnswers() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else {
            importMessage = "The clipboard is empty."
            return
        }
        do {
            let n = try ImportedAnswers.shared.importText(text)
            imported = ImportedAnswers.shared.count
            importMessage = n == 0 ? "No answers found in the clipboard." : "Imported \(n) answers."
        } catch {
            importMessage = "The clipboard doesn't contain a Perla answers file."
        }
    }
}
