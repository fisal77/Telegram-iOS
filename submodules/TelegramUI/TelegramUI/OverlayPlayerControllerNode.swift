import Foundation
import UIKit
import Display
import AsyncDisplayKit
import SwiftSignalKit
import Postbox
import TelegramCore
import TelegramPresentationData
import TelegramUIPreferences

final class OverlayPlayerControllerNode: ViewControllerTracingNode, UIGestureRecognizerDelegate {
    let ready = Promise<Bool>()
    
    private let context: AccountContext
    private let peerId: PeerId
    private var presentationData: PresentationData
    private let type: MediaManagerPlayerType
    private let requestDismiss: () -> Void
    private let requestShare: (MessageId) -> Void
    
    private let controllerInteraction: ChatControllerInteraction
    
    private var currentIsReversed: Bool
    
    private let dimNode: ASDisplayNode
    private let contentNode: ASDisplayNode
    private let controlsNode: OverlayPlayerControlsNode
    private let historyBackgroundNode: ASDisplayNode
    private let historyBackgroundContentNode: ASDisplayNode
    private var floatingHeaderOffset: CGFloat?
    private var historyNode: ChatHistoryListNode
    private var replacementHistoryNode: ChatHistoryListNode?
    private var replacementHistoryNodeFloatingOffset: CGFloat?
    
    private var validLayout: ContainerViewLayout?
    
    private var presentationDataDisposable: Disposable?
    private let replacementHistoryNodeReadyDisposable = MetaDisposable()
    
