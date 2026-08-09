import Foundation
import UIKit
import AsyncDisplayKit
import Display
import TelegramPresentationData
import AuthorizationUtils

/// The screen where somebody whose phone is gone types the six words they were
/// given when they signed up.
///
/// It is a plain text field rather than the boxes on the code screen, because
/// those hold one digit each and a phrase is words. What is typed goes into the
/// same place the code would: phone_code has always been a string, so nothing
/// about the protocol changes.
final class AuthorizationSequenceRecoveryPhraseControllerNode: ASDisplayNode, UITextFieldDelegate {
    private let strings: PresentationStrings
    private let theme: PresentationTheme

    private let titleNode: ASTextNode
    private let noticeNode: ASTextNode

    private let phraseField: TextFieldNode
    private let phraseSeparatorNode: ASDisplayNode

    private var layoutArguments: (ContainerViewLayout, CGFloat)?

    var currentPhrase: String {
        return self.phraseField.textField.text ?? ""
    }

    var enterPhrase: ((String) -> Void)?

    var inProgress: Bool = false {
        didSet {
            self.phraseField.alpha = self.inProgress ? 0.6 : 1.0
        }
    }

    init(strings: PresentationStrings, theme: PresentationTheme) {
        self.strings = strings
        self.theme = theme

        self.titleNode = ASTextNode()
        self.titleNode.isUserInteractionEnabled = false
        self.titleNode.displaysAsynchronously = false
        self.titleNode.attributedText = NSAttributedString(string: recoveryPhraseTitle(strings), font: Font.light(30.0), textColor: self.theme.list.itemPrimaryTextColor)

        self.noticeNode = ASTextNode()
        self.noticeNode.isUserInteractionEnabled = false
        self.noticeNode.displaysAsynchronously = false
        self.noticeNode.attributedText = NSAttributedString(string: recoveryPhraseNotice(strings), font: Font.regular(17.0), textColor: self.theme.list.itemPrimaryTextColor, paragraphAlignment: .center)
        self.noticeNode.lineSpacing = 0.1

        self.phraseSeparatorNode = ASDisplayNode()
        self.phraseSeparatorNode.isLayerBacked = true
        self.phraseSeparatorNode.backgroundColor = self.theme.list.itemPlainSeparatorColor

        self.phraseField = TextFieldNode()
        self.phraseField.textField.font = Font.regular(20.0)
        self.phraseField.textField.textColor = self.theme.list.itemPrimaryTextColor
        self.phraseField.textField.textAlignment = .center
        self.phraseField.textField.attributedPlaceholder = NSAttributedString(string: recoveryPhrasePlaceholder(strings), font: Font.regular(20.0), textColor: self.theme.list.itemPlaceholderTextColor)
        self.phraseField.textField.returnKeyType = .done
        self.phraseField.textField.keyboardAppearance = self.theme.rootController.keyboardColor.keyboardAppearance
        self.phraseField.textField.disableAutomaticKeyboardHandling = [.forward, .backward]
        self.phraseField.textField.tintColor = self.theme.list.itemAccentColor
        // The keyboard must not help. Autocorrection rewrites ordinary words
        // into other ordinary words, and a capital at the front of a phrase
        // that is compared in lower case is a silent way to be wrong.
        self.phraseField.textField.autocapitalizationType = .none
        self.phraseField.textField.autocorrectionType = .no
        self.phraseField.textField.spellCheckingType = .no
        self.phraseField.textField.keyboardType = .asciiCapable

        super.init()

        self.setViewBlock({
            return UITracingLayerView()
        })

        self.backgroundColor = self.theme.list.plainBackgroundColor

        self.phraseField.textField.delegate = self

        self.addSubnode(self.phraseSeparatorNode)
        self.addSubnode(self.phraseField)
        self.addSubnode(self.titleNode)
        self.addSubnode(self.noticeNode)
    }

    func containerLayoutUpdated(_ layout: ContainerViewLayout, navigationBarHeight: CGFloat, transition: ContainedViewLayoutTransition) {
        self.layoutArguments = (layout, navigationBarHeight)

        var insets = layout.insets(options: [.input])
        insets.top = navigationBarHeight

        if max(layout.size.width, layout.size.height) > 1023.0 {
            self.titleNode.attributedText = NSAttributedString(string: recoveryPhraseTitle(self.strings), font: Font.light(40.0), textColor: self.theme.list.itemPrimaryTextColor)
        } else {
            self.titleNode.attributedText = NSAttributedString(string: recoveryPhraseTitle(self.strings), font: Font.light(30.0), textColor: self.theme.list.itemPrimaryTextColor)
        }

        let titleSize = self.titleNode.measure(CGSize(width: layout.size.width, height: CGFloat.greatestFiniteMagnitude))
        let noticeSize = self.noticeNode.measure(CGSize(width: layout.size.width - 28.0, height: CGFloat.greatestFiniteMagnitude))

        var items: [AuthorizationLayoutItem] = []
        items.append(AuthorizationLayoutItem(node: self.titleNode, size: titleSize, spacingBefore: AuthorizationLayoutItemSpacing(weight: 0.0, maxValue: 0.0), spacingAfter: AuthorizationLayoutItemSpacing(weight: 0.0, maxValue: 0.0)))
        items.append(AuthorizationLayoutItem(node: self.noticeNode, size: noticeSize, spacingBefore: AuthorizationLayoutItemSpacing(weight: 10.0, maxValue: 10.0), spacingAfter: AuthorizationLayoutItemSpacing(weight: 0.0, maxValue: 0.0)))
        items.append(AuthorizationLayoutItem(node: self.phraseField, size: CGSize(width: layout.size.width - 88.0, height: 44.0), spacingBefore: AuthorizationLayoutItemSpacing(weight: 32.0, maxValue: 100.0), spacingAfter: AuthorizationLayoutItemSpacing(weight: 0.0, maxValue: 0.0)))
        items.append(AuthorizationLayoutItem(node: self.phraseSeparatorNode, size: CGSize(width: layout.size.width - 88.0, height: UIScreenPixel), spacingBefore: AuthorizationLayoutItemSpacing(weight: 0.0, maxValue: 0.0), spacingAfter: AuthorizationLayoutItemSpacing(weight: 48.0, maxValue: 100.0)))

        let _ = layoutAuthorizationItems(bounds: CGRect(origin: CGPoint(x: 0.0, y: insets.top), size: CGSize(width: layout.size.width, height: layout.size.height - insets.top - insets.bottom - 20.0)), items: items, transition: transition, failIfDoesNotFit: false)
    }

    func activateInput() {
        self.phraseField.textField.becomeFirstResponder()
    }

    func animateError() {
        self.phraseField.layer.addShakeAnimation()
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        self.enterPhrase?(self.currentPhrase)
        return false
    }
}
