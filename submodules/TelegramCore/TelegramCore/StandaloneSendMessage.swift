import Foundation
#if os(macOS)
    import PostboxMac
    import SwiftSignalKitMac
    import MtProtoKitMac
    import TelegramApiMac
#else
    import Postbox
    import SwiftSignalKit
    import TelegramApi
    #if BUCK
        import MtProtoKit
    #else
        import MtProtoKitDynamic
    #endif
#endif

public enum StandaloneMedia {
    case image(Data)
    case file(data: Data, mimeType: String, attributes: [TelegramMediaFileAttribute])
}

private enum StandaloneMessageContent {
    case text(String)
    case media(Api.InputMedia, String)
}

private enum StandaloneSendMessageEvent {
    case result(StandaloneMessageContent)
    case progress(Float)
}

public enum StandaloneSendMessageError {
    case generic
}

public func standaloneSendMessage(account: Account, peerId: PeerId, text: String, attributes: [MessageAttribute], media: StandaloneMedia?, replyToMessageId: MessageId?) -> Signal<Float, StandaloneSendMessageError> {
    let content: Signal<StandaloneSendMessageEvent, StandaloneSendMessageError>
    if let media = media {
        switch media {
            case let .image(data):
                content = uploadedImage(account: account, data: data)
                    |> mapError { _ -> StandaloneSendMessageError in return .generic }
                    |> map { next -> StandaloneSendMessageEvent in
                        switch next {
                            case let .progress(progress):
                                return .progress(progress)
                            case let .result(media):
                                return .result(.media(media, text))
                        }
                    }
            case let .file(data, mimeType, attributes):
                content = uploadedFile(account: account, data: data, mimeType: mimeType, attributes: attributes)
                    |> mapError { _ -> StandaloneSendMessageError in return .generic }
                    |> map { next -> StandaloneSendMessageEvent in
                        switch next {
                            case let .progress(progress):
                                return .progress(progress)
                            case let .result(media):
                                return .result(.media(media, text))
                        }
                    }
        }
    } else {
        content = .single(.result(.text(text)))
    }
    
    return content
        |> mapToSignal { event -> Signal<Float, StandaloneSendMessageError> in
            switch event {
                case let .progress(progress):
                    return .single(progress)
                case let .result(result):
                    let sendContent = sendMessageContent(account: account, peerId: peerId, attributes: attributes, content: result) |> map({ _ -> Float in return 1.0 })
                    return .single(1.0) |> then(sendContent |> mapError { _ -> StandaloneSendMessageError in return .generic })
                
            }
        }
}

private func sendMessageContent(account: Account, peerId: PeerId, attributes: [MessageAttribute], content: StandaloneMessageContent) -> Signal<Void, NoError> {
    return account.postbox.transaction { transaction -> Signal<Void, NoError> in
        if peerId.namespace == Namespaces.Peer.SecretChat {
            return .complete()
        } else if let peer = transaction.getPeer(peerId), let inputPeer = apiInputPeer(peer) {
            var uniqueId: Int64 = arc4random64()
            //var forwardSourceInfoAttribute: ForwardSourceInfoAttribute?
            var messageEntities: [Api.MessageEntity]?
            var replyMessageId: Int32?
            
            var flags: Int32 = 0
            
            flags |= (1 << 7)
            
            for attribute in attributes {
                if let replyAttribute = attribute as? ReplyMessageAttribute {
                    replyMessageId = replyAttribute.messageId.id
                } else if let outgoingInfo = attribute as? OutgoingMessageInfoAttribute {
                    uniqueId = outgoingInfo.uniqueId
                } else if let _ = attribute as? ForwardSourceInfoAttribute {
                    //forwardSourceInfoAttribute = attribute
                } else if let attribute = attribute as? TextEntitiesMessageAttribute {
                    messageEntities = apiTextAttributeEntities(attribute, associatedPeers: SimpleDictionary())
                } else if let attribute = attribute as? OutgoingContentInfoMessageAttribute {
                    if attribute.flags.contains(.disableLinkPreviews) {
                        flags |= Int32(1 << 1)
                    }
                }
            }
            
            if let _ = replyMessageId {
                flags |= Int32(1 << 0)
            }
            if let _ = messageEntities {
                flags |= Int32(1 << 3)
            }
            
            let sendMessageRequest: Signal<Api.Updates, NoError>
            switch content {
                case let .text(text):
                    sendMessageRequest = account.network.request(Api.functions.messages.sendMessage(flags: flags, peer: inputPeer, replyToMsgId: replyMessageId, message: text, randomId: uniqueId, replyMarkup: nil, entities: messageEntities))
                    |> `catch` { _ -> Signal<Api.Updates, NoError> in
                        return .complete()
                    }
                case let .media(inputMedia, text):
                    sendMessageRequest = account.network.request(Api.functions.messages.sendMedia(flags: flags, peer: inputPeer, replyToMsgId: replyMessageId, media: inputMedia, message: text, randomId: uniqueId, replyMarkup: nil, entities: messageEntities))
                    |> `catch` { _ -> Signal<Api.Updates, NoError> in
                            return .complete()
                    }
            }
            
            return sendMessageRequest
            |> mapToSignal { result -> Signal<Void, NoError> in
                return .complete()
            }
            |> `catch` { _ -> Signal<Void, NoError> in
                return .complete()
            }
        } else {
            return .complete()
        }
    }
    |> switchToLatest
}

private enum UploadMediaEvent {
    case progress(Float)
    case result(Api.InputMedia)
}

private func uploadedImage(account: Account, data: Data) -> Signal<UploadMediaEvent, StandaloneSendMessageError> {
    return multipartUpload(network: account.network, postbox: account.postbox, source: .data(data), encrypt: false, tag: TelegramMediaResourceFetchTag(statsCategory: .image), hintFileSize: nil, hintFileIsLarge: false)
        |> mapError { _ -> StandaloneSendMessageError in return .generic }
        |> map { next -> UploadMediaEvent in
            switch next {
                case let .inputFile(inputFile):
                    return .result(Api.InputMedia.inputMediaUploadedPhoto(flags: 0, file: inputFile, stickers: nil, ttlSeconds: nil))
                case .inputSecretFile:
                        preconditionFailure()
                case let .progress(progress):
                    return .progress(progress)
            }
        }
}

private func uploadedFile(account: Account, data: Data, mimeType: String, attributes: [TelegramMediaFileAttribute]) -> Signal<UploadMediaEvent, PendingMessageUploadError> {
    return multipartUpload(network: account.network, postbox: account.postbox, source: .data(data), encrypt: false, tag: TelegramMediaResourceFetchTag(statsCategory: statsCategoryForFileWithAttributes(attributes)), hintFileSize: data.count, hintFileIsLarge: false)
        |> mapError { _ -> PendingMessageUploadError in return .generic }
        |> map { next -> UploadMediaEvent in
            switch next {
                case let .inputFile(inputFile):
                    return .result(Api.InputMedia.inputMediaUploadedDocument(flags: 0, file: inputFile, thumb: nil, mimeType: mimeType, attributes: inputDocumentAttributesFromFileAttributes(attributes), stickers: nil, ttlSeconds: nil))
                case .inputSecretFile:
                    preconditionFailure()
                case let .progress(progress):
                    return .progress(progress)
            }
        }
}