    init(context: AccountContext, peerId: PeerId, type: MediaManagerPlayerType,  initialMessageId: MessageId, initialOrder: MusicPlaybackSettingsOrder, requestDismiss: @escaping () -> Void, requestShare: @escaping (MessageId) -> Void) {
        self.context = context
        self.peerId = peerId
        self.presentationData = context.sharedContext.currentPresentationData.with { $0 }
        self.type = type
        self.requestDismiss = requestDismiss
        self.requestShare = requestShare
        
        if case .regular = initialOrder {
            self.currentIsReversed = false
        } else {
            self.currentIsReversed = true
        }
        
        var openMessageImpl: ((MessageId) -> Bool)?
        self.controllerInteraction = ChatControllerInteraction(openMessage: { message, _ in
            if let openMessageImpl = openMessageImpl {
                return openMessageImpl(message.id)
            } else {
                return false
            }
        }, openPeer: { _, _, _ in
        }, openPeerMention: { _ in
        }, openMessageContextMenu: { _, _, _, _ in
        }, navigateToMessage: { _, _ in
        }, clickThroughMessage: {
        }, toggleMessagesSelection: { _, _ in
        }, sendMessage: { _ in
        }, sendSticker: { _, _ in
        }, sendGif: { _ in
        }, requestMessageActionCallback: { _, _, _ in
        }, requestMessageActionUrlAuth: { _, _, _ in
        }, activateSwitchInline: { _, _ in
        }, openUrl: { _, _, _ in
        }, shareCurrentLocation: {
        }, shareAccountContact: {
        }, sendBotCommand: { _, _ in
        }, openInstantPage: { _, _ in
        }, openWallpaper: { _ in
        }, openHashtag: { _, _ in
        }, updateInputState: { _ in
        }, updateInputMode: { _ in
        }, openMessageShareMenu: { _ in
        }, presentController: { _, _ in
        }, navigationController: {
            return nil
        }, presentGlobalOverlayController: { _, _ in
        }, callPeer: { _ in
        }, longTap: { _, _ in
        }, openCheckoutOrReceipt: { _ in
        }, openSearch: {
        }, setupReply: { _ in
        }, canSetupReply: { _ in
            return false
        }, navigateToFirstDateMessage: { _ in
        }, requestRedeliveryOfFailedMessages: { _ in
        }, addContact: { _ in   
        }, rateCall: { _, _ in
        }, requestSelectMessagePollOption: { _, _ in
        }, openAppStorePage: {
        }, displayMessageTooltip: { _, _, _, _ in
        }, seekToTimecode: { _, _, _ in    
        }, requestMessageUpdate: { _ in
        }, cancelInteractiveKeyboardGestures: {
        }, automaticMediaDownloadSettings: MediaAutoDownloadSettings.defaultSettings, pollActionState: ChatInterfacePollActionState())
        
        self.dimNode = ASDisplayNode()
        self.dimNode.backgroundColor = UIColor(white: 0.0, alpha: 0.5)
        
        self.contentNode = ASDisplayNode()
        
        self.controlsNode = OverlayPlayerControlsNode(account: context.account, accountManager: context.sharedContext.accountManager, theme: self.presentationData.theme, status: context.sharedContext.mediaManager.musicMediaPlayerState)
        
        self.historyBackgroundNode = ASDisplayNode()
        self.historyBackgroundNode.isLayerBacked = true
        
        self.historyBackgroundContentNode = ASDisplayNode()
        self.historyBackgroundContentNode.isLayerBacked = true
        self.historyBackgroundContentNode.backgroundColor = self.presentationData.theme.list.plainBackgroundColor
        
        self.historyBackgroundNode.addSubnode(self.historyBackgroundContentNode)
        
        let tagMask: MessageTags
        switch type {
            case .music:
                tagMask = .music
            case .voice:
                tagMask = .voiceOrInstantVideo
        }
        
        self.historyNode = ChatHistoryListNode(context: context, chatLocation: .peer(peerId), tagMask: tagMask, messageId: initialMessageId, controllerInteraction: self.controllerInteraction, selectedMessages: .single(nil), mode: .list(search: false, reversed: currentIsReversed))
        
        super.init()
        
        self.backgroundColor = nil
        self.isOpaque = false
        
        self.historyNode.preloadPages = true
        self.historyNode.stackFromBottom = true
        self.historyNode.updateFloatingHeaderOffset = { [weak self] offset, transition in
            if let strongSelf = self {
                strongSelf.updateFloatingHeaderOffset(offset: offset, transition: transition)
            }
        }
        
        self.controlsNode.updateIsExpanded = { [weak self] in
            if let strongSelf = self, let validLayout = strongSelf.validLayout {
                strongSelf.containerLayoutUpdated(validLayout, transition: .animated(duration: 0.3, curve: .spring))
            }
        }
        
        self.controlsNode.requestCollapse = { [weak self] in
            self?.requestDismiss()
        }
        
        self.controlsNode.requestShare = { [weak self] messageId in
            self?.requestShare(messageId)
        }
        
        self.controlsNode.updateOrder = { [weak self] order in
            if let strongSelf = self {
                let reversed: Bool
                if case .regular = order {
                    reversed = false
                } else {
                    reversed = true
                }
                if reversed != strongSelf.currentIsReversed {
                    strongSelf.currentIsReversed = reversed
                    if let itemId = strongSelf.controlsNode.currentItemId as? PeerMessagesMediaPlaylistItemId {
                        strongSelf.transitionToUpdatedHistoryNode(atMessage: itemId.messageId)
                    }
                }
            }
        }
        
        self.controlsNode.control = { [weak self] action in
            if let strongSelf = self {
                strongSelf.context.sharedContext.mediaManager.playlistControl(action, type: strongSelf.type)
            }
        }
        
        self.addSubnode(self.dimNode)
        self.addSubnode(self.contentNode)
        self.contentNode.addSubnode(self.historyBackgroundNode)
        self.contentNode.addSubnode(self.historyNode)
        self.contentNode.addSubnode(self.controlsNode)
        
        self.historyNode.beganInteractiveDragging = { [weak self] in
            self?.controlsNode.collapse()
        }
        
        openMessageImpl = { [weak self] id in
            if let strongSelf = self, strongSelf.isNodeLoaded, let message = strongSelf.historyNode.messageInCurrentHistoryView(id) {
                return openChatMessage(context: strongSelf.context, message: message, standalone: false, reverseMessageGalleryOrder: false, navigationController: nil, dismissInput: { }, present: { _, _ in }, transitionNode: { _, _ in return nil }, addToTransitionSurface: { _ in }, openUrl: { _ in }, openPeer: { _, _ in }, callPeer: { _ in }, enqueueMessage: { _ in }, sendSticker: nil, setupTemporaryHiddenMedia: { _, _, _ in }, chatAvatarHiddenMedia: { _, _ in})
            }
            return false
        }
        
        self.presentationDataDisposable = context.sharedContext.presentationData.start(next: { [weak self] presentationData in
            if let strongSelf = self {
                if strongSelf.presentationData.theme !== presentationData.theme || strongSelf.presentationData.strings !== presentationData.strings {
                    strongSelf.updatePresentationData(presentationData)
                }
            }
        })
        
        self.ready.set(self.historyNode.historyState.get() |> map { _ -> Bool in
            return true
        } |> take(1))
    }
    
