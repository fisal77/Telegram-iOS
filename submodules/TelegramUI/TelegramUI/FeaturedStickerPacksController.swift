import Foundation
import UIKit
import Display
import SwiftSignalKit
import Postbox
import TelegramCore
import TelegramPresentationData

private final class FeaturedStickerPacksControllerArguments {
    let account: Account
    
    let openStickerPack: (StickerPackCollectionInfo) -> Void
    let addPack: (StickerPackCollectionInfo) -> Void
    
    init(account: Account, openStickerPack: @escaping (StickerPackCollectionInfo) -> Void, addPack: @escaping (StickerPackCollectionInfo) -> Void) {
        self.account = account
        self.openStickerPack = openStickerPack
        self.addPack = addPack
    }
}

private enum FeaturedStickerPacksSection: Int32 {
    case stickers
}

private enum FeaturedStickerPacksEntryId: Hashable {
    case pack(ItemCollectionId)
    
    var hashValue: Int {
        switch self {
            case let .pack(id):
                return id.hashValue
        }
    }
    
    static func ==(lhs: FeaturedStickerPacksEntryId, rhs: FeaturedStickerPacksEntryId) -> Bool {
        switch lhs {
            case let .pack(id):
                if case .pack(id) = rhs {
                    return true
                } else {
                    return false
                }
        }
    }
}

private enum FeaturedStickerPacksEntry: ItemListNodeEntry {
    case pack(Int32, PresentationTheme, PresentationStrings, StickerPackCollectionInfo, Bool, StickerPackItem?, String, Bool)
    
    var section: ItemListSectionId {
        switch self {
            case .pack:
                return FeaturedStickerPacksSection.stickers.rawValue
        }
    }
    
    var stableId: FeaturedStickerPacksEntryId {
        switch self {
            case let .pack(_, _, _, info, _, _, _, _):
                return .pack(info.id)
        }
    }
    
    static func ==(lhs: FeaturedStickerPacksEntry, rhs: FeaturedStickerPacksEntry) -> Bool {
        switch lhs {
            case let .pack(lhsIndex, lhsTheme, lhsStrings, lhsInfo, lhsUnread, lhsTopItem, lhsCount, lhsInstalled):
                if case let .pack(rhsIndex, rhsTheme, rhsStrings, rhsInfo, rhsUnread, rhsTopItem, rhsCount, rhsInstalled) = rhs {
                    if lhsIndex != rhsIndex {
                        return false
                    }
                    if lhsTheme !== rhsTheme {
                        return false
                    }
                    if lhsStrings !== rhsStrings {
                        return false
                    }
                    if lhsInfo != rhsInfo {
                        return false
                    }
                    if lhsUnread != rhsUnread {
                        return false
                    }
                    if lhsTopItem != rhsTopItem {
                        return false
                    }
                    if lhsCount != rhsCount {
                        return false
                    }
                    if lhsInstalled != rhsInstalled {
                        return false
                    }
                    return true
                } else {
                    return false
                }
        }
    }
    
    static func <(lhs: FeaturedStickerPacksEntry, rhs: FeaturedStickerPacksEntry) -> Bool {
        switch lhs {
            case let .pack(lhsIndex, _, _, _, _, _, _, _):
                switch rhs {
                    case let .pack(rhsIndex, _, _, _, _, _, _, _):
                        return lhsIndex < rhsIndex
                }
        }
    }
    
    func item(_ arguments: FeaturedStickerPacksControllerArguments) -> ListViewItem {
        switch self {
            case let .pack(_, theme, strings, info, unread, topItem, count, installed):
                return ItemListStickerPackItem(theme: theme, strings: strings, account: arguments.account, packInfo: info, itemCount: count, topItem: topItem, unread: unread, control: .installation(installed: installed), editing: ItemListStickerPackItemEditing(editable: false, editing: false, revealed: false, reorderable: false), enabled: true, sectionId: self.section, action: {
                    arguments.openStickerPack(info)
                }, setPackIdWithRevealedOptions: { _, _ in
                }, addPack: {
                    arguments.addPack(info)
                }, removePack: {
                })
        }
    }
}

private struct FeaturedStickerPacksControllerState: Equatable {
    init() {
    }
    
    static func ==(lhs: FeaturedStickerPacksControllerState, rhs: FeaturedStickerPacksControllerState) -> Bool {
        return true
    }
}

private func featuredStickerPacksControllerEntries(presentationData: PresentationData, state: FeaturedStickerPacksControllerState, view: CombinedView, featured: [FeaturedStickerPackItem], unreadPacks: [ItemCollectionId: Bool]) -> [FeaturedStickerPacksEntry] {
    var entries: [FeaturedStickerPacksEntry] = []
    
    if let stickerPacksView = view.views[.itemCollectionInfos(namespaces: [Namespaces.ItemCollection.CloudStickerPacks])] as? ItemCollectionInfosView, !featured.isEmpty {
        if let packsEntries = stickerPacksView.entriesByNamespace[Namespaces.ItemCollection.CloudStickerPacks] {
            var installedPacks = Set<ItemCollectionId>()
            for entry in packsEntries {
                installedPacks.insert(entry.id)
            }
            var index: Int32 = 0
            for item in featured {
                var unread = false
                if let value = unreadPacks[item.info.id] {
                    unread = value
                }
                entries.append(.pack(index, presentationData.theme, presentationData.strings, item.info, unread, item.topItems.first, presentationData.strings.StickerPack_StickerCount(item.info.count), installedPacks.contains(item.info.id)))
                index += 1
            }
        }
    }
    
    return entries
}

