import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @AppStorage(Prefs.Key.textScale) private var textScale = 1.0
    @AppStorage(Prefs.Key.serif) private var serif = false
    @AppStorage(Prefs.Key.margin) private var margin = Prefs.defaultMargin
    @AppStorage(Prefs.Key.lang) private var pubLang = "E"
    @AppStorage(Prefs.Key.appLang) private var appLang = ""

    @State private var saved = AnswerStore.shared.count
    @State private var imported = ImportedAnswers.shared.count
    @State private var importing = false
    @State private var importMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Publications", selection: $pubLang) {
                        ForEach(PubLanguage.all) { l in Text(l.native).tag(l.code) }
                    }
                    Picker("App", selection: $appLang) {
                        Text("Same as iPhone").tag("")
                        ForEach(AppLanguage.choices, id: \.code) { c in Text(c.name).tag(c.code) }
                    }
                } header: {
                    Text("Language")
                        .onChange(of: appLang) { _, code in
                            // Also tell iOS, so system text (pickers, share sheets) follows after a restart.
                            if code.isEmpty {
                                UserDefaults.standard.removeObject(forKey: "AppleLanguages")
                            } else {
                                UserDefaults.standard.set([code], forKey: "AppleLanguages")
                            }
                        }
                } footer: {
                    Text("Publications are downloaded in their language. The app's menus and buttons can use a different one.")
                }

                Section("Reading") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Text size")
                            Spacer()
                            Text("\(Int((textScale * 100).rounded()))%").foregroundStyle(.secondary)
                        }
                        HStack(spacing: 12) {
                            Image(systemName: "textformat.size.smaller")
                            Slider(value: $textScale, in: 0.75...1.8, step: 0.05)
                            Image(systemName: "textformat.size.larger")
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Side margins")
                            Spacer()
                            Text("\(Int(margin)) pt").foregroundStyle(.secondary)
                        }
                        HStack(spacing: 12) {
                            Image(systemName: "arrow.right.and.line.vertical.and.arrow.left")
                            Slider(value: $margin, in: 6...120, step: 2)
                            Image(systemName: "arrow.left.and.line.vertical.and.arrow.right")
                        }
                    }
                    Toggle("Serif font", isOn: $serif)
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
                    Text("Answers")
                } footer: {
                    Text("Type your answers straight into the answer boxes. To fill them in advance, import a Perla answers file (JSON with \"question\" and \"answer\" pairs) from Files, or copy it and tap Paste. Anything you type replaces the imported answer.")
                }

                Section {
                    Button("Clear saved answers (\(saved))", role: .destructive) {
                        AnswerStore.shared.clear()
                        saved = 0
                    }
                    .disabled(saved == 0)
                } footer: {
                    Text("Perla \(Self.version) · For personal use. Publications are downloaded from jw.org.")
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
            importMessage = L("The clipboard is empty.")
            return
        }
        do {
            let n = try ImportedAnswers.shared.importText(text)
            imported = ImportedAnswers.shared.count
            importMessage = n == 0 ? L("No answers found in the clipboard.") : L("Imported %lld answers.", n)
        } catch {
            importMessage = L("The clipboard doesn't contain a Perla answers file.")
        }
    }

    /// "1.0 (build 18)", from the app's own Info.plist.
    static var version: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "?"
        let b = info?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (build \(b))"
    }
}
