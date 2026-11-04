import Foundation
import UIKit
import Display
import MessageUI
import SwiftSignalKit
import TelegramCore
import AccountContext
import AlertUI
import PresentationDataUtils
import ComponentFlow
import AlertComponent
import AlertMultilineInputFieldComponent

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
    /// `chat`, when given, is the group the number was typed into the picker
    /// of: the code leads into it, and the server puts the person into the
    /// group when they sign up (#164).
    public static func invite(context: AccountContext, phone: String, chat: Int64? = nil, from controller: ViewController, onSent: @escaping () -> Void = {}) {
        let strings = context.sharedContext.currentPresentationData.with { $0 }.strings
        let one = InvitationComposer(onSent: onSent)
        open.append(one)
        one.disposable.set((context.engine.contacts.mintInvitation(phone: phone, chat: chat)
        |> deliverOnMainQueue).start(next: { [weak controller] code in
            guard let controller, let window = controller.view.window, MFMessageComposeViewController.canSendText() else {
                // Said, rather than nothing happening: a simulator has no SMS app.
                Logger.shared.log("Invite", "this device cannot send SMS, or the screen that asked is gone")
                one.done()
                return
            }
            let composer = MFMessageComposeViewController()
            composer.messageComposeDelegate = one
            composer.recipients = [phone]
            // A +7 number is usually on a Russian network that cannot reach
            // ice9.app (Cloudflare); ice9.ru is served from our own machine and
            // opens there (#178). Everyone else keeps the CDN-backed link.
            let russian = phone.replacingOccurrences(of: " ", with: "").hasPrefix("+7")
            let inviteURL = russian ? "https://ice9.ru" : strings.InviteText_URL
            var lines = [strings.InviteText_SingleContact(inviteURL).string]
            // From a server of one's own the app alone would land on ours: the
            // link fills this server in on the first screen (#245).
            let server = ServerAddressStore(rootPath: context.sharedContext.basePath).effective
            if !server.isOurs {
                let link = ServerLink.make(host: server.host, port: server.port, code: server.code ?? "", russian: russian)
                Logger.shared.log("Invite", "the SMS hands on the server as \(link)")
                lines.append(strings.Invite_ServerLine(link).string)
            }
            lines.append(strings.Invite_CodeLine(code).string)
            composer.body = lines.joined(separator: "\n")
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
                if chat == nil {
                    offerToWrite(context: context, phone: phone, from: controller)
                    return
                }
                text = strings.Invite_AlreadyHereAdd
            case .notInGroup:
                text = strings.Invite_NotInGroup
            case .generic:
                text = strings.Invite_NoCode
            }
            controller.present(textAlertController(context: context, title: nil, text: text, actions: [TextAlertAction(type: .defaultAction, title: strings.Common_OK, action: {})]), in: .window(.root))
        }))
    }

    /// The number already has an account: say so, and offer the chat instead
    /// of an OK that left nowhere to go (#296). The phone had sent that number
    /// to the server once, while nobody held it, so the person is not among
    /// the contacts; Write finds them by the number, makes them a contact and
    /// opens the chat.
    private static func offerToWrite(context: AccountContext, phone: String, from controller: ViewController) {
        let strings = context.sharedContext.currentPresentationData.with { $0 }.strings
        let write = TextAlertAction(type: .defaultAction, title: strings.Conversation_ContextMenuSendMessage, action: { [weak controller] in
            // Asked afresh: a number looked up before the person came in is
            // remembered as nobody's for two days.
            let _ = (context.engine.peers.resolvePeerByPhone(phone: phone, ageLimit: 0)
            |> deliverOnMainQueue).startStandalone(next: { peer in
                guard let peer, case let .user(user) = peer else {
                    Logger.shared.log("Invite", "already here, and the number finds nobody")
                    controller?.present(textAlertController(context: context, title: nil, text: strings.Invite_NoCode, actions: [TextAlertAction(type: .defaultAction, title: strings.Common_OK, action: {})]), in: .window(.root))
                    return
                }
                let _ = (context.engine.data.get(TelegramEngine.EngineData.Item.Peer.IsContact(id: peer.id))
                |> deliverOnMainQueue).startStandalone(next: { isContact in
                    if !isContact {
                        let _ = context.engine.contacts.addContactInteractively(peerId: peer.id, firstName: user.firstName ?? "", lastName: user.lastName ?? "", phoneNumber: user.phone ?? phone, noteText: "", noteEntities: [], addToPrivacyExceptions: false).startStandalone()
                    }
                    // The walks read this line: the alert led to this person's chat.
                    Logger.shared.log("Invite", "already here, opening the chat with \(peer.id.id._internalGetInt64Value())")
                    guard let navigationController = controller?.navigationController as? NavigationController ?? context.sharedContext.mainWindow?.viewController as? NavigationController else {
                        return
                    }
                    context.sharedContext.navigateToChatController(NavigateToChatControllerParams(navigationController: navigationController, context: context, chatLocation: .peer(peer)))
                })
            })
        })
        let cancel = TextAlertAction(type: .genericAction, title: strings.Common_Cancel, action: {})
        controller.present(textAlertController(context: context, title: nil, text: strings.Invite_AlreadyHere, actions: [cancel, write]), in: .window(.root))
    }

    /// Asks for the number to invite in a window with one field for it.
    ///
    /// "Invite by phone number" opened the contacts search before, with no
    /// hint and the letters keyboard, and a person was left to guess that a
    /// number goes there. What is typed is handed over as it is, the way the
    /// search handed over a typed number.
    public static func askForNumber(context: AccountContext, from controller: ViewController, then: @escaping (String) -> Void) {
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let strings = presentationData.strings
        let inputState = AlertMultilineInputFieldComponent.ExternalState()
        let content: [AnyComponentWithIdentity<AlertComponentEnvironment>] = [
            AnyComponentWithIdentity(id: "title", component: AnyComponent(
                AlertTitleComponent(title: strings.Invite_ByPhoneNumber)
            )),
            AnyComponentWithIdentity(id: "input", component: AnyComponent(
                AlertMultilineInputFieldComponent(
                    context: context,
                    placeholder: strings.Invite_ByPhoneHint,
                    characterLimit: 24,
                    keyboardType: .phonePad,
                    autocorrectionType: .no,
                    emptyLineHandling: .notAllowed,
                    isInitiallyFocused: true,
                    externalState: inputState
                )
            ))
        ]
        let alert = AlertScreen(
            configuration: AlertScreen.Configuration(allowInputInset: true),
            content: content,
            actions: [
                .init(title: strings.Common_Cancel, action: {}),
                .init(title: strings.Contacts_InviteToTelegram, type: .default, action: {
                    let typed = inputState.value.string.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !typed.isEmpty {
                        then(typed)
                    }
                })
            ],
            updatedPresentationData: (presentationData, context.sharedContext.presentationData)
        )
        controller.present(alert, in: .window(.root))
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
