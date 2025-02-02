import Foundation
import UIKit
import Display
import SwiftSignalKit
import Postbox
import TelegramCore
import TelegramPresentationData

private final class ResetPasswordControllerArguments {
    let updateCodeText: (String) -> Void
    let openHelp: () -> Void
    
    init(updateCodeText: @escaping (String) -> Void, openHelp: @escaping () -> Void) {
        self.updateCodeText = updateCodeText
        self.openHelp = openHelp
    }
}

private enum ResetPasswordSection: Int32 {
    case code
    case help
}

private enum ResetPasswordEntryTag: ItemListItemTag {
    case code
    
    func isEqual(to other: ItemListItemTag) -> Bool {
        if let other = other as? ResetPasswordEntryTag {
            return self == other
        } else {
            return false
        }
    }
}

private enum ResetPasswordEntry: ItemListNodeEntry, Equatable {
    case code(PresentationTheme, String, String)
    case codeInfo(PresentationTheme, String)
    case helpInfo(PresentationTheme, String)
    
    var section: ItemListSectionId {
        switch self {
            case .code, .codeInfo:
                return ResetPasswordSection.code.rawValue
            case .helpInfo:
                return ResetPasswordSection.help.rawValue
        }
    }
    
    var stableId: Int32 {
        switch self {
            case .code:
                return 0
            case .codeInfo:
                return 1
            case .helpInfo:
                return 2
        }
    }
    
    static func <(lhs: ResetPasswordEntry, rhs: ResetPasswordEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }
    
    func item(_ arguments: ResetPasswordControllerArguments) -> ListViewItem {
        switch self {
            case let .code(theme, text, value):
                return ItemListSingleLineInputItem(theme: theme, title: NSAttributedString(string: text), text: value, placeholder: "", type: .number, spacing: 10.0, tag: ResetPasswordEntryTag.code, sectionId: self.section, textUpdated: { updatedText in
                    arguments.updateCodeText(updatedText)
                }, action: {
                })
            case let .codeInfo(theme, text):
                return ItemListTextItem(theme: theme, text: .plain(text), sectionId: self.section)
            case let .helpInfo(theme, text):
                return ItemListTextItem(theme: theme, text: .markdown(text), sectionId: self.section, linkAction: { action in
                    if case .tap = action {
                        arguments.openHelp()
                    }
                })
        }
    }
}

private struct ResetPasswordControllerState: Equatable {
    var code: String = ""
    var checking: Bool = false
}

private func resetPasswordControllerEntries(presentationData: PresentationData, state: ResetPasswordControllerState, pattern: String) -> [ResetPasswordEntry] {
    var entries: [ResetPasswordEntry] = []
    
    entries.append(.code(presentationData.theme, presentationData.strings.TwoStepAuth_RecoveryCode, state.code))
    entries.append(.codeInfo(presentationData.theme, presentationData.strings.TwoStepAuth_RecoveryCodeHelp))
    
    let stringData = presentationData.strings.TwoStepAuth_RecoveryEmailUnavailable(pattern)
    var string = stringData.0
    if let (_, range) = stringData.1.first {
        string.insert(contentsOf: "]()", at: string.index(string.startIndex, offsetBy: range.upperBound))
        string.insert(contentsOf: "[", at: string.index(string.startIndex, offsetBy: range.lowerBound))
    }
    entries.append(.helpInfo(presentationData.theme, string))
    
    return entries
}

enum ResetPasswordState: Equatable {
    case setup(currentPassword: String?)
    case pendingVerification(emailPattern: String)
}

