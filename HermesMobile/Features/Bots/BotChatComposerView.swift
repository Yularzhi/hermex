import SwiftUI
import UIKit

/// Sessions presentation with Bot-owned draft and action rules. The same editor
/// stays mounted through focus changes; no webui runtime controls are involved.
struct BotChatComposerView: View {
    let model: BotConversation
    let onStop: () -> Void
    let onReconnect: () -> Void
    let onResolveHeldMessage: () -> Void
    /// Scrolls the transcript back to the pending request card.
    let onShowRequest: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(HeaderLogoColor.storageKey) private var themeHex = HeaderLogoColor.defaultHex
    @AppStorage(PrimaryActionTintSettings.isEnabledKey) private var tintsPrimaryActions = false
    @ScaledMetric(relativeTo: .body) private var actionIconSize: CGFloat = 16
    @ScaledMetric(relativeTo: .body) private var plusIconSize: CGFloat = 20
    @State private var shouldRestoreFocusAfterPicker = false
    @State private var picker: BotAttachmentPicker?
    @State private var preview: PendingAttachment?
    @State private var isFocused = false
    @State private var selection = ComposerSelection()
    @State private var inputHeight: CGFloat = 22
    @State private var measuredHeight: CGFloat = 0
    @State private var keyboardIsVisible = false

    @State private var mode = BotPromptMode.send
    @State private var confirmingHeldSend = false
    @State private var redirectAction: BotConversation.PromptAction?

    private var isExpanded: Bool { isFocused || picker != nil || shouldRestoreFocusAfterPicker || preview != nil || model.submittingPrompt != nil }
    private var showsToolbar: Bool { isExpanded || mode != .send }
    private var showsStop: Bool { model.mayStop || model.turn == .stopping }
    private var canSend: Bool {
        (model.maySubmit(mode) || model.mayConfirmHeldSubmission) && (!model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.attachments.items.isEmpty)
    }
    private var appearance: ChatComposerActionAppearance {
        ChatComposerActionAppearance(
            isStop: false, isDisabled: !canSend, colorScheme: colorScheme,
            tintsPrimaryActions: tintsPrimaryActions, themeHex: themeHex
        )
    }

    var body: some View {
        AdaptiveGlassContainer(spacing: 6) {
            VStack(spacing: 0) {
                BotChatStatusView(
                    model: model, onReconnect: onReconnect,
                    onResolveHeldMessage: onResolveHeldMessage, onShowRequest: onShowRequest
                )

                if mode != .send && model.maySend {
                    Text("Work finished. Choose Send to start a new turn.")
                        .font(AppFont.footnote()).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16).padding(.bottom, 8)
                }

                if let error = model.attachments.errorMessage {
                    Text(error).font(AppFont.footnote()).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16).padding(.bottom, 6)
                }
                if model.attachments.isImporting {
                    Text("Adding attachment…").font(AppFont.footnote()).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16)
                }

                composerSurface.padding(.horizontal, 16)

