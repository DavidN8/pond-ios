//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import MatchaProtocol
import MatrixRustSDK
import SwiftUI

typealias EmojiPackScreenViewModelType = StateStoreViewModelV2<EmojiPackScreenViewState, EmojiPackScreenViewAction>

/// Uploads, renames and removes the custom emoji and stickers of one pack, as the web client's `EmojiPackSettingsViewModel`. Each
/// change reads the pack's latest content just before writing and keeps whatever else it holds, other clients' fields and images not
/// shown here included. A room pack is read from the server, as the sliding sync doesn't bring it; the personal pack from the local
/// store, or this session's last write until sync echoes it.
class EmojiPackScreenViewModel: EmojiPackScreenViewModelType, EmojiPackScreenViewModelProtocol {
    private enum SaveError: Error {
        case packFull
        case failed
    }
    
    private let target: EmojiPackTarget
    private let clientProxy: ClientProxyProtocol
    private let customEmojiPacks: CustomEmojiPacks
    /// Reads and changes run one at a time, so each builds on what the previous one wrote.
    private var queue: Task<Void, Never>?
    private var pendingChanges = 0
    
    private let actionsSubject = PassthroughSubject<EmojiPackScreenViewModelAction, Never>()
    var actionsPublisher: AnyPublisher<EmojiPackScreenViewModelAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }
    
    init(target: EmojiPackTarget, clientProxy: ClientProxyProtocol, customEmojiPacks: CustomEmojiPacks, mediaProvider: MediaProviderProtocol?) {
        self.target = target
        self.clientProxy = clientProxy
        self.customEmojiPacks = customEmojiPacks
        let description = switch target {
        case .user:
            UntranslatedL10n.screenMatchaEmojiUserDescription
        case .room(let roomProxy):
            roomProxy.infoPublisher.value.isSpace ? UntranslatedL10n.screenMatchaEmojiSpaceDescription : UntranslatedL10n.screenMatchaEmojiRoomDescription
        }
        super.init(initialViewState: .init(description: description), mediaProvider: mediaProvider)
        
        switch target {
        case .user:
            state.canEdit = true
        case .room(let roomProxy):
            state.canEdit = EmojiPackTarget.canEditRoomPack(roomProxy.infoPublisher.value)
            roomProxy.infoPublisher
                .receive(on: DispatchQueue.main)
                .sink { [weak self] info in
                    self?.state.canEdit = EmojiPackTarget.canEditRoomPack(info)
                }
                .store(in: &cancellables)
        }
        load()
    }
    
    // MARK: - Public
    
    override func process(viewAction: EmojiPackScreenViewAction) {
        switch viewAction {
        case .retry:
            load()
        case .upload(let usage):
            actionsSubject.send(.pickImages(usage))
        case .rename(let shortcode):
            askForNewName(of: shortcode)
        case .remove(let shortcode):
            remove(shortcode)
        }
    }
    
    func upload(urls: [URL], usage: ImageUsage) {
        // A started batch finishes and writes even if the screen closes meanwhile.
        change { [self] () async throws(SaveError) -> String? in
            // Refused and failed files are skipped so the others still get added; the first problem is shown.
            var problem: String?
            var uploads: [UploadedEmoji] = []
            var packBytes: Int?
            if case .room = target {
                packBytes = try await ImagePacks.packBytes(latestContent())
            }
            for url in urls {
                let file = EmojiImageFile(url: url)
                if let rule = ImagePacks.uploadProblem(mimeType: file.mimeType, byteCount: file.byteCount, pixelSize: file.pixelSize) {
                    problem = problem ?? Self.message(rule, fileName: url.lastPathComponent)
                    continue
                }
                if let packBytes, ImagePacks.isPackFull(packBytes: packBytes, adding: uploads.count + 1) {
                    problem = problem ?? UntranslatedL10n.screenMatchaEmojiErrorPackFull
                    break
                }
                if let upload = await upload(file) {
                    uploads.append(upload)
                } else {
                    problem = problem ?? UntranslatedL10n.screenMatchaEmojiErrorUpload(url.lastPathComponent)
                }
            }
            guard !uploads.isEmpty else { return problem }
            // Named against the latest pack, so nobody's image is replaced.
            try await write(ImagePacks.withUploadedEmojis(latestContent(), uploads, usage: usage))
            return problem
        }
    }
    
    /// Waits for the queued reads and changes, as `MatchaRoomStore.settle()` does.
    func settle() async {
        await queue?.value
    }
    
    // MARK: - Private
    
    private func load() {
        state.loadState = .loading
        enqueue { [self] in
            do {
                _ = try await latestContent()
                state.loadState = .loaded
            } catch {
                state.loadState = .failed
            }
        }
    }
    
    private func askForNewName(of shortcode: String) {
        var name = shortcode
        state.bindings.alertInfo = .init(id: .rename,
                                         title: UntranslatedL10n.screenMatchaEmojiNameLabel(":\(shortcode):"),
                                         primaryButton: .init(title: L10n.actionCancel, role: .cancel, action: nil),
                                         secondaryButton: .init(title: L10n.actionSave) { [weak self] in self?.rename(shortcode, to: name) },
                                         textFields: [.init(placeholder: shortcode,
                                                            text: Binding { name } set: { name = $0 },
                                                            autoCapitalization: .never,
                                                            autoCorrectionDisabled: true)])
    }
    
    private func rename(_ shortcode: String, to name: String) {
        let newShortcode = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newShortcode.isEmpty, newShortcode != shortcode else { return }
        change { [self] () async throws(SaveError) -> String? in
            guard ImagePacks.isValidNewShortcode(newShortcode) else { return UntranslatedL10n.screenMatchaEmojiErrorShortcodeInvalid }
            let content = try await latestContent()
            let renamed: JSONValue
            do {
                renamed = try ImagePacks.withRenamedImage(content, from: shortcode, to: newShortcode)
            } catch ImagePackEditError.shortcodeTaken {
                return UntranslatedL10n.screenMatchaEmojiErrorShortcodeTaken(newShortcode)
            } catch {
                // Someone else removed or renamed it meanwhile; the list now shows their change.
                return nil
            }
            try await write(renamed)
            return nil
        }
    }
    
    private func remove(_ shortcode: String) {
        change { [self] () async throws(SaveError) -> String? in
            try await write(ImagePacks.withoutImage(latestContent(), shortcode: shortcode))
            return nil
        }
    }
    
    /// Queues a change, which returns a message to show, if any, and throws when the pack couldn't be read or saved.
    private func change(_ operation: @escaping () async throws(SaveError) -> String?) {
        pendingChanges += 1
        state.isBusy = true
        enqueue { [self] in
            let message: String?
            do {
                message = try await operation()
            } catch SaveError.packFull {
                message = UntranslatedL10n.screenMatchaEmojiErrorPackFull
            } catch {
                message = UntranslatedL10n.screenMatchaEmojiErrorSave
            }
            pendingChanges -= 1
            state.isBusy = pendingChanges > 0
            if let message {
                state.bindings.alertInfo = .init(id: .error, title: L10n.commonError, message: message)
            }
        }
    }
    
    private func enqueue(_ operation: @escaping () async -> Void) {
        queue = Task { [previous = queue] in
            await previous?.value
            await operation()
        }
    }
    
    /// The pack's latest content, which the list then shows; nil when there is none.
    private func latestContent() async throws(SaveError) -> JSONValue? {
        let content: JSONValue?
        switch target {
        case .user:
            guard case .success(let stored) = await customEmojiPacks.latestAccountData(type: ImagePacks.userEmotesEventType) else { throw .failed }
            content = stored
        case .room(let roomProxy):
            guard case .success(let json) = await roomProxy.fetchStateEventContentJSON(type: ImagePacks.roomEmotesEventType, stateKey: "") else {
                throw .failed
            }
            // Content that doesn't parse is never replaced.
            if let json {
                guard let parsed = JSONValue(json: json) else { throw .failed }
                content = parsed
            } else {
                content = nil
            }
        }
        show(content)
        return content
    }
    
    /// Saves the pack, which the list then shows.
    private func write(_ content: JSONValue) async throws(SaveError) {
        switch target {
        case .user:
            if case .failure(let error) = await customEmojiPacks.setAccountData(type: ImagePacks.userEmotesEventType, content: content) {
                throw Self.saveError(error)
            }
        case .room(let roomProxy):
            if case .failure(let error) = await roomProxy.sendRawStateEvent(type: ImagePacks.roomEmotesEventType, stateKey: "", contentJSON: content.jsonString) {
                throw Self.saveError(error)
            }
            // A space's pack applies in its rooms too.
            customEmojiPacks.forgetRooms()
        }
        show(content)
    }
    
    private func show(_ content: JSONValue?) {
        state.emojis = ImagePacks.parseEmojiImages(content)
        state.stickers = ImagePacks.parseImages(content, usage: .sticker)
    }
    
    /// Uploads an image without its file name, which would be public too, as pack images aren't encrypted.
    private func upload(_ file: EmojiImageFile) async -> UploadedEmoji? {
        guard let mimeType = file.mimeType, let pixelSize = file.pixelSize else { return nil }
        var uploadURL = file.url
        if mimeType == "image/jpeg" {
            guard let data = file.jpegWithoutMetadata(),
                  let url = try? FileManager.default.writeDataToTemporaryDirectory(data: data, fileName: "\(UUID().uuidString).jpg") else {
                return nil
            }
            uploadURL = url
        }
        defer {
            if uploadURL != file.url {
                try? FileManager.default.removeItem(at: uploadURL)
            }
        }
        let size = (try? uploadURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? file.byteCount
        let media = MediaInfo.file(fileURL: uploadURL, fileInfo: FileInfo(mimetype: mimeType, size: UInt64(size), thumbnailInfo: nil, thumbnailSource: nil))
        guard case .success(let url) = await clientProxy.uploadMedia(media) else { return nil }
        return UploadedEmoji(fileName: file.url.lastPathComponent, url: url, width: pixelSize.width, height: pixelSize.height, mimeType: mimeType, size: size)
    }
    
    private static func message(_ problem: EmojiUploadProblem, fileName: String) -> String {
        switch problem {
        case .type:
            UntranslatedL10n.screenMatchaEmojiErrorType(fileName)
        case .size:
            UntranslatedL10n.screenMatchaEmojiErrorSize(fileName)
        case .dimensions:
            UntranslatedL10n.screenMatchaEmojiErrorDimensions(fileName)
        }
    }
    
    /// The server refusing the pack as too large (`M_TOO_LARGE`) means it is full.
    private static func saveError(_ error: Error) -> SaveError {
        let sdkError: Error? = switch error {
        case ClientProxyError.sdkError(let error), RoomProxyError.sdkError(let error):
            error
        default:
            nil
        }
        if case .MatrixApi(kind: .tooLarge, _, _, _)? = sdkError as? ClientError {
            return .packFull
        }
        return .failed
    }
}
