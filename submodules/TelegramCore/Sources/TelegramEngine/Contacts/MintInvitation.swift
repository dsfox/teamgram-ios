import Foundation
import SwiftSignalKit
import TelegramApi
import MtProtoKit

public enum MintInvitationError {
    /// The number already has an account here: there is nobody to invite,
    /// just somebody to write to - or, from a picker, to add.
    case alreadyHere
    /// The group the code was asked for is not one the person is in (#164).
    case notInGroup
    case generic
}

/// A six-digit code bound to this number (#47), and to a group when minted
/// from one (#164): the server puts whoever signs up with it into the group.
/// The phone's own SMS app carries the code to that number over the
/// inviter's carrier, so only the person the carrier delivers to can sign in
/// with it.
func _internal_mintInvitation(network: Network, phone: String, chat: Int64?) -> Signal<String, MintInvitationError> {
    let request: Signal<Api.invite.Minted, MTRpcError>
    if let chat {
        request = network.request(Api.functions.invite.mintForChat(chatId: chat, phone: phone))
    } else {
        request = network.request(Api.functions.invite.mint(phone: phone))
    }
    return request
    |> mapError { error -> MintInvitationError in
        Logger.shared.log("Invite", "no code for the number - \(error.errorDescription ?? "no answer")")
        if error.errorDescription == "PHONE_ALREADY_HERE" {
            return .alreadyHere
        }
        if error.errorDescription == "USER_NOT_PARTICIPANT" {
            return .notInGroup
        }
        return .generic
    }
    |> map { minted -> String in
        // The same line Android prints: one number, the code in the body, and the group if any.
        Logger.shared.log("Invite", "composing an SMS to one number with code \(minted.code)" + (chat.map { " for chat \($0)" } ?? ""))
        return minted.code
    }
}
