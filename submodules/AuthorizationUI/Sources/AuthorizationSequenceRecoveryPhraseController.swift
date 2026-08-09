import Foundation
import UIKit
import Display
import AsyncDisplayKit
import TelegramPresentationData
import ProgressNavigationButtonNode

/// The wording for the recovery phrase screen.
///
/// These strings are ours rather than upstream's, and the app ships two
/// languages, so they are written here instead of going through the generated
/// string table - adding a key there means regenerating a table built from
/// Telegram's own translations, which is a poor trade for four sentences.
func recoveryPhraseIsRussian(_ strings: PresentationStrings) -> Bool {
    return strings.baseLanguageCode.hasPrefix("ru")
}

func recoveryPhraseTitle(_ strings: PresentationStrings) -> String {
    return recoveryPhraseIsRussian(strings) ? "Фраза восстановления" : "Recovery phrase"
}

func recoveryPhraseNotice(_ strings: PresentationStrings) -> String {
    return recoveryPhraseIsRussian(strings)
        ? "Введите шесть слов, которые мы выдали при регистрации. Они работают один раз — после входа придут новые."
        : "Enter the six words you were given when you signed up. They work once - a new phrase arrives after you are back in."
}

func recoveryPhrasePlaceholder(_ strings: PresentationStrings) -> String {
    return recoveryPhraseIsRussian(strings) ? "шесть слов через пробел" : "six words, spaces between"
}

func recoveryPhraseEntryPoint(_ strings: PresentationStrings) -> String {
    return recoveryPhraseIsRussian(strings) ? "Потерял телефон?" : "Lost your phone?"
}

/// Signing in with the recovery phrase: the only way back that needs nobody
/// else awake. There is no SMS here, and the login code goes to a session the
/// person no longer has, so without this screen a lost phone means writing to
/// us and waiting.
final class AuthorizationSequenceRecoveryPhraseController: ViewController {
    private var controllerNode: AuthorizationSequenceRecoveryPhraseControllerNode {
        return self.displayNode as! AuthorizationSequenceRecoveryPhraseControllerNode
    }

    private let strings: PresentationStrings
    private let theme: PresentationTheme

    var enterPhrase: ((String) -> Void)?

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

        self.statusBar.statusBarStyle = theme.intro.statusBarStyle.style

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

    override func loadDisplayNode() {
        self.displayNode = AuthorizationSequenceRecoveryPhraseControllerNode(strings: self.strings, theme: self.theme)
        self.displayNodeDidLoad()

        self.controllerNode.enterPhrase = { [weak self] phrase in
            self?.submit(phrase)
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        self.controllerNode.activateInput()
    }

    override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)

        self.controllerNode.containerLayoutUpdated(layout, navigationBarHeight: self.navigationBar?.frame.maxY ?? 0.0, transition: transition)
    }

    func animateError() {
        self.hapticFeedback.error()
        self.controllerNode.animateError()
    }

    @objc func nextPressed() {
        self.submit(self.controllerNode.currentPhrase)
    }

    /// An empty field is not an attempt: sending it spends one of the tries the
    /// server allows this number, and the person has typed nothing.
    private func submit(_ phrase: String) {
        if phrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self.hapticFeedback.error()
            self.controllerNode.animateError()
            return
        }
        self.enterPhrase?(phrase)
    }
}
