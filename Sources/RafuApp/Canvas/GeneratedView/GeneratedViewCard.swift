import JSONRenderCore
import JSONRenderSwiftUI
import SwiftUI

/// The body of a generated view card: a caption line (who showed it, resets,
/// unsaved state) and the native render of the spec with the Rafu catalog
/// and theme. The board's card chrome (header, border, ports) stays the
/// shell's; this view owns only what is inside the card.
struct GeneratedViewCard: View {
    let card: CanvasCard
    let content: CanvasGeneratedView
    let board: CanvasBoardState
    let session: WorkspaceSession
    @Environment(\.rafuTheme) private var theme

    private var model: GeneratedViewCardModel {
        GeneratedViewModels.shared.model(for: card.id, board: board, session: session)
    }

    var body: some View {
        let model = model
        let jsonTheme = GeneratedViewThemeCache.theme(for: theme)
        VStack(alignment: .leading, spacing: 0) {
            GeneratedViewCaption(content: content, model: model)
            GeneratedViewBody(cardID: card.id, model: model)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(jsonTheme.color.surface)
        .jsonRenderTheme(jsonTheme)
        .environment(\.generatedViewBoardContext, model.boardContext)
        .task(id: content) { await model.sync(content) }
        .onDisappear { GeneratedViewModels.shared.prune() }
        .sheet(item: confirmBinding(model)) { request in
            RafuConfirmPopup(
                symbol: request.isDestructive ? "exclamationmark.triangle" : "questionmark.circle",
                title: request.title, message: request.message,
                actions: [
                    .init(request.confirmTitle, isDestructive: request.isDestructive) {
                        model.answerConfirmation(true)
                    }
                ],
                defaultActionID: request.isDestructive ? nil : request.confirmTitle,
                cancel: { model.answerConfirmation(false) })
        }
        .sheet(isPresented: specBinding(model)) {
            GeneratedViewSpecPopup(title: card.title, specJSON: content.specJSON) {
                model.isShowingSpec = false
            }
        }
    }

    private func confirmBinding(_ model: GeneratedViewCardModel)
        -> Binding<GeneratedViewConfirmRequest?>
    {
        Binding(
            get: { model.confirmRequest },
            set: { value in
                if value == nil, model.confirmRequest != nil { model.answerConfirmation(false) }
            })
    }

    private func specBinding(_ model: GeneratedViewCardModel) -> Binding<Bool> {
        Binding(get: { model.isShowingSpec }, set: { model.isShowingSpec = $0 })
    }
}

/// One quiet line under the card header: "Shown by Claude · 2 minutes ago",
/// then any reset notice, unsaved-state note, or warning count. Words carry
/// the meaning; there is no colour-only signal.
struct GeneratedViewCaption: View {
    let content: CanvasGeneratedView
    let model: GeneratedViewCardModel
    @Environment(\.jsonRenderTheme) private var theme

    var body: some View {
        let parts = captionParts
        HStack(spacing: 6) {
            if GeneratedViewStreams.shared.models[model.cardID] != nil {
                Image(systemName: "waveform")
                    .accessibilityHidden(true)
                Text("Listening…")
            }
            Text(parts.joined(separator: " · "))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .font(theme.type.caption)
        .foregroundStyle(theme.color.textSecondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var captionParts: [String] {
        let provenance = content.provenance
        let verb = provenance.provider == "user" ? "Made by" : "Shown by"
        let date = provenance.updatedAt ?? provenance.createdAt
        var parts = [
            "\(verb) \(provenance.creator)",
            date.formatted(.relative(presentation: .named)),
        ]
        if let notice = model.resetNotice { parts.append(notice.text) }
        if model.stateNotSaved { parts.append("Some state was not saved") }
        if model.warningCount > 0 {
            parts.append(model.warningCount == 1 ? "1 warning" : "\(model.warningCount) warnings")
        }
        return parts
    }
}

/// The rendered spec, the stream while voice fills the card, or a calm
/// fallback when the spec cannot be shown.
struct GeneratedViewBody: View {
    let cardID: CanvasCardID
    let model: GeneratedViewCardModel
    @Environment(\.jsonRenderTheme) private var theme

    var body: some View {
        if let stream = GeneratedViewStreams.shared.models[cardID] {
            ScrollView(.vertical) {
                JSONRenderStreamView(model: stream) { snapshot, store in
                    JSONRenderView(
                        snapshot: snapshot, catalog: RafuCatalog.rafu, store: store,
                        host: model.actionHost)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        } else if let spec = model.spec {
            ScrollView(.vertical) {
                JSONRenderView(
                    spec: spec, catalog: RafuCatalog.rafu, state: model.store,
                    host: model.actionHost, observer: model.actionHost
                )
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        } else if let error = model.decodeError {
            VStack(spacing: 6) {
                Image(systemName: "rectangle.dashed")
                    .font(.system(size: 20))
                    .foregroundStyle(theme.color.textMuted)
                    .accessibilityHidden(true)
                Text("This view cannot be shown")
                    .font(theme.type.bodyEmphasis)
                    .foregroundStyle(theme.color.text)
                Text(error)
                    .font(theme.type.caption)
                    .foregroundStyle(theme.color.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)
        } else {
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
