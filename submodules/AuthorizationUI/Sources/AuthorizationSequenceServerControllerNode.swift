import Foundation
import UIKit
import AsyncDisplayKit
import Display
import TelegramCore
import TelegramPresentationData
import AuthorizationUtils

/// The screen that asks which server this phone talks to.
///
/// A field with one line in it, because that is the whole question. Ours is
/// filled in, so the common case is one tap on Next; anything else is typed
/// over it, and a way back to ours sits underneath for whoever changes their
/// mind.
final class AuthorizationSequenceServerControllerNode: ASDisplayNode, UITextFieldDelegate {
    private let strings: PresentationStrings
    private let theme: PresentationTheme

    private let titleNode: ASTextNode
    private let noticeNode: ASTextNode

    private let addressField: TextFieldNode
    private let addressSeparatorNode: ASDisplayNode

    private let errorNode: ASTextNode
    private let ownServerNode: HighlightableButtonNode
    private let defaultNode: HighlightableButtonNode

    private var layoutArguments: (ContainerViewLayout, CGFloat)?

    var currentAddress: String {
        return self.addressField.textField.text ?? ""
    }

    var enterAddress: ((String) -> Void)?
    var openInstructions: (() -> Void)?

    var inProgress: Bool = false {
        didSet {
            self.addressField.alpha = self.inProgress ? 0.6 : 1.0
            self.addressField.textField.isEnabled = !self.inProgress
        }
    }

