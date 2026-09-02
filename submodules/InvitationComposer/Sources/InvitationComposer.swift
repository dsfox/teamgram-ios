import Foundation
import UIKit
import Display
import MessageUI
import SwiftSignalKit
import TelegramCore
import AccountContext
import AlertUI
import PresentationDataUtils

/// The one place an invitation SMS is composed from (#47).
///
/// Four screens can invite a number - Invite Contacts, a contact's own page,
/// the new-contact screen, and a number tapped in a message - and an SMS
/// without a code is useless, because the code is what lets that number in.
/// So every one of them comes here: a code bound to the number is minted
/// first, and the phone's own SMS app then carries it over the inviter's
/// carrier, which is what makes "I vouch for this person" true. A refusal is
/// said in words rather than swallowed, and the composer never opens without
/// a code.
public final class InvitationComposer: NSObject, MFMessageComposeViewControllerDelegate {
    /// Alive while a composer is up. The composer holds its delegate weakly,
    /// and the screen that asked may be gone by the time the SMS is sent.
    private static var open: [InvitationComposer] = []

    private let disposable = MetaDisposable()
    private let onSent: () -> Void
    private var composer: MFMessageComposeViewController?

    private init(onSent: @escaping () -> Void) {
        self.onSent = onSent
        super.init()
    }

    deinit {
        self.disposable.dispose()
    }

    /// Mints a code for the number and opens the SMS app to it, on the window
    /// of the screen that asked. A refusal is shown on that screen; onSent
    /// runs once the SMS has actually gone.
    public static func invite(context: AccountContext, phone: String, from controller: ViewController, onSent: @escaping () -> Void = {}) {
        let strings = context.sharedContext.currentPresentationData.with { $0 }.strings
        let one = InvitationComposer(onSent: onSent)
        open.append(one)
        one.disposable.set((context.engine.contacts.mintInvitation(phone: phone)
        |> deliverOnMainQueue).start(next: { [weak controller] code in
            guard let controller, let window = controller.view.window, MFMessageComposeViewController.canSendText() else {
                one.done()
                return
            }
            let composer = MFMessageComposeViewController()
            composer.messageComposeDelegate = one
            composer.recipients = [phone]
            composer.body = strings.InviteText_SingleContact(strings.InviteText_URL).string + "\n" + strings.Invite_CodeLine(code).string
            one.composer = composer
            window.rootViewController?.present(composer, animated: true)
        }, error: { [weak controller] error in
            one.done()
            guard let controller else {
                return
            }
            let text: String
            switch error {
            case .alreadyHere:
                text = strings.Invite_AlreadyHere
            case .generic:
                text = strings.Invite_NoCode
            }
            controller.present(textAlertController(context: context, title: nil, text: text, actions: [TextAlertAction(type: .defaultAction, title: strings.Common_OK, action: {})]), in: .window(.root))
        }))
    }

    private func done() {
        self.composer = nil
        InvitationComposer.open.removeAll { $0 === self }
    }

    public func messageComposeViewController(_ controller: MFMessageComposeViewController, didFinishWith result: MessageComposeResult) {
        controller.dismiss(animated: true, completion: nil)
        if case .sent = result {
            self.onSent()
        }
        self.done()
    }
}