func resetPasswordController(context: AccountContext, emailPattern: String, completion: @escaping () -> Void) -> ViewController {
    let statePromise = ValuePromise(ResetPasswordControllerState(), ignoreRepeated: true)
    let stateValue = Atomic(value: ResetPasswordControllerState())
    let updateState: ((ResetPasswordControllerState) -> ResetPasswordControllerState) -> Void = { f in
        statePromise.set(stateValue.modify { f($0) })
    }
    
    var dismissImpl: (() -> Void)?
    var presentControllerImpl: ((ViewController, ViewControllerPresentationArguments?) -> Void)?
    
    let actionsDisposable = DisposableSet()
    
    let saveDisposable = MetaDisposable()
    actionsDisposable.add(saveDisposable)
    
    let arguments = ResetPasswordControllerArguments(updateCodeText: { updatedText in
        updateState { state in
            var state = state
            state.code = updatedText
            return state
        }
    }, openHelp: {
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        presentControllerImpl?(textAlertController(context: context, title: nil, text: presentationData.strings.TwoStepAuth_RecoveryFailed, actions: [TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_OK, action: {})]), nil)
    })
    
    var initialFocusImpl: (() -> Void)?
    
    let signal = combineLatest(context.sharedContext.presentationData, statePromise.get())
    |> deliverOnMainQueue
    |> map { presentationData, state -> (ItemListControllerState, (ItemListNodeState<ResetPasswordEntry>, ResetPasswordEntry.ItemGenerationArguments)) in
        
        let leftNavigationButton = ItemListNavigationButton(content: .text(presentationData.strings.Common_Cancel), style: .regular, enabled: true, action: {
            dismissImpl?()
        })
        var rightNavigationButton: ItemListNavigationButton?
        if state.checking {
            rightNavigationButton = ItemListNavigationButton(content: .none, style: .activity, enabled: true, action: {})
        } else {
            rightNavigationButton = ItemListNavigationButton(content: .text(presentationData.strings.Common_Done), style: .bold, enabled: !state.code.isEmpty, action: {
                var state: ResetPasswordControllerState?
                updateState { s in
                    state = s
                    return s
                }
                if let state = state, !state.checking, !state.code.isEmpty {
                    updateState { state  in
                        var state = state
                        state.checking = true
                        return state
                    }
                    saveDisposable.set((recoverTwoStepVerificationPassword(network: context.account.network, code: state.code)
                    |> deliverOnMainQueue).start(error: { error in
                        updateState { state in
                            var state = state
                            state.checking = false
                            return state
                        }
                        let text: String
                        switch error {
                            case .invalidCode:
                                text = presentationData.strings.TwoStepAuth_RecoveryCodeInvalid
                            case .codeExpired:
                                text = presentationData.strings.TwoStepAuth_RecoveryCodeExpired
                            case .limitExceeded:
                                text = presentationData.strings.TwoStepAuth_FloodError
                            case .generic:
                                text = presentationData.strings.Login_UnknownError
                        }
                        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
                        presentControllerImpl?(textAlertController(context: context, title: nil, text: text, actions: [TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_OK, action: {})]), nil)
                    }, completed: {
                        completion()
                    }))
                }
            })
        }
        
        let controllerState = ItemListControllerState(theme: presentationData.theme, title: .text(presentationData.strings.TwoStepAuth_RecoveryTitle), leftNavigationButton: leftNavigationButton, rightNavigationButton: rightNavigationButton, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back), animateChanges: false)
        let listState = ItemListNodeState(entries: resetPasswordControllerEntries(presentationData: presentationData, state: state, pattern: emailPattern), style: .blocks, focusItemTag: ResetPasswordEntryTag.code, emptyStateItem: nil, animateChanges: false)
        
        return (controllerState, (listState, arguments))
    }
    |> afterDisposed {
        actionsDisposable.dispose()
    }
    
    let controller = ItemListController(context: context, state: signal)
    dismissImpl = { [weak controller] in
        controller?.view.endEditing(true)
        controller?.dismiss()
    }
    presentControllerImpl = { [weak controller] c, p in
        if let controller = controller {
            controller.present(c, in: .window(.root), with: p)
        }
    }
    initialFocusImpl = { [weak controller] in
        guard let controller = controller, controller.didAppearOnce else {
            return
        }
        var resultItemNode: ItemListSingleLineInputItemNode?
        let _ = controller.frameForItemNode({ itemNode in
            if let itemNode = itemNode as? ItemListSingleLineInputItemNode, let tag = itemNode.tag, tag.isEqual(to: ResetPasswordEntryTag.code) {
                resultItemNode = itemNode
                return true
            }
            return false
        })
        if let resultItemNode = resultItemNode {
            resultItemNode.focus()
        }
    }
    controller.didAppear = { firstTime in
        if !firstTime {
            return
        }
        initialFocusImpl?()
    }
    
    return controller
}