public func featuredStickerPacksController(context: AccountContext) -> ViewController {
    let statePromise = ValuePromise(FeaturedStickerPacksControllerState(), ignoreRepeated: true)
    var presentControllerImpl: ((ViewController, ViewControllerPresentationArguments?) -> Void)?
    
    let actionsDisposable = DisposableSet()
    
    let resolveDisposable = MetaDisposable()
    actionsDisposable.add(resolveDisposable)
    
    var presentStickerPackController: ((StickerPackCollectionInfo) -> Void)?
    
    let arguments = FeaturedStickerPacksControllerArguments(account: context.account, openStickerPack: { info in
        presentStickerPackController?(info)
    }, addPack: { info in
        let _ = (loadedStickerPack(postbox: context.account.postbox, network: context.account.network, reference: .id(id: info.id.id, accessHash: info.accessHash), forceActualized: false)
        |> mapToSignal { result -> Signal<Void, NoError> in
            switch result {
                case let .result(info, items, installed):
                    if installed {
                        return .complete()
                    } else {
                        return addStickerPackInteractively(postbox: context.account.postbox, info: info, items: items)
                    }
                case .fetching:
                    break
                case .none:
                    break
            }
            return .complete()
        } |> deliverOnMainQueue).start()
    })
    
    let stickerPacks = Promise<CombinedView>()
    stickerPacks.set(context.account.postbox.combinedView(keys: [.itemCollectionInfos(namespaces: [Namespaces.ItemCollection.CloudStickerPacks])]))
    
    let featured = Promise<[FeaturedStickerPackItem]>()
    featured.set(context.account.viewTracker.featuredStickerPacks())
    
    var previousPackCount: Int?
    var initialUnreadPacks: [ItemCollectionId: Bool] = [:]
    
    let signal = combineLatest(context.sharedContext.presentationData, statePromise.get() |> deliverOnMainQueue, stickerPacks.get() |> deliverOnMainQueue, featured.get() |> deliverOnMainQueue)
        |> deliverOnMainQueue
        |> map { presentationData, state, view, featured -> (ItemListControllerState, (ItemListNodeState<FeaturedStickerPacksEntry>, FeaturedStickerPacksEntry.ItemGenerationArguments)) in
            let packCount: Int? = featured.count
            
            for item in featured {
                if initialUnreadPacks[item.info.id] == nil {
                    initialUnreadPacks[item.info.id] = item.unread
                }
            }
            
            let rightNavigationButton: ItemListNavigationButton? = nil
            let previous = previousPackCount
            previousPackCount = packCount
            
            let controllerState = ItemListControllerState(theme: presentationData.theme, title: .text(presentationData.strings.FeaturedStickerPacks_Title), leftNavigationButton: nil, rightNavigationButton: rightNavigationButton, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back), animateChanges: true)
            
            let listState = ItemListNodeState(entries: featuredStickerPacksControllerEntries(presentationData: presentationData, state: state, view: view, featured: featured, unreadPacks: initialUnreadPacks), style: .blocks, animateChanges: false)
            return (controllerState, (listState, arguments))
        } |> afterDisposed {
            actionsDisposable.dispose()
    }
    
    let controller = ItemListController(context: context, state: signal)
    
    var alreadyReadIds = Set<ItemCollectionId>()
    
    controller.visibleEntriesUpdated = { entries in
        var unreadIds: [ItemCollectionId] = []
        for entry in entries {
            switch entry {
                case let .pack(_, _, _, info, unread, _, _, _):
                    if unread && !alreadyReadIds.contains(info.id) {
                        unreadIds.append(info.id)
                    }
            }
        }
        if !unreadIds.isEmpty {
            alreadyReadIds.formUnion(Set(unreadIds))
            
            let _ = markFeaturedStickerPacksAsSeenInteractively(postbox: context.account.postbox, ids: unreadIds).start()
        }
    }
    
    presentControllerImpl = { [weak controller] c, p in
        if let controller = controller {
            controller.present(c, in: .window(.root), with: p)
        }
    }
    
    presentStickerPackController = { [weak controller] info in
        presentControllerImpl?(StickerPackPreviewController(context: context, stickerPack: .id(id: info.id.id, accessHash: info.accessHash), mode: .settings, parentNavigationController: controller?.navigationController as? NavigationController), ViewControllerPresentationArguments(presentationAnimation: .modalSheet))
    }
    
    return controller
}
