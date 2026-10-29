//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
@testable import ElementX
import Foundation
import ImageIO
import MatchaProtocol
import MatrixRustSDK
import Testing
import UniformTypeIdentifiers

/// The Emoji screens, with the cases of the web client's `EmojiPackSettingsViewModel.test.ts`, through real image files.
@MainActor
struct EmojiPackScreenViewModelTests {
    private let homeserver = PackHomeserver()
    private let files: ImageFiles
    
    init() throws {
        files = try ImageFiles()
        homeserver.roomPack = Self.pack
    }
    
    // MARK: - Showing a pack
    
    @Test
    func showsTheRoomPacksEmojiFromTheServer() async {
        let viewModel = await makeViewModel()
        
        #expect(viewModel.context.viewState.loadState == .loaded)
        #expect(viewModel.context.viewState.emojis.map(\.shortcode) == ["wave"])
        #expect(viewModel.context.viewState.canEdit)
        #expect(viewModel.context.viewState.description == UntranslatedL10n.screenMatchaEmojiRoomDescription)
    }
    
    @Test
    func showsTheSpaceDescriptionAndAReadOnlyListWithoutPermission() async {
        let homeserver = PackHomeserver(members: .allMembers, isSpace: true)
        homeserver.roomPack = Self.pack
        let viewModel = await makeViewModel(homeserver: homeserver)
        
        #expect(!viewModel.context.viewState.canEdit)
        #expect(viewModel.context.viewState.emojis.map(\.shortcode) == ["wave"])
        #expect(viewModel.context.viewState.description == UntranslatedL10n.screenMatchaEmojiSpaceDescription)
    }
    
    @Test
    func followsPowerLevels() async throws {
        let viewModel = await makeViewModel()
        let powerLevels = RoomPowerLevelsProxyMock(.init())
        powerLevels.canOwnUserSendStateEventReturnValue = false
        let info = RoomInfoProxyMock(JoinedRoomProxyMockConfiguration())
        info.powerLevels = powerLevels
        
        let readOnly = deferFulfillment(viewModel.context.observe(\.viewState.canEdit)) { !$0 }
        homeserver.roomInfo.send(info)
        try await readOnly.fulfill()
    }
    
    @Test
    func retriesAFailedRead() async {
        homeserver.failsReads = true
        let viewModel = await makeViewModel()
        #expect(viewModel.context.viewState.loadState == .failed)
        
        homeserver.failsReads = false
        viewModel.context.send(viewAction: .retry)
        await viewModel.settle()
        #expect(viewModel.context.viewState.loadState == .loaded)
        #expect(viewModel.context.viewState.emojis.map(\.shortcode) == ["wave"])
    }
    
