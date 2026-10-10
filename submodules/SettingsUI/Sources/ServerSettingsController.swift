import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import ItemListUI
import PresentationDataUtils
import AccountContext
import AlertUI
import DebugSettingsUI

/// The wording for the server row and the screen behind it (ice9 #65).
///
/// Ours rather than upstream's, and written here rather than in the generated
/// string table for the reason the first-launch screen gives: adding a key
/// there means regenerating a table built from Telegram's own translations,
/// which is a poor trade for six sentences.
public func serverSettingsIsRussian(_ strings: PresentationStrings) -> Bool {
    return strings.baseLanguageCode.hasPrefix("ru")
}

public func serverSettingsTitle(_ strings: PresentationStrings) -> String {
    return serverSettingsIsRussian(strings) ? "Сервер" : "Server"
}

func serverSettingsChange(_ strings: PresentationStrings) -> String {
    return serverSettingsIsRussian(strings) ? "Сменить сервер" : "Change server"
}

/// The whole of the warning, and it has to be the whole of it: this is the one
/// screen in the app where a tap costs somebody their messages.
func serverSettingsChangeInfo(_ strings: PresentationStrings) -> String {
    return serverSettingsIsRussian(strings)
        ? "Смена сервера означает выход из аккаунта: всё на этом телефоне будет стёрто — сообщения, чаты и ключи. Они принадлежат тому серверу, который их выдал, и на другом ничего не значат. Ваш аккаунт на прежнем сервере останется там же, и туда можно вернуться."
        : "Changing the server signs you out and erases everything on this phone: messages, chats and keys. They belong to the server that issued them and mean nothing on another one. Your account on the old server stays where it is, and you can come back to it."
}

func serverSettingsConfirmTitle(_ strings: PresentationStrings) -> String {
    return serverSettingsIsRussian(strings) ? "Сменить сервер?" : "Change server?"
}

func serverSettingsConfirmText(_ strings: PresentationStrings) -> String {
    return serverSettingsIsRussian(strings)
        ? "Вы выйдете из аккаунта, и всё на этом телефоне будет стёрто. Адрес нового сервера спросят сразу после выхода, и пока вы его не назовёте, приложение будет обращаться к прежнему."
        : "You will be signed out and everything on this phone will be erased. The new address is asked for straight afterwards, and until you name one the app goes on reaching the server it reaches now."
}

func serverSettingsConfirmAction(_ strings: PresentationStrings) -> String {
    return serverSettingsIsRussian(strings) ? "Сменить и выйти" : "Change and sign out"
}

func serverSettingsSendLogs(_ strings: PresentationStrings) -> String {
    return serverSettingsIsRussian(strings) ? "Отправить журнал приложения" : "Send app logs"
}

/// What the share extension says when it sent nothing (#230). Kept here, with
/// the other texts ice9 writes in both languages.
public func shareNotEncryptedText(_ strings: PresentationStrings) -> String {
    return serverSettingsIsRussian(strings)
        ? "В этом чате ещё нет шифрования. Откройте ice9 и напишите в него оттуда - из других приложений ice9 отправляет только зашифрованным и сюда ничего не отправил."
        : "This chat is not encrypted yet. Open ice9 and write in it from there - from other apps ice9 sends only encrypted, and has sent nothing here."
}

public func shareNotSentText(_ strings: PresentationStrings) -> String {
    return serverSettingsIsRussian(strings)
        ? "Не отправлено. Ничего не ушло открытым текстом - попробуйте ещё раз из ice9."
        : "Not sent. Nothing went unencrypted - try again from ice9."
}

/// The one way to the app's own log, said where it is: App Review rejected
/// 12.9.2 under 2.3.1(a) for hidden features (#181), and the debug menu that
/// used to send it was reached by ten taps on a tab.
func serverSettingsSendLogsInfo(_ strings: PresentationStrings) -> String {
    return serverSettingsIsRussian(strings)
        ? "Журнал работы приложения на этом телефоне — для того, кто помогает разобраться с проблемой. Он уходит файлом в чат, который вы выберете, и никуда больше. Если журнал не вёлся, он включится с этого нажатия."
        : "The app's own record of its work on this phone, for whoever is helping you with a problem. It goes as a file to the chat you pick, and nowhere else. If the app was not keeping one, it starts with this tap."
}

/// Where ice9 comes from, said in the app (#181): App Review refused 12.9.2 as
/// Telegram's code "presented as an original product". It is built on
/// Telegram's open-source apps, and its own code is public; this says both.
public let serverSettingsSourceCodeUrl = "https://github.com/dsfox/teamgram-ios"

func serverSettingsSourceCode(_ strings: PresentationStrings) -> String {
    return serverSettingsIsRussian(strings) ? "Исходный код" : "Source code"
}

