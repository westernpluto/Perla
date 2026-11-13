import SwiftUI
import UniformTypeIdentifiers

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
                    done(n == 0 ? L("No answers found in that file.") : L("Imported %lld answers.", n))
                } catch {
                    done(L("That file couldn't be read as a Perla answers file."))
                }
            case .failure(let error):
                done(error.localizedDescription)
            }
        }
    }
}