    @Test
    func showsThePacksStickersApartFromItsEmojiAndImagesForBothInEach() async {
        homeserver.roomPack = #"""
        {"images": {"both": {"url": "mxc://server/both"}, "emoji": {"url": "mxc://server/emoji", "usage": ["emoticon"]},
                    "pepe": {"url": "mxc://server/pepe", "usage": ["sticker"]}}}
        """#
        let viewModel = await makeViewModel()
        
        #expect(viewModel.context.viewState.emojis.map(\.shortcode) == ["both", "emoji"])
        #expect(viewModel.context.viewState.stickers.map(\.shortcode) == ["both", "pepe"])
    }
    
    // MARK: - Uploads
    
    @Test
    func uploadsStickersAsStickers() async throws {
        let viewModel = await makeViewModel()
        let picking = deferFulfillment(viewModel.actionsPublisher) { action in
            if case .pickImages(.sticker) = action {
                true
            } else {
                false
            }
        }
        viewModel.context.send(viewAction: .upload(.sticker))
        try await picking.fulfill()
        
        try viewModel.upload(urls: [files.webP("pepe_happy.webp")], usage: .sticker)
        await viewModel.settle()
        
        #expect(homeserver.stateWrites.last?.objectValue?.object("images")?["pepe_happy"]?.objectValue?["usage"] == json(#"["sticker"]"#))
        #expect(viewModel.context.viewState.stickers.map(\.shortcode) == ["pepe_happy", "wave"])
        #expect(viewModel.context.viewState.emojis.map(\.shortcode) == ["wave"])
    }
    
    @Test
    func rejectsUnsupportedOversizedUnreadableAndHugeFilesNamingTheFile() async throws {
        let viewModel = await makeViewModel()
        
        try await expectError(UntranslatedL10n.screenMatchaEmojiErrorType("notes.txt"), after: viewModel, uploading: files.text("notes.txt"))
        try await expectError(UntranslatedL10n.screenMatchaEmojiErrorSize("huge.png"), after: viewModel, uploading: files.image("huge.png", padding: 512 * 1024))
        try await expectError(UntranslatedL10n.screenMatchaEmojiErrorType("fake.png"), after: viewModel, uploading: files.text("fake.png"))
        try await expectError(UntranslatedL10n.screenMatchaEmojiErrorDimensions("photo.png"), after: viewModel,
                              uploading: files.image("photo.png", width: 1025, height: 64))
        
        #expect(homeserver.uploads.isEmpty)
        #expect(homeserver.stateWrites.isEmpty)
    }
    
    @Test
    func uploadsValidFilesWithoutTheirNamesAndWritesOneStateEventKeepingEverythingElse() async throws {
        homeserver.roomPack = #"""
        {"pack": {"display_name": "Crew", "custom": 1}, "other_client_field": true,
         "images": {"wave": {"url": "mxc://server/wave"}, "hidden": {"url": "mxc://server/hidden", "usage": ["sticker"]}}}
        """#
        let viewModel = await makeViewModel()
        let gif = try files.image("wave.gif", type: .gif)
        let webP = try files.webP("hidden!.webp")
        
        try viewModel.upload(urls: [gif, files.text("notes.txt"), gif, webP], usage: .emoticon)
        #expect(viewModel.context.viewState.isBusy)
        await viewModel.settle()
        
        #expect(homeserver.uploads.map(\.mimeType) == ["image/gif", "image/gif", "image/webp"])
        #expect(homeserver.stateWrites.count == 1)
        let content = try #require(homeserver.stateWrites.first?.objectValue)
        #expect(content["other_client_field"] == .bool(true))
        #expect(content.object("pack")?["custom"] == .integer(1))
        let images = try #require(content.object("images"))
        #expect(images.keys.sorted() == ["hidden", "hidden_2", "wave", "wave_2", "wave_3"])
        let gifSize = try #require(gif.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        #expect(images["wave_2"] == json(#"{"url": "mxc://server/wavegif", "info": {"w": 64, "h": 32, "mimetype": "image/gif", "size": \#(gifSize)}, "usage": ["emoticon"]}"#))
        #expect(images["hidden_2"]?.objectValue?.object("info")?.string("mimetype") == "image/webp")
        // The rejected file is reported, and the new emoji show.
        #expect(viewModel.context.alertInfo?.message == UntranslatedL10n.screenMatchaEmojiErrorType("notes.txt"))
        #expect(viewModel.context.viewState.emojis.map(\.shortcode) == ["hidden_2", "wave", "wave_2", "wave_3"])
        #expect(!viewModel.context.viewState.isBusy)
    }
    
    @Test
    func redrawsJPEGsUprightWithoutTheirMetadata() async throws {
        let viewModel = await makeViewModel()
        let photo = try files.image("photo.jpg", type: .jpeg,
                                    properties: [kCGImagePropertyOrientation: 6,
                                                 kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 51.5, kCGImagePropertyGPSLatitudeRef: "N"],
                                                 kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "Home"]])
        
        viewModel.upload(urls: [photo], usage: .emoticon)
        await viewModel.settle()
        
        let upload = try #require(homeserver.uploads.first)
        #expect(upload.mimeType == "image/jpeg")
        let source = try #require(CGImageSourceCreateWithData(upload.data as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyGPSDictionary] == nil)
        #expect((properties[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifUserComment] == nil)
        #expect((properties[kCGImagePropertyOrientation] as? Int ?? 1) == 1)
        // Turned upright, as the photo displays.
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 32)
        #expect(properties[kCGImagePropertyPixelHeight] as? Int == 64)
        #expect(homeserver.stateWrites.first?.objectValue?.object("images")?["photo"]?.objectValue?["info"]
            == json(#"{"w": 32, "h": 64, "mimetype": "image/jpeg", "size": \#(upload.data.count)}"#))
    }
    
    @Test
    func refusesToUploadIntoAFullPackAndSaysSoWhenTheServerFindsItTooLarge() async throws {
        homeserver.roomPack = #"{"images": {"big": {"url": "mxc://server/big", "body": "\#(String(repeating: "x", count: 59800))"}}}"#
        let viewModel = await makeViewModel()
        
        try await expectError(UntranslatedL10n.screenMatchaEmojiErrorPackFull, after: viewModel, uploading: files.image("cat.png"))
        #expect(homeserver.uploads.isEmpty)
        
        homeserver.writeError = .sdkError(ClientError.MatrixApi(kind: .tooLarge, code: "M_TOO_LARGE", msg: "Too large", details: nil))
        viewModel.context.alertInfo = nil
        try await rename(viewModel, "big", to: "bigger")
        #expect(viewModel.context.alertInfo?.message == UntranslatedL10n.screenMatchaEmojiErrorPackFull)
    }
    
    @Test
    func stillAddsTheFilesThatUploadedWhenAnotherUploadFails() async throws {
        homeserver.failingUploads = ["bad.png"]
        let viewModel = await makeViewModel()
        
        try viewModel.upload(urls: [files.image("bad.png"), files.image("good.png")], usage: .emoticon)
        await viewModel.settle()
        
        let images = try #require(homeserver.stateWrites.last?.objectValue?.object("images"))
        #expect(images["good"] != nil)
        #expect(images["bad"] == nil)
        #expect(viewModel.context.alertInfo?.message == UntranslatedL10n.screenMatchaEmojiErrorUpload("bad.png"))
    }
    
    @Test
    func readsTheServersLatestPackBeforeEachWrite() async throws {
        let viewModel = await makeViewModel()
        // Another client adds an emoji after the screen opened.
        homeserver.roomPack = #"{"images": {"wave": {"url": "mxc://server/wave"}, "dog": {"url": "mxc://server/dog"}}}"#
        
        try viewModel.upload(urls: [files.image("cat.png")], usage: .emoticon)
        viewModel.context.send(viewAction: .remove(shortcode: "wave"))
        await viewModel.settle()
        
        #expect(homeserver.stateWrites.count == 2)
        #expect(homeserver.stateWrites.last?.objectValue?.object("images")?.keys.sorted() == ["cat", "dog"])
        #expect(viewModel.context.viewState.emojis.map(\.shortcode) == ["cat", "dog"])
    }
    
    @Test
    func neverWritesWhenTheLatestPackCantBeRead() async {
        let viewModel = await makeViewModel()
        homeserver.failsReads = true
        
        viewModel.context.send(viewAction: .remove(shortcode: "wave"))
        await viewModel.settle()
        
        #expect(homeserver.stateWrites.isEmpty)
        #expect(viewModel.context.alertInfo?.message == UntranslatedL10n.screenMatchaEmojiErrorSave)
    }
    
    // MARK: - Renames and removals
    
    @Test
    func validatesNewNamesAndKeepsTheImageWhenRenaming() async throws {
        homeserver.roomPack = #"{"images": {"wave": {"url": "mxc://server/wave", "body": "Hi"}, "hidden": {"url": "mxc://server/hidden", "usage": ["sticker"]}}}"#
        let viewModel = await makeViewModel()
        
        try await rename(viewModel, "wave", to: "a")
        #expect(viewModel.context.alertInfo?.message == UntranslatedL10n.screenMatchaEmojiErrorShortcodeInvalid)
        try await rename(viewModel, "wave", to: "hidden")
        #expect(viewModel.context.alertInfo?.message == UntranslatedL10n.screenMatchaEmojiErrorShortcodeTaken("hidden"))
        #expect(homeserver.stateWrites.isEmpty)
        
        viewModel.context.alertInfo = nil
        try await rename(viewModel, "wave", to: " hello-there ")
        #expect(viewModel.context.alertInfo == nil)
        #expect(homeserver.stateWrites.last?.objectValue?["images"]
            == json(#"{"hello-there": {"url": "mxc://server/wave", "body": "Hi"}, "hidden": {"url": "mxc://server/hidden", "usage": ["sticker"]}}"#))
        #expect(viewModel.context.viewState.emojis.map(\.shortcode) == ["hello-there"])
    }
    
    @Test
    func ignoresRenamingAnEmojiSomeoneElseJustRemoved() async throws {
        let viewModel = await makeViewModel()
        homeserver.roomPack = #"{"images": {}}"#
        
        try await rename(viewModel, "wave", to: "hello")
        
        #expect(viewModel.context.alertInfo == nil)
        #expect(homeserver.stateWrites.isEmpty)
        #expect(viewModel.context.viewState.emojis.isEmpty)
    }
    
    @Test
    func removesAnEmojiAndForgetsTheRoomsPacks() async {
        homeserver.roomPack = #"{"images": {"wave": {"url": "mxc://server/wave"}, "hidden": {"url": "mxc://server/hidden", "usage": ["sticker"]}}}"#
        let packs = CustomEmojiPacks(clientProxy: homeserver.clientProxy)
        let viewModel = await makeViewModel(packs: packs)
        homeserver.clientProxy.roomInfoRoomIDClosure = { roomID in .success(RoomInfoProxyMock(JoinedRoomProxyMockConfiguration(id: roomID, name: "Room"))) }
        homeserver.clientProxy.stateEventsJSONRoomIDTypeClosure = { _, _ in .success([:]) }
        homeserver.clientProxy.fetchStateEventContentJSONRoomIDTypeStateKeyClosure = { [homeserver] _, _, _ in .success(homeserver.roomPack) }
        #expect(await packs.packs(roomID: "!room:x").emoji(shortcode: "wave") != nil)
        
        viewModel.context.send(viewAction: .remove(shortcode: "wave"))
        await viewModel.settle()
        
        #expect(homeserver.stateWrites.last?.objectValue?.object("images")?.keys.sorted() == ["hidden"])
        #expect(await packs.packs(roomID: "!room:x").isEmpty)
    }
    
    @Test
    func showsAnErrorWhenSavingFails() async {
        homeserver.writeError = .sdkError(RoomProxyMockError.generic)
        let viewModel = await makeViewModel()
        
        viewModel.context.send(viewAction: .remove(shortcode: "wave"))
        await viewModel.settle()
        
        #expect(viewModel.context.alertInfo?.message == UntranslatedL10n.screenMatchaEmojiErrorSave)
        #expect(viewModel.context.viewState.emojis.map(\.shortcode) == ["wave"])
    }
    
    // MARK: - Personal pack
    
    @Test
    func managesThePersonalPackThroughAccountData() async throws {
        homeserver.accountPack = #"{"images": {"smile": {"url": "mxc://server/smile"}}}"#
        let viewModel = await makeViewModel(target: .user)
        #expect(viewModel.context.viewState.canEdit)
        #expect(viewModel.context.viewState.emojis.map(\.shortcode) == ["smile"])
        #expect(viewModel.context.viewState.description == UntranslatedL10n.screenMatchaEmojiUserDescription)
        
        try viewModel.upload(urls: [files.image("smile.png")], usage: .emoticon)
        await viewModel.settle()
        
        #expect(homeserver.stateWrites.isEmpty)
        let size = try #require(files.directory.appending(path: "smile.png").resourceValues(forKeys: [.fileSizeKey]).fileSize)
        #expect(homeserver.accountWrites == [json(#"""
        {"images": {"smile": {"url": "mxc://server/smile"},
                    "smile_2": {"url": "mxc://server/smilepng", "info": {"w": 64, "h": 32, "mimetype": "image/png", "size": \#(size)}, "usage": ["emoticon"]}}}
        """#)])
        // The next change builds on that write, though sync hasn't echoed it.
        viewModel.context.send(viewAction: .remove(shortcode: "smile"))
        await viewModel.settle()
        #expect(homeserver.accountWrites.last?.objectValue?.object("images")?.keys.sorted() == ["smile_2"])
    }
    
    // MARK: - Settings rows
    
    @Test
    func showsTheRoomRowToEditorsOrWhenThePackHasEmojiOrStickers() async {
        let userSession = UserSessionMock(.init(clientProxy: homeserver.clientProxy))
        #expect(await EmojiPackTarget.showsRoomRow(roomProxy: homeserver.roomProxy, userSession: userSession))
        
        let member = PackHomeserver(members: .allMembers)
        #expect(await !EmojiPackTarget.showsRoomRow(roomProxy: member.roomProxy, userSession: userSession))
        member.roomPack = Self.pack
        #expect(await EmojiPackTarget.showsRoomRow(roomProxy: member.roomProxy, userSession: userSession))
        member.roomPack = #"{"images": {"sticker": {"url": "mxc://server/sticker", "usage": ["sticker"]}}}"#
        #expect(await EmojiPackTarget.showsRoomRow(roomProxy: member.roomProxy, userSession: userSession))
        member.roomPack = #"{"images": {"gif": {"url": "mxc://server/gif", "usage": ["gif"]}}}"#
        #expect(await !EmojiPackTarget.showsRoomRow(roomProxy: member.roomProxy, userSession: userSession))
        
        let settings = UserSettings.mock()
        settings.app.matchaWorkspacesEnabled = false
        let flagOff = UserSessionMock(.init(clientProxy: homeserver.clientProxy, userSettings: settings))
        #expect(await !EmojiPackTarget.showsRoomRow(roomProxy: homeserver.roomProxy, userSession: flagOff))
    }
    
    @Test
    func showsTheSettingsRowWhileCustomEmojiAreOn() {
        let settings = UserSettings.mock()
        let viewModel = SettingsScreenViewModel(userSession: UserSessionMock(.init(userSettings: settings)), isBugReportServiceEnabled: false,
                                                isInSecondaryWindow: false, userIndicatorController: UserIndicatorControllerMock())
        #expect(viewModel.context.viewState.showsEmojiPack)
        
        settings.app.matchaWorkspacesEnabled = false
        let flagOff = SettingsScreenViewModel(userSession: UserSessionMock(.init(userSettings: settings)), isBugReportServiceEnabled: false,
                                              isInSecondaryWindow: false, userIndicatorController: UserIndicatorControllerMock())
        #expect(!flagOff.context.viewState.showsEmojiPack)
    }
    
    // MARK: - Helpers
    
    private static let pack = #"{"images": {"wave": {"url": "mxc://server/wave"}, "broken": {"url": "https://example.org/broken.png"}}}"#
    
    private func makeViewModel(target: EmojiPackTarget? = nil, homeserver: PackHomeserver? = nil, packs: CustomEmojiPacks? = nil) async -> EmojiPackScreenViewModel {
        let homeserver = homeserver ?? self.homeserver
        let viewModel = EmojiPackScreenViewModel(target: target ?? .room(homeserver.roomProxy),
                                                 clientProxy: homeserver.clientProxy,
                                                 customEmojiPacks: packs ?? CustomEmojiPacks(clientProxy: homeserver.clientProxy),
                                                 mediaProvider: nil)
        await viewModel.settle()
        return viewModel
    }
    
    private func expectError(_ message: String, after viewModel: EmojiPackScreenViewModel, uploading url: URL,
                             sourceLocation: SourceLocation = #_sourceLocation) async throws {
        viewModel.context.alertInfo = nil
        viewModel.upload(urls: [url], usage: .emoticon)
        await viewModel.settle()
        #expect(viewModel.context.alertInfo?.message == message, sourceLocation: sourceLocation)
    }
    
    /// Types the name into the rename alert and saves.
    private func rename(_ viewModel: EmojiPackScreenViewModel, _ shortcode: String, to name: String) async throws {
        viewModel.context.send(viewAction: .rename(shortcode: shortcode))
        let alert = try #require(viewModel.context.alertInfo)
        #expect(alert.title == UntranslatedL10n.screenMatchaEmojiNameLabel(":\(shortcode):"))
        let field = try #require(alert.textFields?.first)
        let save = try #require(alert.secondaryButton?.action)
        field.text.wrappedValue = name
        viewModel.context.alertInfo = nil
        save()
        await viewModel.settle()
    }
}

/// A room, its pack on the homeserver and the account's personal pack, as the tests set them.
@MainActor
private final class PackHomeserver {
    let clientProxy = ClientProxyMock(.init())
    let roomProxy: JoinedRoomProxyMock
    let roomInfo: CurrentValueSubject<RoomInfoProxyProtocol, Never>
    var roomPack: String?
    var accountPack: String?
    var failsReads = false
    var writeError: RoomProxyError?
    /// File names whose upload fails.
    var failingUploads: Set<String> = []
    private(set) var stateWrites: [JSONValue] = []
    private(set) var accountWrites: [JSONValue] = []
    private(set) var uploads: [(mimeType: String?, data: Data)] = []
    
    init(members: [RoomMemberProxyMock] = .allMembersAsAdmin, isSpace: Bool = false) {
        roomProxy = JoinedRoomProxyMock(.init(id: "!room:x", isSpace: isSpace, members: members))
        roomInfo = CurrentValueSubject(roomProxy.infoPublisher.value)
        roomProxy.infoPublisher = roomInfo.asCurrentValuePublisher()
        roomProxy.fetchStateEventContentJSONTypeStateKeyClosure = { [unowned self] type, stateKey in
            #expect(type == ImagePacks.roomEmotesEventType && stateKey.isEmpty)
            return failsReads ? .failure(.sdkError(RoomProxyMockError.generic)) : .success(roomPack)
        }
        roomProxy.sendRawStateEventTypeStateKeyContentJSONClosure = { [unowned self] type, stateKey, json in
            #expect(type == ImagePacks.roomEmotesEventType && stateKey.isEmpty)
            if let writeError {
                return .failure(writeError)
            }
            stateWrites.append(JSONValue(json: json) ?? .null)
            roomPack = json
            return .success("$\(stateWrites.count)")
        }
        clientProxy.accountDataJSONTypeClosure = { [unowned self] type in
            if failsReads {
                return .failure(.sdkError(ClientProxyMockError.generic))
            }
            return .success(type == ImagePacks.userEmotesEventType ? accountPack : nil)
        }
        // Sync doesn't echo the write, so the local store keeps the old pack.
        clientProxy.setAccountDataTypeContentJSONClosure = { [unowned self] type, json in
            #expect(type == ImagePacks.userEmotesEventType)
            accountWrites.append(JSONValue(json: json) ?? .null)
            return .success(())
        }
        clientProxy.uploadMediaClosure = { [unowned self] media in
            let fileName = media.url.lastPathComponent
            guard !failingUploads.contains(fileName), let data = try? Data(contentsOf: media.url) else {
                return .failure(.sdkError(ClientProxyMockError.generic))
            }
            uploads.append((media.mimeType, data))
            // A redrawn JPEG is uploaded from a temporary file, so its URL can't name it.
            return .success("mxc://server/\(media.mimeType == "image/jpeg" ? "photo" : fileName.filter { $0.isLetter || $0.isNumber })")
        }
    }
}

/// Image and text files written for a test.
private struct ImageFiles {
    let directory = URL.temporaryDirectory.appending(path: "EmojiPackScreenViewModelTests-\(UUID().uuidString)")
    
    init() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    
    /// A red image of `type`, with `padding` bytes after it.
    func image(_ name: String, width: Int = 64, height: Int = 32, type: UTType = .png,
               properties: [CFString: Any] = [:], padding: Int = 0) throws -> URL {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return try write(data as Data + Data(count: padding), name)
    }
    
    /// A 1 × 1 WebP, which ImageIO reads but can't write.
    func webP(_ name: String) throws -> URL {
        try write(#require(Data(base64Encoded: "UklGRiIAAABXRUJQVlA4IBYAAAAwAQCdASoBAAEADsD+JaQAA3AAAAAA")), name)
    }
    
    func text(_ name: String) throws -> URL {
        try write(Data("Not an image".utf8), name)
    }
    
    private func write(_ data: Data, _ name: String) throws -> URL {
        let url = directory.appending(path: name)
        try data.write(to: url)
        return url
    }
}

private func json(_ text: String) -> JSONValue {
    guard let value = JSONValue(json: text) else {
        Issue.record("Invalid JSON in a test: \(text)")
        return .null
    }
    return value
}