                if showsToolbar {
                    HStack(alignment: .center, spacing: 8) {
                        ComposerToolbarScroller {
                            plusMenu
                            modeMenu
                        }
                        promptButtons
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .background(
                        Color(.systemBackground)
                            .padding(.top, -10).padding(.bottom, -12)
                            .ignoresSafeArea(edges: .bottom)
                    )
                    .transition(ChatMotion.bottomOverlayTransition(reduceMotion: reduceMotion))
                }
            }
            // Focus flips arrive from UIKit outside any withAnimation, so the
            // pill-to-card morph and the row's insertion animate from here,
            // exactly as the Sessions composer does.
            .animation(ChatMotion.composerChrome(reduceMotion: reduceMotion), value: isExpanded)
        }
        .modifier(BotAttachmentPickerPresentation(model: model, picker: $picker))
        .sheet(item: $preview) { item in
            BotArtifactPreview(reference: TranscriptMediaReference(rawReference: item.name)) {
                try await model.attachments.data(for: item)
            }
        }
        .task(id: picker) {
            guard picker == nil, shouldRestoreFocusAfterPicker else { return }
            // Match Sessions' short delay while the native picker dismisses.
            do { try await Task.sleep(for: .milliseconds(80)) } catch { return }
            guard picker == nil, shouldRestoreFocusAfterPicker else { return }
            shouldRestoreFocusAfterPicker = false
            if model.mayEditDraft { isFocused = true }
        }
        .onDisappear { shouldRestoreFocusAfterPicker = false }
        .onChange(of: model.attachments.items.isEmpty) { _, empty in
            if !empty, mode == .steer || mode == .redirect { mode = model.mayGuide ? .queue : .send }
        }
        .padding(.bottom, keyboardIsVisible ? 10 : 0)
        .onChange(of: model.mayGuide) { _, busy in
            if busy && mode == .send { mode = model.attachments.items.isEmpty ? .steer : .queue }
        }
        .onAppear { if model.mayGuide && mode == .send { mode = model.attachments.items.isEmpty ? .steer : .queue } }
        .confirmationDialog("Send this draft?", isPresented: $confirmingHeldSend, titleVisibility: .visible) {
            Button("Send draft") {
                Task {
                    await model.restoreUncertainSubmission()
                    guard !model.uncertainSend else { return }
                    let nextMode: BotPromptMode = model.maySend ? .send : .queue
                    guard let action = model.preparePrompt(nextMode) else { return }
                    mode = nextMode
                    await model.submit(action)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The previous send was not confirmed. Sending this draft could duplicate it if the bot already received it.")
        }
        .confirmationDialog("Redirect this bot's current work?", isPresented: Binding(
            get: { redirectAction != nil }, set: { if !$0 { redirectAction = nil } }
        ), titleVisibility: .visible) {
            if let action = redirectAction {
                Button("Redirect", role: .destructive) {
                    redirectAction = nil
                    Task { await model.submit(action) }
                }
            }
            Button("Cancel", role: .cancel) { redirectAction = nil }
        } message: {
            Text("Interrupt current work and send this direction? During startup, the server may queue it for the next turn.")
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            keyboardIsVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardIsVisible = false
        }
    }

    /// Same pill/card structure as the Sessions composer. The editor keeps its
    /// identity as the attachment strip and controls move around it.
    private var composerSurface: some View {
        VStack(spacing: 0) {
            if isExpanded {
                ComposerAttachmentStripView(attachments: model.attachments.items, onRemove: { id in
                    Task { await model.attachments.remove(id) }
                }, onPreview: { preview = $0 })
                .disabled(!model.mayEditDraft || model.attachments.isImporting)
            }
            HStack(alignment: .center, spacing: 4) {
                ComposerTextInputView(
                    text: Binding(get: { model.draft }, set: { model.editDraft($0) }),
                    selection: $selection, isFocused: $isFocused,
                    inputHeight: $inputHeight, measuredHeight: $measuredHeight,
                    isDisabled: !model.mayEditDraft, isCollapsed: !isExpanded,
                    isKeyboardSendEnabled: canSend, verticalPadding: 12,
                    chipSkills: [], chipFilePaths: [], quotes: [],
                    onKeyboardSend: send,
                    onPasteFileProviders: { BotAttachmentPaste.providers($0, model: model) },
                    onPasteFileURLs: { BotAttachmentPaste.files($0, model: model) },
                    onPasteImageProviders: { BotAttachmentPaste.providers($0, model: model) },
                    onPasteImages: { BotAttachmentPaste.images($0, model: model) },
                    onTapChip: { _ in }, onTapQuote: { _ in }, onRemoveQuote: { _ in },
                    placeholder: String(localized: "Message bot"), acceptsAttachments: model.mayEditDraft
                )
                if !isExpanded {
                    ComposerAttachmentPillPreview(attachments: model.attachments.items, onPreview: { preview = $0 })
                    if !showsToolbar { if showsStop { stopButton } else { actionButton } }
                }
            }
            .padding(.trailing, isExpanded ? 0 : ChatComposerMetrics.pillInset)
            .padding(.vertical, isExpanded ? 0 : ChatComposerMetrics.pillInset)
        }
        .padding(.top, isExpanded ? 2 : 0)
        .padding(.bottom, isExpanded ? 4 : 0)
        .modifier(ChatComposerSurfaceStyle(isExpanded: isExpanded))
    }

    private var plusMenu: some View {
        ChatUIKitMenuButton {
            Image(systemName: "plus")
                .font(.system(size: plusIconSize, weight: .medium))
                .foregroundStyle(Color(.secondaryLabel))
                .frame(width: ChatComposerMetrics.actionSize, height: ChatComposerMetrics.actionSize)
                .adaptiveGlass(.regular, isInteractive: true, fallbackMaterial: .ultraThinMaterial,
                               inheritsClipping: true, in: Circle())
                .clipShape(Circle())
        } menu: {
            UIMenu(children: [UIMenu(title: String(localized: "Attach"), options: [.displayInline], children: [
                attachmentAction(.files, title: String(localized: "Attach File"), image: "paperclip"),
                attachmentAction(.photos, title: String(localized: "Photos"), image: "photo.on.rectangle"),
                attachmentAction(.camera, title: String(localized: "Camera"), image: "camera")
            ])])
        }
        .tint(Color(.secondaryLabel))
        .disabled(!model.mayImportAttachments || model.attachments.isImporting)
        .accessibilityLabel("Composer options")
    }

    private func attachmentAction(_ choice: BotAttachmentPicker, title: String, image: String) -> UIAction {
        UIAction(title: title, image: UIImage(systemName: image),
                 attributes: choice == .camera && !UIImagePickerController.isSourceTypeAvailable(.camera) ? .disabled : []) { _ in
            Task { @MainActor in
                guard model.mayImportAttachments else { return }
                shouldRestoreFocusAfterPicker = isFocused
                isFocused = false
                picker = choice
            }
        }
    }

    private var modeMenu: some View {
        ChatUIKitMenuButton {
            ComposerInlineControlLabel(
                title: mode.title, systemImage: "arrow.turn.up.right",
                color: .secondary, controlFont: AppFont.subheadline(), chevronFont: AppFont.caption2()
            )
        } menu: {
            UIMenu(children: BotPromptMode.allCases.map { option in
                UIAction(title: option.title, subtitle: option.explanation,
                         attributes: model.maySubmit(option) ? [] : [.disabled],
                         state: mode == option ? .on : .off) { _ in
                    mode = option
                }
            })
        }
        .accessibilityLabel(Text("Message action: \(mode.title)"))
        .accessibilityHint(Text(mode.explanation))
    }

    private var promptButtons: some View {
        HStack(spacing: 8) {
            if showsStop { stopButton }
            actionButton
        }
    }

    private var stopButton: some View {
        let colors = ChatComposerActionAppearance(
            isStop: true, isDisabled: !model.mayStop, colorScheme: colorScheme,
            tintsPrimaryActions: tintsPrimaryActions, themeHex: themeHex
        )
        return Button(action: onStop) {
            Image(systemName: "stop.fill")
                .font(.system(size: actionIconSize, weight: .semibold))
                .frame(width: ChatComposerMetrics.actionSize, height: ChatComposerMetrics.actionSize)
                .background(colors.background).foregroundStyle(colors.foreground).clipShape(Circle())
        }
        .buttonStyle(.chatTactile(.icon))
        .disabled(!model.mayStop)
        .accessibilityLabel("Stop current work")
    }

    private var actionButton: some View {
        Button(action: send) {
            Image(systemName: "arrow.up")
                .font(.system(size: actionIconSize, weight: .semibold))
                .frame(width: ChatComposerMetrics.actionSize, height: ChatComposerMetrics.actionSize)
                .background(appearance.background)
                .foregroundStyle(appearance.foreground)
                .clipShape(Circle())
        }
        .buttonStyle(.chatTactile(.icon))
        .disabled(!canSend)
        .accessibilityLabel(Text(mode.title))
        .accessibilityHint(Text(mode.explanation))
        .keyboardShortcut(.return, modifiers: .command)
    }

    private func send() {
        if model.mayConfirmHeldSubmission {
            confirmingHeldSend = true
            return
        }
        guard let action = model.preparePrompt(mode) else { return }
        if mode == .redirect { redirectAction = action }
        else { Task { await model.submit(action) } }
    }
}