    deinit {
        self.presentationDataDisposable?.dispose()
        self.replacementHistoryNodeReadyDisposable.dispose()
    }
    
    override func didLoad() {
        super.didLoad()
        
        self.dimNode.view.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(self.dimTapGesture(_:))))
        
        let panRecognizer = DirectionalPanGestureRecognizer(target: self, action: #selector(self.panGesture(_:)))
        panRecognizer.delegate = self
        panRecognizer.delaysTouchesBegan = false
        panRecognizer.cancelsTouchesInView = true
        self.view.addGestureRecognizer(panRecognizer)
    }
    
    func updatePresentationData(_ presentationData: PresentationData) {
        self.presentationData = presentationData
        
        self.historyBackgroundContentNode.backgroundColor = self.presentationData.theme.list.plainBackgroundColor
        self.controlsNode.updateTheme(self.presentationData.theme)
    }
    
    func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        self.validLayout = layout
        
        transition.updateFrame(node: self.dimNode, frame: CGRect(origin: CGPoint(), size: layout.size))
        transition.updateFrame(node: self.contentNode, frame: CGRect(origin: CGPoint(), size: layout.size))
        
        let layoutTopInset: CGFloat = max(layout.statusBarHeight ?? 0.0, layout.safeInsets.top)
        
        var insets = UIEdgeInsets()
        insets.left = layout.safeInsets.left
        insets.right = layout.safeInsets.right
        insets.bottom = layout.intrinsicInsets.bottom
        
        if layout.size.width > layout.size.height && self.controlsNode.isExpanded {
            self.controlsNode.isExpanded = false
        }
        
        let maxHeight = layout.size.height - layoutTopInset - floor(56.0 * 0.5)
        
        let controlsHeight = OverlayPlayerControlsNode.heightForLayout(width: layout.size.width, leftInset: layout.safeInsets.left, rightInset: layout.safeInsets.right, maxHeight: maxHeight, isExpanded: self.controlsNode.isExpanded)
        
        let listTopInset = layoutTopInset + controlsHeight
        
        let listNodeSize = CGSize(width: layout.size.width, height: layout.size.height - listTopInset)
        
        insets.top = max(0.0, listNodeSize.height - floor(56.0 * 3.5))
        
        transition.updateFrame(node: self.historyNode, frame: CGRect(origin: CGPoint(x: 0.0, y: listTopInset), size: listNodeSize))
        
        var duration: Double = 0.0
        var curve: UInt = 0
        switch transition {
            case .immediate:
                break
            case let .animated(animationDuration, animationCurve):
                duration = animationDuration
                switch animationCurve {
                    case .easeInOut, .custom:
                        break
                    case .spring:
                        curve = 7
                }
        }
        
        let listViewCurve: ListViewAnimationCurve
        if curve == 7 {
            listViewCurve = .Spring(duration: duration)
        } else {
            listViewCurve = .Default(duration: duration)
        }
        
        let updateSizeAndInsets = ListViewUpdateSizeAndInsets(size: listNodeSize, insets: insets, duration: duration, curve: listViewCurve)
        self.historyNode.updateLayout(transition: transition, updateSizeAndInsets: updateSizeAndInsets)
        if let replacementHistoryNode = replacementHistoryNode {
            let updateSizeAndInsets = ListViewUpdateSizeAndInsets(size: listNodeSize, insets: insets, duration: 0.0, curve: .Default(duration: nil))
            replacementHistoryNode.updateLayout(transition: transition, updateSizeAndInsets: updateSizeAndInsets)
        }
    }
    
    func animateIn() {
        self.layer.animateBoundsOriginYAdditive(from: -self.bounds.size.height, to: 0.0, duration: 0.3, timingFunction: kCAMediaTimingFunctionSpring)
        self.dimNode.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.2)
        self.dimNode.layer.animatePosition(from: CGPoint(x: 0.0, y: -self.bounds.size.height), to: CGPoint(), duration: 0.3, timingFunction: kCAMediaTimingFunctionSpring, removeOnCompletion: true, additive: true)
    }
    
    func animateOut(completion: (() -> Void)?) {
        self.layer.animateBoundsOriginYAdditive(from: self.bounds.origin.y, to: -self.bounds.size.height, duration: 0.3, timingFunction: kCAMediaTimingFunctionSpring, removeOnCompletion: false, completion: { _ in
            completion?()
        })
        self.dimNode.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.2, removeOnCompletion: false)
        self.dimNode.layer.animatePosition(from: CGPoint(), to: CGPoint(x: 0.0, y: -self.bounds.size.height), duration: 0.3, timingFunction: kCAMediaTimingFunctionSpring, removeOnCompletion: false, additive: true)
    }
    
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if !self.bounds.contains(point) {
            return nil
        }
        if point.y < self.controlsNode.frame.minY {
            return self.dimNode.view
        }
        let result = super.hitTest(point, with: event)
        if self.controlsNode.frame.contains(point) {
//            if result == self.historyNode.view {
//                return self.view
//            }
        }
        return result
    }
    
    @objc func dimTapGesture(_ recognizer: UITapGestureRecognizer) {
        if case .ended = recognizer.state {
            self.requestDismiss()
        }
    }
    
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if let recognizer = gestureRecognizer as? UIPanGestureRecognizer {
            let location = recognizer.location(in: self.view)
            if let view = super.hitTest(location, with: nil) {
                if let gestureRecognizers = view.gestureRecognizers, view != self.view {
                    for gestureRecognizer in gestureRecognizers {
                        if let panGestureRecognizer = gestureRecognizer as? UIPanGestureRecognizer, gestureRecognizer.isEnabled {
                            panGestureRecognizer.isEnabled = false
                            panGestureRecognizer.isEnabled = true
                        }
                    }
                }
            }
        }
        return true
    }
    
    @objc func panGesture(_ recognizer: UIPanGestureRecognizer) {
        switch recognizer.state {
            case .began:
                break
            case .changed:
                let translation = recognizer.translation(in: self.contentNode.view)
                var bounds = self.contentNode.bounds
                bounds.origin.y = -translation.y
                bounds.origin.y = min(0.0, bounds.origin.y)
                if bounds.origin.y < 0.0 {
                    //let delta = -bounds.origin.y
                    //bounds.origin.y = -((1.0 - (1.0 / (((delta) * 0.55 / (50.0)) + 1.0))) * 50.0)
                }
                
                self.contentNode.bounds = bounds
            case .ended:
                let translation = recognizer.translation(in: self.contentNode.view)
                var bounds = self.contentNode.bounds
                bounds.origin.y = -translation.y
                if bounds.origin.y < 0.0 {
                    //let delta = -bounds.origin.y
                    //bounds.origin.y = -((1.0 - (1.0 / (((delta) * 0.55 / (50.0)) + 1.0))) * 50.0)
                }
                
                let velocity = recognizer.velocity(in: self.contentNode.view)
                
                if (bounds.minY < -60.0 || velocity.y > 300.0) {
                    self.requestDismiss()
                } else {
                    let previousBounds = self.bounds
                    var bounds = self.bounds
                    bounds.origin.y = 0.0
                    self.contentNode.bounds = bounds
                    self.contentNode.layer.animateBounds(from: previousBounds, to: self.contentNode.bounds, duration: 0.3, timingFunction: kCAMediaTimingFunctionEaseInEaseOut)
                }
            case .cancelled:
                let previousBounds = self.contentNode.bounds
                var bounds = self.contentNode.bounds
                bounds.origin.y = 0.0
                self.contentNode.bounds = bounds
                self.contentNode.layer.animateBounds(from: previousBounds, to: self.contentNode.bounds, duration: 0.3, timingFunction: kCAMediaTimingFunctionEaseInEaseOut)
            default:
                break
        }
    }
    
    private func updateFloatingHeaderOffset(offset: CGFloat, transition: ContainedViewLayoutTransition) {
        guard let validLayout = self.validLayout else {
            return
        }
        
        self.floatingHeaderOffset = offset
        
        let layoutTopInset: CGFloat = max(validLayout.statusBarHeight ?? 0.0, validLayout.safeInsets.top)
        
        let maxHeight = validLayout.size.height - layoutTopInset - floor(56.0 * 0.5)
        
        let controlsHeight = self.controlsNode.updateLayout(width: validLayout.size.width, leftInset: validLayout.safeInsets.left, rightInset: validLayout.safeInsets.right, maxHeight: maxHeight, transition: transition)
        
        let listTopInset = layoutTopInset + controlsHeight
        
        let rawControlsOffset = offset + listTopInset - controlsHeight
        let controlsOffset = max(layoutTopInset, rawControlsOffset)
        let isOverscrolling = rawControlsOffset <= layoutTopInset
        let controlsFrame = CGRect(origin: CGPoint(x: 0.0, y: controlsOffset), size: CGSize(width: validLayout.size.width, height: controlsHeight))
        
        let previousFrame = self.controlsNode.frame
        
        if !controlsFrame.equalTo(previousFrame) {
            self.controlsNode.frame = controlsFrame
            
            let positionDelta = CGPoint(x: controlsFrame.minX - previousFrame.minX, y: controlsFrame.minY - previousFrame.minY)
            
            transition.animateOffsetAdditive(node: self.controlsNode, offset: positionDelta.y)
        }
        
        transition.updateAlpha(node: self.controlsNode.separatorNode, alpha: isOverscrolling ? 1.0 : 0.0)
        
        let backgroundFrame = CGRect(origin: CGPoint(x: 0.0, y: controlsFrame.maxY), size: CGSize(width: validLayout.size.width, height: validLayout.size.height))
        
        let previousBackgroundFrame = self.historyBackgroundNode.frame
        
        if !backgroundFrame.equalTo(previousBackgroundFrame) {
            self.historyBackgroundNode.frame = backgroundFrame
            self.historyBackgroundContentNode.frame = CGRect(origin: CGPoint(), size: backgroundFrame.size)
            
            let positionDelta = CGPoint(x: backgroundFrame.minX - previousBackgroundFrame.minX, y: backgroundFrame.minY - previousBackgroundFrame.minY)
            
            transition.animateOffsetAdditive(node: self.historyBackgroundNode, offset: positionDelta.y)
        }
    }
    
    private func transitionToUpdatedHistoryNode(atMessage messageId: MessageId) {
        let tagMask: MessageTags
        switch self.type {
            case .music:
                tagMask = .music
            case .voice:
                tagMask = .voiceOrInstantVideo
        }
        
        let historyNode = ChatHistoryListNode(context: self.context, chatLocation: .peer(self.peerId), tagMask: tagMask, messageId: messageId, controllerInteraction: self.controllerInteraction, selectedMessages: .single(nil), mode: .list(search: false, reversed: self.currentIsReversed))
        historyNode.preloadPages = true
        historyNode.stackFromBottom = true
        historyNode.updateFloatingHeaderOffset = { [weak self] offset, _ in
            self?.replacementHistoryNodeFloatingOffset = offset
        }
        self.replacementHistoryNode = historyNode
        if let layout = self.validLayout {
            let layoutTopInset: CGFloat = max(layout.statusBarHeight ?? 0.0, layout.safeInsets.top)
            
            var insets = UIEdgeInsets()
            insets.left = layout.safeInsets.left
            insets.right = layout.safeInsets.right
            insets.bottom = layout.intrinsicInsets.bottom
            
            let maxHeight = layout.size.height - layoutTopInset - floor(56.0 * 0.5)
            
            let controlsHeight = OverlayPlayerControlsNode.heightForLayout(width: layout.size.width, leftInset: layout.safeInsets.left, rightInset: layout.safeInsets.right, maxHeight: maxHeight, isExpanded: self.controlsNode.isExpanded)
            
            let listTopInset = layoutTopInset + controlsHeight
            
            let listNodeSize = CGSize(width: layout.size.width, height: layout.size.height - listTopInset)
            
            insets.top = max(0.0, listNodeSize.height - floor(56.0 * 3.5))
            
            historyNode.frame = CGRect(origin: CGPoint(x: 0.0, y: listTopInset), size: listNodeSize)
            
            let updateSizeAndInsets = ListViewUpdateSizeAndInsets(size: listNodeSize, insets: insets, duration: 0.0, curve: .Default(duration: nil))
            historyNode.updateLayout(transition: .immediate, updateSizeAndInsets: updateSizeAndInsets)
        }
        self.replacementHistoryNodeReadyDisposable.set((historyNode.historyState.get() |> take(1) |> deliverOnMainQueue).start(next: { [weak self] _ in
            if let strongSelf = self {
                strongSelf.replaceWithReadyUpdatedHistoryNode()
            }
        }))
    }
    
    private func replaceWithReadyUpdatedHistoryNode() {
        if let replacementHistoryNode = self.replacementHistoryNode {
            self.replacementHistoryNode = nil
            
            let previousHistoryNode = self.historyNode
            previousHistoryNode.disconnect()
            self.contentNode.insertSubnode(replacementHistoryNode, belowSubnode: self.historyNode)
            self.historyNode = replacementHistoryNode
            
            if let validLayout = self.validLayout, let offset = self.replacementHistoryNodeFloatingOffset, let previousOffset = self.floatingHeaderOffset {
                let offsetDelta = offset - previousOffset
                
                let layoutTopInset: CGFloat = max(validLayout.statusBarHeight ?? 0.0, validLayout.safeInsets.top)
                
                let maxHeight = validLayout.size.height - layoutTopInset - floor(56.0 * 0.5)
                
                let controlsHeight = OverlayPlayerControlsNode.heightForLayout(width: validLayout.size.width, leftInset: validLayout.safeInsets.left, rightInset: validLayout.safeInsets.right, maxHeight: maxHeight, isExpanded: self.controlsNode.isExpanded)
                
                let listTopInset = layoutTopInset + controlsHeight
                
                let controlsBottomOffset = max(layoutTopInset, offset + listTopInset)
                
                let previousBackgroundNode = ASDisplayNode()
                previousBackgroundNode.isLayerBacked = true
                previousBackgroundNode.backgroundColor = self.historyBackgroundContentNode.backgroundColor
                self.contentNode.insertSubnode(previousBackgroundNode, belowSubnode: previousHistoryNode)
                previousBackgroundNode.frame = self.historyBackgroundNode.frame
                
                previousBackgroundNode.layer.animateFrame(from: previousBackgroundNode.frame, to: CGRect(origin: CGPoint(x: 0.0, y: controlsBottomOffset), size: validLayout.size), duration: 0.2, timingFunction: kCAMediaTimingFunctionSpring, removeOnCompletion: false)
                
                self.updateFloatingHeaderOffset(offset: offset, transition: .animated(duration: 0.4, curve: .spring))
                previousHistoryNode.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.2, removeOnCompletion: false, completion: { [weak previousHistoryNode] _ in
                    previousHistoryNode?.removeFromSupernode()
                })
                previousHistoryNode.layer.animatePosition(from: CGPoint(), to: CGPoint(x: 0.0, y: offsetDelta), duration: 0.4, timingFunction: kCAMediaTimingFunctionSpring, removeOnCompletion: true, additive: true)
                previousBackgroundNode.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.2, removeOnCompletion: false, completion: { [weak previousBackgroundNode] _ in
                    previousBackgroundNode?.removeFromSupernode()
                })
                self.historyNode.layer.animatePosition(from: CGPoint(x: 0.0, y: -offsetDelta), to: CGPoint(), duration: 0.4, timingFunction: kCAMediaTimingFunctionSpring, removeOnCompletion: true, additive: true)
            } else {
                previousHistoryNode.removeFromSupernode()
            }
            
            self.historyNode.updateFloatingHeaderOffset = { [weak self] offset, transition in
                if let strongSelf = self {
                    strongSelf.updateFloatingHeaderOffset(offset: offset, transition: transition)
                }
            }
            
            self.historyNode.beganInteractiveDragging = { [weak self] in
                self?.controlsNode.collapse()
            }
            
            if let layout = self.validLayout {
                let layoutTopInset: CGFloat = max(layout.statusBarHeight ?? 0.0, layout.safeInsets.top)
                
                var insets = UIEdgeInsets()
                insets.left = layout.safeInsets.left
                insets.right = layout.safeInsets.right
                insets.bottom = layout.intrinsicInsets.bottom
                
                let maxHeight = layout.size.height - layoutTopInset - floor(56.0 * 0.5)
                
                let controlsHeight = OverlayPlayerControlsNode.heightForLayout(width: layout.size.width, leftInset: layout.safeInsets.left, rightInset: layout.safeInsets.right, maxHeight: maxHeight, isExpanded: self.controlsNode.isExpanded)
                
                let listTopInset = layoutTopInset + controlsHeight
                
                let listNodeSize = CGSize(width: layout.size.width, height: layout.size.height - listTopInset)
                
                insets.top = max(0.0, listNodeSize.height - floor(56.0 * 3.5))
                
                self.historyNode.frame = CGRect(origin: CGPoint(x: 0.0, y: listTopInset), size: listNodeSize)
                
                let updateSizeAndInsets = ListViewUpdateSizeAndInsets(size: listNodeSize, insets: insets, duration: 0.0, curve: .Default(duration: nil))
                self.historyNode.updateLayout(transition: .immediate, updateSizeAndInsets: updateSizeAndInsets)
                
                self.historyNode.recursivelyEnsureDisplaySynchronously(true)
            }
        }
    }
}