func serverSettingsSourceCodeInfo(_ strings: PresentationStrings) -> String {
    return serverSettingsIsRussian(strings)
        ? "ice9 построен на открытых приложениях Telegram для iOS и Android. Код этого приложения, сервера и шифрования открыт на github.com/dsfox."
        : "ice9 is built on Telegram's open-source apps for iOS and Android. The code of this app, of the server and of the encryption is public at github.com/dsfox."
}

/// What a pinned key means, said under the address (#244).
func serverSettingsCodeInfo(_ strings: PresentationStrings, code: String) -> String {
    return serverSettingsIsRussian(strings)
        ? "Телефон доверяет только ключу с кодом \(code)."
        : "This phone trusts only the key with the code \(code)."
}

func serverSettingsLinkMalformed(_ strings: PresentationStrings) -> String {
    return serverSettingsIsRussian(strings)
        ? "Ссылка на сервер повреждена. Попросите её ещё раз."
        : "This server link is damaged. Ask for it again."
}

func serverSettingsSameServer(_ strings: PresentationStrings) -> String {
    return serverSettingsIsRussian(strings)
        ? "Этот телефон уже говорит с этим сервером."
        : "This phone already talks to this server."
}

/// A server link opened while signed in (#244): the same question Settings >
/// Server asks, because changing servers is a sign-out here too. Confirmed, the
/// question comes back after the sign-out with the link's server filled in.
public func serverLinkWhileSignedInController(context: AccountContext, link: ServerLink) -> ViewController {
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    let store = ServerAddressStore(rootPath: context.sharedContext.basePath)
    if case .malformed = link {
        // Nothing to change to, so no reason to sign out.
        return textAlertController(context: context, title: nil, text: serverSettingsLinkMalformed(presentationData.strings), actions: [
            TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_OK, action: {})
        ])
    }
    if case let .link(host, port, code) = link, store.effective.host == host, store.effective.port == port, (store.effective.code ?? "") == code {
        return textAlertController(context: context, title: nil, text: serverSettingsSameServer(presentationData.strings), actions: [
            TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_OK, action: {})
        ])
    }
    return textAlertController(context: context, title: serverSettingsConfirmTitle(presentationData.strings), text: serverSettingsConfirmText(presentationData.strings), actions: [
        TextAlertAction(type: .genericAction, title: presentationData.strings.Common_Cancel, action: {}),
        TextAlertAction(type: .destructiveAction, title: serverSettingsConfirmAction(presentationData.strings), action: {
            store.askAgain()
            ServerLinkInbox.shared.put(link)
            let _ = logoutFromAccount(id: context.account.id, accountManager: context.sharedContext.accountManager, alreadyLoggedOutRemotely: false).startStandalone()
        })
    ])
}

private struct ServerSettingsArguments {
    let change: () -> Void
    let sendLogs: () -> Void
    let openSourceCode: () -> Void
}

private enum ServerSettingsSection: Int32 {
    case current
    case change
    case logs
    case source
}

private enum ServerSettingsEntry: ItemListNodeEntry, Equatable {
    case current(PresentationTheme, String)
    case codeInfo(PresentationTheme, String)
    case change(PresentationTheme, String)
    case changeInfo(PresentationTheme, String)
    case sendLogs(PresentationTheme, String)
    case sendLogsInfo(PresentationTheme, String)
    case sourceCode(PresentationTheme, String)
    case sourceCodeInfo(PresentationTheme, String)

    var section: ItemListSectionId {
        switch self {
        case .current, .codeInfo:
            return ServerSettingsSection.current.rawValue
        case .change, .changeInfo:
            return ServerSettingsSection.change.rawValue
        case .sendLogs, .sendLogsInfo:
            return ServerSettingsSection.logs.rawValue
        case .sourceCode, .sourceCodeInfo:
            return ServerSettingsSection.source.rawValue
        }
    }

    var stableId: Int32 {
        switch self {
        case .current:
            return 1
        case .codeInfo:
            return 8
        case .change:
            return 2
        case .changeInfo:
            return 3
        case .sendLogs:
            return 4
        case .sendLogsInfo:
            return 5
        case .sourceCode:
            return 6
        case .sourceCodeInfo:
            return 7
        }
    }

    static func <(lhs: ServerSettingsEntry, rhs: ServerSettingsEntry) -> Bool {
        return lhs.order < rhs.order
    }

