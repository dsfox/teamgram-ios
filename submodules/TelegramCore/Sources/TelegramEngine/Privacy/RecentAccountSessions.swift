import Foundation
import Postbox
import TelegramApi
import SwiftSignalKit

func requestRecentAccountSessions(account: Account) -> Signal<([RecentAccountSession], Int32), NoError> {
    return account.network.request(Api.functions.account.getAuthorizations())
    |> retryRequestIfNotFrozen
    |> map { result -> ([RecentAccountSession], Int32) in
        guard let result else {
            return ([], 1)
        }
        var sessions: [RecentAccountSession] = []
        var ttlDays: Int32 = 1
        switch result {
            case let .authorizations(authorizationsData):
                let (authorizationTtlDays, authorizations) = (authorizationsData.authorizationTtlDays, authorizationsData.authorizations)
                for authorization in authorizations {
                    sessions.append(RecentAccountSession(apiAuthorization: authorization))
                }
            ttlDays = authorizationTtlDays
        }
        return (sessions, ttlDays)
    }
}

public enum TerminateSessionError {
    case generic
    case freshReset
}

func terminateAccountSession(account: Account, hash: Int64) -> Signal<Void, TerminateSessionError> {
    return account.network.request(Api.functions.account.resetAuthorization(hash: hash))
    |> mapError { error -> TerminateSessionError in
        if error.errorCode == 406 {
            return .freshReset
        }
        return .generic
    }
    |> mapToSignal { _ -> Signal<Void, TerminateSessionError> in
        // The phone that just lost a device is this one, and it is the one that
        // has to take that device's leaf out of every conversation. Left to its
        // own rhythm it would notice a quarter of an hour later, and until then
        // the phone that was signed out goes on reading everything said (#121).
        return askHowManyDevices(postbox: account.postbox, network: account.network,
                                 accountPeerId: account.peerId)
        |> castError(TerminateSessionError.self)
    }
}

func terminateOtherAccountSessions(account: Account) -> Signal<Void, TerminateSessionError> {
    return account.network.request(Api.functions.auth.resetAuthorizations())
    |> mapError { error -> TerminateSessionError in
        if error.errorCode == 406 {
            return .freshReset
        }
        return .generic
    }
    |> mapToSignal { _ -> Signal<Void, TerminateSessionError> in
        // The same as ending one session, and the commoner way to answer
        // "I have lost my phone" (#121).
        return askHowManyDevices(postbox: account.postbox, network: account.network,
                                 accountPeerId: account.peerId)
        |> castError(TerminateSessionError.self)
    }
}

public enum UpadteAuthorizationTTLError {
    case generic
}

func setAuthorizationTTL(account: Account, ttl: Int32) -> Signal<Void, UpadteAuthorizationTTLError> {
    return account.network.request(Api.functions.account.setAuthorizationTTL(authorizationTtlDays: ttl))
    |> mapError { error -> UpadteAuthorizationTTLError in
        return .generic
    }
    |> mapToSignal { _ -> Signal<Void, UpadteAuthorizationTTLError> in
        return .single(Void())
    }
}

public enum UpdateSessionError {
    case generic
}

func updateAccountSessionAcceptsSecretChats(account: Account, hash: Int64, accepts: Bool) -> Signal<Void, UpdateSessionError> {
    return account.network.request(Api.functions.account.changeAuthorizationSettings(flags: 1 << 0, hash: hash, encryptedRequestsDisabled: accepts ? .boolFalse : .boolTrue, callRequestsDisabled: nil))
    |> mapError { error -> UpdateSessionError in
        return .generic
    }
    |> mapToSignal { _ -> Signal<Void, UpdateSessionError> in
        return .single(Void())
    }
}

func updateAccountSessionAcceptsIncomingCalls(account: Account, hash: Int64, accepts: Bool) -> Signal<Void, UpdateSessionError> {
    return account.network.request(Api.functions.account.changeAuthorizationSettings(flags: 1 << 1, hash: hash, encryptedRequestsDisabled: nil, callRequestsDisabled: accepts ? .boolFalse : .boolTrue))
    |> mapError { error -> UpdateSessionError in
        return .generic
    }
    |> mapToSignal { _ -> Signal<Void, UpdateSessionError> in
        return .single(Void())
    }
}