/// Ready and connected has no status chrome. Recovery, work and failures appear
/// immediately above the composer, including the existing Desktop-only actions.
private struct BotChatStatusView: View {
    let model: BotConversation
    let onReconnect: () -> Void
    let onResolveHeldMessage: () -> Void
    let onShowRequest: () -> Void

    var body: some View {
        if model.connectionState != .connected || model.turn != .idle || model.errorMessage != nil || model.uncertainSend
            || model.promptReceipt != nil || !model.liveActivity.notices.isEmpty || !model.liveActivity.memoryNotes.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                if let connectionText { Text(connectionText) }
                ForEach(model.liveActivity.notices) { notice in
                    Label(notice.text, systemImage: notice.isWarning ? "exclamationmark.triangle" : "info.circle")
                }
                ForEach(model.liveActivity.memoryNotes, id: \.self) { note in
                    Label(note, systemImage: "brain")
                }
                if let error = model.errorMessage { Text(error) }
                if let receipt = model.promptReceipt { Text(receipt) }
                if model.isUploadingAttachments {
                    HStack {
                        Text("Uploading…")
                        Button("Cancel upload") { model.cancelAttachmentUpload() }
                    }
                } else if model.submittingPrompt != nil {
                    Text("Sending…")
                } else if model.uncertainSend {
                    Text("The previous send was not confirmed. You can edit this draft and try sending again.")
                    if model.connectionState == .connected {
                        Button("Resolve held message…", action: onResolveHeldMessage)
                    }
                } else if model.turn == .needsAttention {
                    // The model ranks a pending request above an unresolved Stop, so
                    // the actionable line wins here too. The card is in the transcript
                    // and may be scrolled away, so this doubles as the way back to it.
                    if model.pendingRequest != nil {
                        Button(action: onShowRequest) {
                            Label(requestText, systemImage: "arrow.down.circle")
                        }
                    } else {
                        // A pending key the phone could not read has no card to show.
                        Text("Needs attention. Answer the request in Hermes Desktop on this same connection.")
                    }
                } else if model.uncertainStop && model.turn != .stopping {
                    Text("Outcome unknown")
                } else if model.connectionState == .connected, let turnText {
                    Text(turnText)
                }
                if model.connectionState == .disconnected {
                    Button("Reconnect", action: onReconnect)
                }
            }
            .font(AppFont.footnote())
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.bottom, 8)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("bot-chat-status")
        }
    }

    /// What the blocked bot is waiting on. "Handling this" is only true where
    /// there is nothing to do: a request the phone can answer or decline has an
    /// action on its card, and saying it is handled would hide that.
    private var requestText: String {
        if model.pendingRequest?.isAnswerable == true { return String(localized: "Waiting for your answer") }
        if model.mayDecline { return String(localized: "Waiting on Hermes Desktop") }
        return String(localized: "Hermes Desktop is handling this")
    }

    private var connectionText: String? {
        switch model.connectionState {
        case .connected: return nil
        case .recovering: return String(localized: "Loading current conversation…")
        case .disconnected: return String(localized: "Disconnected · Last loaded conversation")
        }
    }

    private var turnText: String? {
        switch model.turn {
        case .idle, .needsAttention: return nil
        case .running: return model.workStatus ?? String(localized: "Working")
        case .submitting: return String(localized: "Sending…")
        case .stopping: return String(localized: "Stopping…")
        case .uncertain: return String(localized: "Outcome unknown")
        case .interrupted: return String(localized: "Work was interrupted. The saved conversation is loaded.")
        case .unknown: return String(localized: "Checking current work…")
        }
    }
}
