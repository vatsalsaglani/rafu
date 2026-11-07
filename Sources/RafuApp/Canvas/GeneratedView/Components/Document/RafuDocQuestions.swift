import JSONRenderClient
import JSONRenderCore
import JSONRenderSwiftUI
import SwiftUI

/// `Questions`: numbered questions, each with its answer options.
@JRComponent(
    "Questions",
    description: "Numbered review questions. items is a list of {text, options: [string]}.",
    slots: ["default"])
nonisolated struct RafuDocQuestions: View {
    @JRProp(description: "Optional title. Default: Questions.") var title: String?
    @JRProp(description: "List of {text: string, options: [string]}.")
    var items: [JSONRenderCore.JSONValue]

    var body: some View {
        RafuDocQuestionsView(title: title, items: items, children: jrContext.children)
    }
}

struct RafuDocQuestionsView: View {
    let title: String?
    let items: [JSONRenderCore.JSONValue]
    let children: JRChildren

    @Environment(\.rafuTheme) private var theme

    private struct Question {
        let text: String
        let options: [String]
    }

    private var questions: [Question] {
        items.compactMap { value in
            guard let object = value.objectValue, let text = object["text"]?.stringValue
            else { return nil }
            let options = (object["options"]?.arrayValue ?? []).compactMap(\.stringValue)
            return Question(text: text, options: options)
        }
    }

    var body: some View {
        let questions = questions
        RafuDocumentFrame {
            RafuDocumentHeader(
                systemImage: "questionmark.bubble", title: title ?? "Questions", badge: nil)
        } content: {
            VStack(alignment: .leading, spacing: RafuMetrics.space3) {
                ForEach(Array(questions.enumerated()), id: \.offset) { index, question in
                    VStack(alignment: .leading, spacing: RafuMetrics.space1) {
                        Text("\(index + 1). \(question.text)")
                            .font(.system(size: 13.5, weight: .medium))
                            .foregroundStyle(theme.palette.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(Array(question.options.enumerated()), id: \.offset) { _, option in
                            Label {
                                Text(option)
                                    .fixedSize(horizontal: false, vertical: true)
                            } icon: {
                                Image(systemName: "circle")
                                    .accessibilityHidden(true)
                            }
                            .font(.system(size: 13))
                            .foregroundStyle(theme.palette.textSecondary)
                            .padding(.leading, RafuMetrics.space3)
                        }
                    }
                }
                RafuDocumentChildren(children: children)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
    }
}
