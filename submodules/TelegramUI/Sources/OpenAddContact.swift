import Foundation
import SwiftSignalKit
import TelegramCore
import Display
import DeviceAccess
import AccountContext
import ShareController
import AlertUI
import PresentationDataUtils
import PeerInfoUI
import PhoneNumberFormat

func openAddContactImpl(context: AccountContext, peer: EnginePeer?, firstName: String = "", lastName: String = "", phoneNumber: String, label: String = "_$!<Mobile>!$_", present: @escaping (ViewController, Any?) -> Void, pushController: @escaping (ViewController) -> Void, completed: @escaping () -> Void = {}) {
    let _ = (DeviceAccess.authorizationStatus(subject: .contacts)
    |> take(1)
    |> deliverOnMainQueue).startStandalone(next: { value in
        switch value {
        case .notDetermined:
            DeviceAccess.authorizeAccess(to: .contacts)
        default:
            // Allowed, denied or restricted alike: the screen takes a typed
            // number and reads nothing from the book (#164). Saving to the
            // book is its own toggle, off when the book is not ours to write.
            let controller = context.sharedContext.makeNewContactScreen(
                context: context,
                peer: peer,
                firstName: firstName.isEmpty ? nil : firstName,
                lastName: lastName.isEmpty ? nil : lastName,
                phoneNumber: cleanPhoneNumber(phoneNumber, removePlus: true),
                shareViaException: false,
                completion: { peer, stableId, contactData in
                    if let peer = peer {
                        if let infoController = context.sharedContext.makePeerInfoController(context: context, updatedPresentationData: nil, peer: peer, mode: .generic, avatarInitiallyExpanded: false, fromChat: false, requestsContext: nil) {
                            pushController(infoController)
                        }
                    } else if let stableId, let contactData {
                        pushController(deviceContactInfoController(context: ShareControllerAppAccountContext(context: context), environment: ShareControllerAppEnvironment(sharedContext: context.sharedContext), subject: .vcard(nil, stableId, contactData), completed: nil, cancelled: nil))
                    }
                    completed()
                }
            )
            pushController(controller)
        }
    })
}
