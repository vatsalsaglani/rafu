import RafuCore
import SwiftUI

struct CompanionRequestView: View {
    let row: NotchAgentRow
    let request: CanvasAgentRequest
    let openTerminal: () -> Void
    let report: (String) -> Void

    @State private var expanded = false
    @State private var answers: [String: String] = [:]

    var body: some View {
        let presentation = CompanionRequestPresentation(
            request: request,
            decision: AgentRequestStore.shared.decision(for: row.id, key: request.key))
        VStack(alignment: .leading, spacing: RafuMetrics.space2) {
            Button(action: openTerminal) {
                Label(row.title, systemImage: "terminal")
            }
            .help("Show this agent in its window")
            Text(presentation.title).font(.headline)
            if let command = request.command {
                Text(verbatim: command)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(expanded ? nil : 3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .accessibilityLabel("\(row.cli.displayName) asks to run \(command)")
                if !request.terminalOnly {
                    Button(expanded ? "Show less" : "Show all") { expanded.toggle() }
                }
            }
            if let cwd = request.cwd { Text("In \(cwd)") }
            if let root = request.grantRoot { Text("Write access to \(root)") }
            if let reason = request.reason { Text(verbatim: reason) }
            ForEach(request.permissions.indices, id: \.self) { index in
                Text(verbatim: request.permissions[index])
            }
            switch presentation.controls {
            case .terminal: EmptyView()
            case .sending: Text("Sending answer…")
            case .options(let options):
                ForEach(options, id: \.id) { option in
                    Button(option.label) { choose(option.decision) }
                }
            case .questions(let questions):
                ForEach(questions, id: \.id) { question in
                    if !question.header.isEmpty { Text(verbatim: question.header).bold() }
                    Text(verbatim: question.text)
                    ForEach(question.choices.indices, id: \.self) { index in
                        let choice = question.choices[index]
                        let selected = answers[question.id] == choice.label
                        Button {
                            answers[question.id] = choice.label
                        } label: {
                            Label {
                                VStack(alignment: .leading) {
                                    Text(verbatim: choice.label)
                                    if !choice.detail.isEmpty {
                                        Text(verbatim: choice.detail).font(.caption)
                                    }
                                }
                            } icon: {
                                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            }
                        }
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
                Button("Answer") { choose(.answers(answers)) }
                    .disabled(!request.permits(.answers(answers)))
            }
            Button("Open terminal", action: openTerminal)
        }
        .controlSize(.small)
        .padding(RafuMetrics.space2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private func choose(_ decision: CanvasAgentRequestDecision) {
        let result = AgentRequestStore.shared.choose(
            controllerID: row.id, key: request.key, decision: decision)
        if let message = CompanionRequestPresentation.message(for: result) { report(message) }
    }
}