    init(strings: PresentationStrings, theme: PresentationTheme, address: ServerAddress) {
        self.strings = strings
        self.theme = theme

        self.titleNode = ASTextNode()
        self.titleNode.isUserInteractionEnabled = false
        self.titleNode.displaysAsynchronously = false
        self.titleNode.attributedText = NSAttributedString(string: serverChoiceTitle(strings), font: Font.light(30.0), textColor: theme.list.itemPrimaryTextColor)

        self.noticeNode = ASTextNode()
        self.noticeNode.isUserInteractionEnabled = false
        self.noticeNode.displaysAsynchronously = false
        self.noticeNode.attributedText = NSAttributedString(string: serverChoiceNotice(strings), font: Font.regular(17.0), textColor: theme.list.itemPrimaryTextColor, paragraphAlignment: .center)
        self.noticeNode.lineSpacing = 0.1

        self.addressSeparatorNode = ASDisplayNode()
        self.addressSeparatorNode.isLayerBacked = true
        self.addressSeparatorNode.backgroundColor = theme.list.itemPlainSeparatorColor

        self.addressField = TextFieldNode()
        // Named, because this is the only thing on the screen a run can take
        // hold of. The "Next" button lives in a navigation bar built out of
        // nodes, and none of it reaches the accessibility tree - a fresh
        // install left the sign-in tool looking at a screen with two unnamed
        // elements on it. Pressing return in this field is what the delegate
        // below reads as Next, so naming the field is enough to walk past.
        self.addressField.textField.accessibilityIdentifier = "Auth.Server.AddressField"
        self.addressField.textField.font = Font.regular(20.0)
        self.addressField.textField.textColor = theme.list.itemPrimaryTextColor
        self.addressField.textField.textAlignment = .center
        self.addressField.textField.attributedPlaceholder = NSAttributedString(string: serverChoicePlaceholder(strings), font: Font.regular(20.0), textColor: theme.list.itemPlaceholderTextColor)
        self.addressField.textField.returnKeyType = .done
        self.addressField.textField.keyboardAppearance = theme.rootController.keyboardColor.keyboardAppearance
        self.addressField.textField.disableAutomaticKeyboardHandling = [.forward, .backward]
        self.addressField.textField.tintColor = theme.list.itemAccentColor
        // An address is not prose. A capital letter at the front of a hostname
        // and a helpful rewrite of the middle of one are both ways to be told
        // that nothing answered.
        self.addressField.textField.autocapitalizationType = .none
        self.addressField.textField.autocorrectionType = .no
        self.addressField.textField.spellCheckingType = .no
        self.addressField.textField.keyboardType = .URL
        self.addressField.textField.text = address.described

        self.errorNode = ASTextNode()
        self.errorNode.isUserInteractionEnabled = false
        self.errorNode.displaysAsynchronously = false

        // Said on the screen where it can be acted on rather than on a page
        // somebody would have to go looking for. Most people will keep ours and
        // should - but a messenger that offers a server of your own and never
        // mentions how is offering it the way a form offers a tick box.
        self.ownServerNode = HighlightableButtonNode()
        self.ownServerNode.displaysAsynchronously = false
        self.ownServerNode.titleNode.maximumNumberOfLines = 0
        self.ownServerNode.setAttributedTitle(NSAttributedString(string: serverChoiceOwnServer(strings), font: Font.regular(15.0), textColor: theme.list.itemAccentColor, paragraphAlignment: .center), for: [])

        self.defaultNode = HighlightableButtonNode()
        self.defaultNode.displaysAsynchronously = false
        self.defaultNode.setAttributedTitle(NSAttributedString(string: serverChoiceUseDefault(strings), font: Font.regular(16.0), textColor: theme.list.itemAccentColor, paragraphAlignment: .center), for: [])

        super.init()

        self.setViewBlock({
            return UITracingLayerView()
        })

        self.backgroundColor = theme.list.plainBackgroundColor

        self.addressField.textField.delegate = self
        self.addressField.textField.addTarget(self, action: #selector(self.addressChanged), for: .editingChanged)

        self.addSubnode(self.addressSeparatorNode)
        self.addSubnode(self.addressField)
        self.addSubnode(self.titleNode)
        self.addSubnode(self.noticeNode)
        self.addSubnode(self.errorNode)
        self.addSubnode(self.ownServerNode)
        self.addSubnode(self.defaultNode)

        self.ownServerNode.addTarget(self, action: #selector(self.ownServerPressed), forControlEvents: .touchUpInside)
        self.defaultNode.addTarget(self, action: #selector(self.defaultPressed), forControlEvents: .touchUpInside)

        self.updateDefaultButton()
    }

    /// Says what went wrong, or takes the complaint away. The old complaint is
    /// about the old address, and leaving it up makes a corrected one look
    /// refused too.
    func showError(_ text: String?) {
        if let text = text, !text.isEmpty {
            self.errorNode.attributedText = NSAttributedString(string: text, font: Font.regular(15.0), textColor: self.theme.list.itemDestructiveColor, paragraphAlignment: .center)
        } else {
            self.errorNode.attributedText = nil
        }
        if let (layout, navigationBarHeight) = self.layoutArguments {
            self.containerLayoutUpdated(layout, navigationBarHeight: navigationBarHeight, transition: .immediate)
        }
    }

    /// Nothing to put back when what is typed is already the default.
    private func updateDefaultButton() {
        let typed = ServerAddress.parse(self.currentAddress)
        self.defaultNode.isHidden = typed?.isOurs ?? false
    }

    @objc private func addressChanged() {
        self.showError(nil)
        self.updateDefaultButton()
    }

    @objc private func defaultPressed() {
        self.addressField.textField.text = ServerAddress.default.described
        self.showError(nil)
        self.updateDefaultButton()
    }

    @objc private func ownServerPressed() {
        self.openInstructions?()
    }

    func containerLayoutUpdated(_ layout: ContainerViewLayout, navigationBarHeight: CGFloat, transition: ContainedViewLayoutTransition) {
        self.layoutArguments = (layout, navigationBarHeight)

        var insets = layout.insets(options: [.input])
        insets.top = navigationBarHeight

        if max(layout.size.width, layout.size.height) > 1023.0 {
            self.titleNode.attributedText = NSAttributedString(string: serverChoiceTitle(self.strings), font: Font.light(40.0), textColor: self.theme.list.itemPrimaryTextColor)
        } else {
            self.titleNode.attributedText = NSAttributedString(string: serverChoiceTitle(self.strings), font: Font.light(30.0), textColor: self.theme.list.itemPrimaryTextColor)
        }

        let titleSize = self.titleNode.measure(CGSize(width: layout.size.width, height: CGFloat.greatestFiniteMagnitude))
        let noticeSize = self.noticeNode.measure(CGSize(width: layout.size.width - 28.0, height: CGFloat.greatestFiniteMagnitude))
        let errorSize = self.errorNode.measure(CGSize(width: layout.size.width - 28.0, height: CGFloat.greatestFiniteMagnitude))
        let ownServerSize = self.ownServerNode.measure(CGSize(width: layout.size.width - 44.0, height: CGFloat.greatestFiniteMagnitude))
        let defaultSize = self.defaultNode.measure(CGSize(width: layout.size.width, height: CGFloat.greatestFiniteMagnitude))

        var items: [AuthorizationLayoutItem] = []
        items.append(AuthorizationLayoutItem(node: self.titleNode, size: titleSize, spacingBefore: AuthorizationLayoutItemSpacing(weight: 0.0, maxValue: 0.0), spacingAfter: AuthorizationLayoutItemSpacing(weight: 0.0, maxValue: 0.0)))
        items.append(AuthorizationLayoutItem(node: self.noticeNode, size: noticeSize, spacingBefore: AuthorizationLayoutItemSpacing(weight: 10.0, maxValue: 10.0), spacingAfter: AuthorizationLayoutItemSpacing(weight: 0.0, maxValue: 0.0)))
        items.append(AuthorizationLayoutItem(node: self.addressField, size: CGSize(width: layout.size.width - 88.0, height: 44.0), spacingBefore: AuthorizationLayoutItemSpacing(weight: 32.0, maxValue: 100.0), spacingAfter: AuthorizationLayoutItemSpacing(weight: 0.0, maxValue: 0.0)))
        items.append(AuthorizationLayoutItem(node: self.addressSeparatorNode, size: CGSize(width: layout.size.width - 88.0, height: UIScreenPixel), spacingBefore: AuthorizationLayoutItemSpacing(weight: 0.0, maxValue: 0.0), spacingAfter: AuthorizationLayoutItemSpacing(weight: 0.0, maxValue: 0.0)))
        items.append(AuthorizationLayoutItem(node: self.errorNode, size: errorSize, spacingBefore: AuthorizationLayoutItemSpacing(weight: 16.0, maxValue: 16.0), spacingAfter: AuthorizationLayoutItemSpacing(weight: 0.0, maxValue: 0.0)))
        items.append(AuthorizationLayoutItem(node: self.defaultNode, size: defaultSize, spacingBefore: AuthorizationLayoutItemSpacing(weight: 32.0, maxValue: 60.0), spacingAfter: AuthorizationLayoutItemSpacing(weight: 0.0, maxValue: 0.0)))
        items.append(AuthorizationLayoutItem(node: self.ownServerNode, size: ownServerSize, spacingBefore: AuthorizationLayoutItemSpacing(weight: 40.0, maxValue: 80.0), spacingAfter: AuthorizationLayoutItemSpacing(weight: 0.0, maxValue: 0.0)))

        let _ = layoutAuthorizationItems(bounds: CGRect(origin: CGPoint(x: 0.0, y: insets.top), size: CGSize(width: layout.size.width, height: layout.size.height - insets.top - insets.bottom - 20.0)), items: items, transition: transition, failIfDoesNotFit: false)
    }

    func activateInput() {
        self.addressField.textField.becomeFirstResponder()
    }

    func animateError() {
        self.addressField.layer.addShakeAnimation()
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        self.enterAddress?(self.currentAddress)
        return false
    }
}