    /// The code line sits under the address, whatever its id.
    private var order: Int32 {
        if case .codeInfo = self {
            return 3
        }
        return self.stableId * 2
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! ServerSettingsArguments
        switch self {
        case let .current(_, address):
            // A row rather than a footnote. The address is the one thing on this
            // screen somebody came to read, and as free text under a heading it
            // was the smallest and greyest thing on it. No arrow and no action:
            // it is a value, and what changes it is below.
            return ItemListDisclosureItem(presentationData: presentationData, title: address, label: "", sectionId: self.section, style: .blocks, disclosureStyle: .none, action: nil)
        case let .change(_, title):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: title, kind: .destructive, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                arguments.change()
            })
        case let .changeInfo(_, text), let .codeInfo(_, text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .sendLogs(_, title):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: title, kind: .generic, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                arguments.sendLogs()
            })
        case let .sendLogsInfo(_, text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .sourceCode(_, title):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: title, kind: .generic, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                arguments.openSourceCode()
            })
        case let .sourceCodeInfo(_, text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        }
    }
}

private func serverSettingsEntries(presentationData: PresentationData, address: ServerAddress) -> [ServerSettingsEntry] {
    var entries: [ServerSettingsEntry] = [
        .current(presentationData.theme, address.described),
    ]
    if let code = address.code {
        entries.append(.codeInfo(presentationData.theme, serverSettingsCodeInfo(presentationData.strings, code: ServerCode.grouped(code))))
    }
    return entries + [
        .change(presentationData.theme, serverSettingsChange(presentationData.strings)),
        .changeInfo(presentationData.theme, serverSettingsChangeInfo(presentationData.strings)),
        .sendLogs(presentationData.theme, serverSettingsSendLogs(presentationData.strings)),
        .sendLogsInfo(presentationData.theme, serverSettingsSendLogsInfo(presentationData.strings)),
        .sourceCode(presentationData.theme, serverSettingsSourceCode(presentationData.strings)),
        .sourceCodeInfo(presentationData.theme, serverSettingsSourceCodeInfo(presentationData.strings)),
    ]
}

/// Which server this phone talks to, after the first launch has answered it.
///
/// Changing it is a sign-out and a wipe, so it does not happen here: this screen
/// puts the question back and signs out, and the address is typed on the screen
/// that already knows how to check one before keeping it. Doing the checking
/// here would mean building a second connection beside the account's own, and
/// keeping an address that has not answered is the one outcome this whole
/// feature exists to prevent.
public func serverSettingsController(context: AccountContext) -> ViewController {
    var presentControllerImpl: ((ViewController, Any?) -> Void)?
    var pushControllerImpl: ((ViewController) -> Void)?
    var dismissImpl: (() -> Void)?

    let store = ServerAddressStore(rootPath: context.sharedContext.basePath)

    let arguments = ServerSettingsArguments(change: {
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        presentControllerImpl?(textAlertController(context: context, title: serverSettingsConfirmTitle(presentationData.strings), text: serverSettingsConfirmText(presentationData.strings), actions: [
            TextAlertAction(type: .genericAction, title: presentationData.strings.Common_Cancel, action: {
            }),
            TextAlertAction(type: .destructiveAction, title: serverSettingsConfirmAction(presentationData.strings), action: {
                // The order matters and only one way round is safe. The question
                // goes back first, so that whatever happens to the sign-out the
                // next launch asks it; the address itself is left alone, so a
                // phone that gets no further goes on reaching the server it
                // always did rather than silently landing on ours.
                store.askAgain()
                let _ = logoutFromAccount(id: context.account.id, accountManager: context.sharedContext.accountManager, alreadyLoggedOutRemotely: false).startStandalone()
                dismissImpl?()
            })
        ]), nil)
    }, sendLogs: {
        let _ = updateLoggingSettings(accountManager: context.sharedContext.accountManager, {
            $0.withUpdatedLogToFile(true)
        }).startStandalone()
        triggerDebugSendLogsUI(context: context, pushController: { controller in
            pushControllerImpl?(controller)
        })
    }, openSourceCode: {
        context.sharedContext.openExternalUrl(context: context, urlContext: .generic, url: serverSettingsSourceCodeUrl, forceExternal: true, presentationData: context.sharedContext.currentPresentationData.with { $0 }, navigationController: nil, dismissInput: {})
    })

    let signal = context.sharedContext.presentationData
    |> map { presentationData -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(serverSettingsTitle(presentationData.strings)), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: serverSettingsEntries(presentationData: presentationData, address: store.effective), style: .blocks)
        return (controllerState, (listState, arguments))
    }

    let controller = ItemListController(context: context, state: signal)
    presentControllerImpl = { [weak controller] c, a in
        controller?.present(c, in: .window(.root), with: a)
    }
    pushControllerImpl = { [weak controller] c in
        controller?.push(c)
    }
    dismissImpl = { [weak controller] in
        controller?.dismiss()
    }
    return controller
}
