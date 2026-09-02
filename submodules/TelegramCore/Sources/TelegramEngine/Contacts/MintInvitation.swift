import Foundation
import SwiftSignalKit
import TelegramApi
import MtProtoKit

public enum MintInvitationError {
    /// The number already has an account here: there is nobody to invite,
    /// just somebody to write to.
    case alreadyHere
    case generic
}

/// A six-digit code bound to this number (#47). The phone's own SMS app
/// carries it to that number over the inviter's carrier, so only the person
/// the carrier delivers to can sign in with it.
func _internal_mintInvitation(network: Network, phone: String) -> Signal<String, MintInvitationError> {
    return network.request(Api.functions.invite.mint(phone: phone))
    |> mapError { error -> MintInvitationError in
        Logger.shared.log("Invite", "no code for the contact - \(error.errorDescription ?? "no answer")")
        if error.errorDescription == "PHONE_ALREADY_HERE" {
            return .alreadyHere
        }
        return .generic
    }
    |> map { minted -> String in
        // The same line Android prints: one number, and the code is in the body.
        Logger.shared.log("Invite", "composing an SMS to one number with code \(minted.code)")
        return minted.code
    }
}
