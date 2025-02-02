import Foundation
import UIKit
import Display
import AsyncDisplayKit
import TelegramPresentationData

final class AuthorizationSequencePasswordEntryController: ViewController {
    private var controllerNode: AuthorizationSequencePasswordEntryControllerNode {
        return self.displayNode as! AuthorizationSequencePasswordEntryControllerNode
    }
    
    private let strings: PresentationStrings
    private let theme: PresentationTheme
    
    var loginWithPassword: ((String) -> Void)?
    var forgot: (() -> Void)?
    var reset: (() -> Void)?
    var hint: String?
    
    var didForgotWithNoRecovery: Bool = false {
        didSet {
            if self.didForgotWithNoRecovery != oldValue {
                if self.isNodeLoaded, let hint = self.hint {
                    self.controllerNode.updateData(hint: hint, didForgotWithNoRecovery: didForgotWithNoRecovery, suggestReset: self.suggestReset)
                }
            }
        }
    }
    
    var suggestReset: Bool = false
    
    private let hapticFeedback = HapticFeedback()
    
    var inProgress: Bool = false {
        didSet {
            if self.inProgress {
                let item = UIBarButtonItem(customDisplayNode: ProgressNavigationButtonNode(color: self.theme.rootController.navigationBar.accentTextColor))
                self.navigationItem.rightBarButtonItem = item
            } else {
                self.navigationItem.rightBarButtonItem = UIBarButtonItem(title: self.strings.Common_Next, style: .done, target: self, action: #selector(self.nextPressed))
            }
            self.controllerNode.inProgress = self.inProgress
        }
    }
    
    init(strings: PresentationStrings, theme: PresentationTheme, back: @escaping () -> Void) {
        self.strings = strings
        self.theme = theme
        
        super.init(navigationBarPresentationData: NavigationBarPresentationData(theme: AuthorizationSequenceController.navigationBarTheme(theme), strings: NavigationBarStrings(presentationStrings: strings)))
        
        self.supportedOrientations = ViewControllerSupportedOrientations(regularSize: .all, compactSize: .portrait)
        
        self.hasActiveInput = true
        
        self.statusBar.statusBarStyle = theme.rootController.statusBar.style.style
        
        self.attemptNavigation = { _ in
            return false
        }
        self.navigationBar?.backPressed = {
            back()
        }
        
        self.navigationItem.rightBarButtonItem = UIBarButtonItem(title: self.strings.Common_Next, style: .done, target: self, action: #selector(self.nextPressed))
    }
    
    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override public func loadDisplayNode() {
        self.displayNode = AuthorizationSequencePasswordEntryControllerNode(strings: self.strings, theme: self.theme)
        self.displayNodeDidLoad()
        
        self.controllerNode.loginWithCode = { [weak self] _ in
            self?.nextPressed()
        }
        
        self.controllerNode.forgot = { [weak self] in
            self?.forgotPressed()
        }
        
        self.controllerNode.reset = { [weak self] in
            self?.resetPressed()
        }
        
        if let hint = self.hint {
            self.controllerNode.updateData(hint: hint, didForgotWithNoRecovery: self.didForgotWithNoRecovery, suggestReset: self.suggestReset)
        }
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        
        self.controllerNode.activateInput()
    }
    
    func updateData(hint: String, suggestReset: Bool) {
        if self.hint != hint || self.suggestReset != suggestReset {
            self.hint = hint
            self.suggestReset = suggestReset
            if self.isNodeLoaded {
                self.controllerNode.updateData(hint: hint, didForgotWithNoRecovery: self.didForgotWithNoRecovery, suggestReset: self.suggestReset)
            }
        }
    }
    
    func passwordIsInvalid() {
        if self.isNodeLoaded {
            self.controllerNode.passwordIsInvalid()
        }
    }
    
    override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        
        self.controllerNode.containerLayoutUpdated(layout, navigationBarHeight: self.navigationHeight, transition: transition)
    }
    
    @objc func nextPressed() {
        if self.controllerNode.currentPassword.isEmpty {
            hapticFeedback.error()
            self.controllerNode.animateError()
        } else {
            self.loginWithPassword?(self.controllerNode.currentPassword)
        }
    }
    
    func forgotPressed() {
        if self.suggestReset {
            self.present(standardTextAlertController(theme: AlertControllerTheme(presentationTheme: self.theme), title: nil, text: self.strings.TwoStepAuth_RecoveryFailed, actions: [TextAlertAction(type: .defaultAction, title: self.strings.Common_OK, action: {})]), in: .window(.root))
        } else if self.didForgotWithNoRecovery {
            self.present(standardTextAlertController(theme: AlertControllerTheme(presentationTheme: self.theme), title: nil, text: self.strings.TwoStepAuth_RecoveryUnavailable, actions: [TextAlertAction(type: .defaultAction, title: self.strings.Common_OK, action: {})]), in: .window(.root))
        } else {
            self.forgot?()
        }
    }
    
    func resetPressed() {
        self.reset?()
    }
}
