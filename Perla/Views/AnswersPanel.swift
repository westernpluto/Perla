import SwiftUI
import UniformTypeIdentifiers

struct AnswersPanel: View {
    @ObservedObject var reader: ReaderModel
    let inSheet: Bool
    @State private var importing = false
    @State private var message: String?

    init(reader: ReaderModel, inSheet: Bool) {
        _reader = ObservedObject(wrappedValue: reader)
        self.inSheet = inSheet
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.accentColor.opacity(0.08))
            }
            if reader.questions.isEmpty {
                empty
            } else {
                list
            }
        }
        .background(Color(.secondarySystemBackground).opacity(inSheet ? 0 : 0.5))
        .answersImporter(isPresented: $importing) { message = $0 }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Answers")
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Menu {
                Section("Add answers") {
                    Button("Import answers file", systemImage: "square.and.arrow.down") { importing = true }
                    Button("Paste answers", systemImage: "doc.on.clipboard") { paste() }
                }
                Section {
                    Button("Copy all", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = reader.exportText
                    }
                    .disabled(reader.questions.isEmpty)
                    Button("Print", systemImage: "printer") {
                        Printer.present(title: reader.title, items: reader.exportItems)
                    }
                    .disabled(reader.questions.isEmpty)
                    ShareLink(item: reader.exportText) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .disabled(reader.questions.isEmpty)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var subtitle: String {
        let total = reader.questions.count
        if total == 0 { return "Nothing to answer here" }
        return "\(reader.answeredCount) of \(total) answered"
    }

    private func paste() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else {
            message = "The clipboard is empty. Copy the answers (JSON) first."
            return
        }
        do {
            let n = try ImportedAnswers.shared.importText(text)
            message = n == 0 ? "No answers found in the clipboard." : "Added \(n) answers."
        } catch {
            message = "The clipboard doesn't contain a Perla answers file."
        }
    }

    // MARK: List

    private var list: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(reader.questions) { q in
                    AnswerRow(question: q,
                              state: reader.answers[q.id] ?? AnswerState(),
                              focused: reader.focusedID == q.id,
                              reader: reader)
                        .id(q.id)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .onChange(of: reader.focusedID) { _, id in
                guard let id else { return }
                withAnimation { proxy.scrollTo(id, anchor: .top) }
            }
        }
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "text.bubble")
                .font(.largeTitle)
                .foregroundStyle(.tint)
            Text("No questions on this page")
                .font(.headline)
            Text("Open a meeting part, a study article or a book chapter to write answers.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

struct AnswerRow: View {
    let question: PageQuestion
    let state: AnswerState
    let focused: Bool
    let reader: ReaderModel
    @State var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !question.heading.isEmpty {
                Text(question.heading)
                    .font(.caption2.weight(.semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Button {
                reader.scrollTo(question.id)
            } label: {
                Text(question.text)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            content
        }
        .padding(.vertical, 6)
        .listRowBackground(focused ? Color.accentColor.opacity(0.10) : Color.clear)
    }

    @ViewBuilder
    private var content: some View {
        switch state.status {
        case .idle:
            HStack(spacing: 10) {
                Button("Write answer") { reader.beginEdit(question.id) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                if !reader.paragraphText(question.id).isEmpty {
                    Button("Use paragraph") { reader.useParagraph(question.id) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        case .done:
            AnswerText(text: state.text)
            HStack(spacing: 16) {
                Text(state.note)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button {
                    UIPasteboard.general.string = state.text
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Copy")
                Button {
                    reader.beginEdit(question.id)
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Edit")
            }
            .font(.footnote)
        }
    }
}

extension View {
    /// The Files picker for a Perla answers file. `done` gets a short message for the person.
    func answersImporter(isPresented: Binding<Bool>, done: @escaping (String) -> Void) -> some View {
        fileImporter(isPresented: isPresented, allowedContentTypes: [.json, .plainText, .text]) { result in
            switch result {
            case .success(let url):
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    let data = try Data(contentsOf: url)
                    let n = try ImportedAnswers.shared.importFile(data)
                    done(n == 0 ? "No answers found in that file." : "Imported \(n) answers.")
                } catch {
                    done("That file couldn't be read as a Perla answers file.")
                }
            case .failure(let error):
                done(error.localizedDescription)
            }
        }
    }
}

enum Printer {
    /// Prints the questions and answers in a large, easy-to-read layout.
    @MainActor
    static func present(title: String, items: [(heading: String, question: String, answer: String)]) {
        let doc = NSMutableAttributedString()
        let spacing = NSMutableParagraphStyle()
        spacing.lineSpacing = 3
        spacing.paragraphSpacing = 6

        doc.append(NSAttributedString(string: title + "\n\n", attributes: [
            .font: UIFont.systemFont(ofSize: 20, weight: .bold),
        ]))
        for item in items {
            if !item.heading.isEmpty {
                doc.append(NSAttributedString(string: item.heading.uppercased() + "\n", attributes: [
                    .font: UIFont.systemFont(ofSize: 10, weight: .semibold),
                    .foregroundColor: UIColor.gray,
                ]))
            }
            doc.append(NSAttributedString(string: item.question + "\n", attributes: [
                .font: UIFont.systemFont(ofSize: 15, weight: .semibold),
                .paragraphStyle: spacing,
            ]))
            doc.append(NSAttributedString(string: (item.answer.isEmpty ? "—" : item.answer) + "\n\n", attributes: [
                .font: UIFont.systemFont(ofSize: 15),
                .paragraphStyle: spacing,
            ]))
        }

        let formatter = UISimpleTextPrintFormatter(attributedText: doc)
        formatter.perPageContentInsets = UIEdgeInsets(top: 48, left: 48, bottom: 48, right: 48)
        let info = UIPrintInfo(dictionary: nil)
        info.outputType = .general
        info.jobName = title
        let controller = UIPrintInteractionController.shared
        controller.printInfo = info
        controller.printFormatter = formatter
        controller.present(animated: true, completionHandler: nil)
    }
}
