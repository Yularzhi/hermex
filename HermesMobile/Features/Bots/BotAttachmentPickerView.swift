import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

enum BotAttachmentPicker: Equatable { case photos, files, camera }

/// Presentation only. The native + menu and attachment strip live in the same
/// composer positions as Sessions; imports still belong to the Bot draft.
struct BotAttachmentPickerPresentation: ViewModifier {
    let model: BotConversation
    @Binding var picker: BotAttachmentPicker?
    @State private var photos: [PhotosPickerItem] = []

    func body(content: Content) -> some View {
        content
            .photosPicker(isPresented: presented(.photos), selection: $photos,
                          maxSelectionCount: 8, matching: .images)
            .fileImporter(isPresented: presented(.files), allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { BotAttachmentPaste.files(urls, model: model) }
                else if case .failure(let error) = result,
                        (error as NSError).code != NSUserCancelledError { model.attachments.report(error) }
            }
            .fullScreenCover(isPresented: presented(.camera)) {
                CameraPickerView { image in BotAttachmentPaste.images([image], model: model) }
                    .ignoresSafeArea()
            }
            .task(id: photos) {
                for photo in photos {
                    guard model.mayImportAttachments, !Task.isCancelled else { break }
                    await model.attachments.importValue {
                        guard let data = try await photo.loadTransferable(type: Data.self) else { throw BotAttachmentFailure.unreadable }
                        let ext = photo.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
                        return (data, "photo.\(ext)")
                    }
                }
                photos = []
            }
    }

    private func presented(_ value: BotAttachmentPicker) -> Binding<Bool> {
        Binding(get: { picker == value }, set: { if $0 { picker = value } else if picker == value { picker = nil } })
    }
}

@MainActor enum BotAttachmentPaste {
    static func files(_ urls: [URL], model: BotConversation) {
        Task {
            for url in urls {
                guard model.mayImportAttachments else { return }
                await model.attachments.importValue {
                    try await Task.detached { try BotAttachmentDraft.readFile(url) }.value
                }
            }
        }
    }

    static func providers(_ providers: [NSItemProvider], model: BotConversation) {
        Task {
            for provider in providers {
                guard model.mayImportAttachments else { return }
                await model.attachments.importValue {
                    try await withCheckedThrowingContinuation { continuation in
                        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                                if let error { continuation.resume(throwing: error); return }
                                let url = (item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                                do {
                                    guard let url else { throw BotAttachmentFailure.unreadable }
                                    continuation.resume(returning: try BotAttachmentDraft.readFile(url))
                                } catch { continuation.resume(throwing: error) }
                            }
                        } else if let type = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .image) == true }) {
                            provider.loadDataRepresentation(forTypeIdentifier: type) { data, error in
                                if let error { continuation.resume(throwing: error); return }
                                guard let data else { continuation.resume(throwing: BotAttachmentFailure.unreadable); return }
                                continuation.resume(returning: (data, "image." + (UTType(type)?.preferredFilenameExtension ?? "jpg")))
                            }
                        } else { continuation.resume(throwing: BotAttachmentFailure.type) }
                    }
                }
            }
        }
    }

    static func images(_ images: [UIImage], model: BotConversation) {
        Task {
            for image in images {
                guard model.mayImportAttachments else { return }
                await model.attachments.importValue {
                    guard let data = image.jpegData(compressionQuality: 0.9) else { throw BotAttachmentFailure.unreadable }
                    return (data, "image.jpg")
                }
            }
        }
    }
}
