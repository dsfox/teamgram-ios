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

private struct ServerSettingsArguments {
    let change: () -> Void
}

private enum ServerSettingsSection: Int32 {
    case current
    case change
}

private enum ServerSettingsEntry: ItemListNodeEntry, Equatable {
    case current(PresentationTheme, String)
    case change(PresentationTheme, String)
    case changeInfo(PresentationTheme, String)

    var section: ItemListSectionId {
        switch self {
        case .current:
            return ServerSettingsSection.current.rawValue
        case .change, .changeInfo:
            return ServerSettingsSection.change.rawValue
        }
    }

    var stableId: Int32 {
        switch self {
        case .current:
            return 1
        case .change:
            return 2
        case .changeInfo:
            return 3
        }
    }

    static func <(lhs: ServerSettingsEntry, rhs: ServerSettingsEntry) -> Bool {
        return lhs.stableId < rhs.stableId
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
        case let .changeInfo(_, text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        }
    }
}

private func serverSettingsEntries(presentationData: PresentationData, address: ServerAddress) -> [ServerSettingsEntry] {
    return [
        .current(presentationData.theme, address.described),
        .change(presentationData.theme, serverSettingsChange(presentationData.strings)),
        .changeInfo(presentationData.theme, serverSettingsChangeInfo(presentationData.strings)),
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
    dismissImpl = { [weak controller] in
        controller?.dismiss()
    }
    return controller
}
