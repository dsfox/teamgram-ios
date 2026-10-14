import Foundation
import LocalAuthentication
import SwiftSignalKit
import TelegramCore
import PasscodeCore

/// ice9's WalletContext: there is no wallet here (#278). Telegram 13.0 ships a
/// TON wallet, which is the payment functionality Apple refused 12.9.2 for
/// (#181), so the module compiles this file instead of upstream's: the app
/// never makes a WalletContext (AccountContextImpl sets it to nil), every
/// screen behind it compiles a stub, and the Rust engine under it is not
/// linked. What lives on is the app passcode, which upstream keeps in this
/// module: its keychain service name and the protection settings, delegated
/// to PasscodeCore as upstream does. Everything else below exists so the code
/// that reaches for a wallet it will never find keeps compiling.

// MARK: - The app passcode, alive

/// The keychain service the passcode's biometric item is stored under; a
/// phone that set its passcode on an earlier build has it under this name.
public let walletBiometricKeychainService = "org.telegram.ton-wallet.vault.v1.biometric"

public struct WalletProtectionSettings: Equatable, Sendable {
    public let passcode: PasscodeCredentialReference?
    public let enabled: Bool
    public let biometricsEnabled: Bool
}

public struct WalletAuthorizationRequest: Sendable {
    public let id: UUID
    public let namespace: String
    public let reason: String
    public let lifetime: PasscodeSession.Lifetime
}

public func walletProtectionSettings(credentials: PasscodeCredentialStore = .shared) throws -> WalletProtectionSettings {
    let settings = try credentials.protectionSettings()
    return WalletProtectionSettings(passcode: settings.passcode, enabled: settings.enabled, biometricsEnabled: settings.biometricsEnabled)
}

public func setWalletProtectionEnabled(_ enabled: Bool, session: PasscodeSession, credentials: PasscodeCredentialStore = .shared) throws {
    try credentials.validate(session, scope: .settings)
    guard try credentials.protectionSettings().enabled != enabled else {
        return
    }
    if enabled {
        try credentials.resumeCleanup()
    }
    try credentials.setProtectionEnabled(enabled, session: session)
}

public func setWalletBiometricsEnabled(_ enabled: Bool, session: PasscodeSession, context: LAContext, credentials: PasscodeCredentialStore = .shared) throws {
    try credentials.validate(session, scope: .settings)
    let settings = try credentials.protectionSettings()
    guard settings.enabled else {
        throw PasscodeError.authenticationRequired
    }
    guard settings.biometricsEnabled != enabled else {
        return
    }
    if enabled {
        try credentials.enableBiometrics(session: session, context: context)
    } else {
        try credentials.disableBiometrics(session: session)
    }
}

public func authenticateWalletBiometrics(namespace: String, lifetime: PasscodeSession.Lifetime = .standard, context: LAContext, credentials: PasscodeCredentialStore = .shared) throws -> PasscodeSession {
    return try credentials.authenticateBiometrics(context: context, scope: .resource(namespace: namespace), lifetime: lifetime)
}

/// Resets the passcode credential. Upstream also wipes the wallet's vault
/// here; there is none.
public func resetWalletLocalSecrets(environment: PasscodeEnvironment = .shared, credentials: PasscodeCredentialStore = .shared) throws {
    guard environment.isMainApp else { throw PasscodeError.unavailable }
    try credentials.resetCredential(removingProtectedData: {})
}

public func _internalResetLocalSecretsForPasscodeMigrationTest(then: () throws -> Never) throws -> Never {
    let environment = PasscodeEnvironment.shared
    guard environment.isMainApp else { throw PasscodeError.unavailable }
    try PasscodeCredentialStore.shared._internalResetForPasscodeMigrationTest(removingProtectedData: {}, then: then)
}

// MARK: - The wallet, absent

/// Never available, whatever the server's app configuration says: there is no
/// wallet to make available.
public struct WalletConfiguration: Equatable, Sendable {
    public let isAvailable: Bool
    public let explorerUrl: String

    public static func with(appConfiguration: AppConfiguration) -> WalletConfiguration {
        return WalletConfiguration(isAvailable: false, explorerUrl: "")
    }
}

/// Nothing can make one: the app reads `context.walletContext`, which is nil.
public final class WalletContext {
    private init() {
    }

    /// A TON address in a message is not a link here.
    public static func transferAddress(from value: String, preserveBounce: Bool = false) -> String? {
        return nil
    }

    public static func isTonConnectUrl(_ value: String) -> Bool {
        return false
    }

    public func setAuthorizationPresenter(_ presenter: @escaping @Sendable (WalletAuthorizationRequest) async throws -> PasscodeSession) {
    }

    public var state: Signal<State, NoError> {
        return .never()
    }

    public var stateValue: State {
        return State()
    }

    public var tonConnectState: Signal<TonConnectState, NoError> {
        return .never()
    }

    public func processTonConnectUrl(_ value: String) {
    }

    public func openTonConnectRequest(sessionId: Int64, messageId: EngineMessage.Id) {
    }

    public func decideTonConnectRequest(id: String, approve: Bool) -> Signal<TonConnectDecisionResult, WalletError> {
        return .fail(.unavailable)
    }

    public func rejectTonConnectRequest(id: String) {
    }

    public func retryTonConnectRequest(id: String) {
    }

    public func closeTonConnectPresentation(id: String) {
    }

    public func logoutWarningBalance() -> Signal<Int64?, NoError> {
        return .single(nil)
    }
}

public extension WalletContext {
    enum FiatCurrency: Equatable, Sendable {
        case usd

        public var code: String {
            return "USD"
        }

        public var symbol: String {
            return "$"
        }
    }

    struct FiatRate: Equatable, Sendable {
        public let unitsPerUsd: Double
        public let unitsPerGram: Double

        public init(unitsPerUsd: Double, unitsPerGram: Double) {
            self.unitsPerUsd = unitsPerUsd
            self.unitsPerGram = unitsPerGram
        }
    }

    struct FiatState: Equatable, Sendable {
        public let selectedCurrency: FiatCurrency
        public let selectedRate: FiatRate?

        public init(selectedCurrency: FiatCurrency = .usd, selectedRate: FiatRate? = nil) {
            self.selectedCurrency = selectedCurrency
            self.selectedRate = selectedRate
        }
    }

    enum Resource<Value: Equatable>: Equatable {
        case idle

        public var currentValue: Value? {
            return nil
        }
    }

    struct WalletInfo: Equatable, Sendable {
        public let address: String
    }

    enum Phase: Equatable, Sendable {
        case empty
        case wallet(WalletInfo)
    }

    struct Transaction: Equatable, Sendable {
        public enum Kind: Int32, Equatable, Sendable {
            case transfer = 0
        }

        public enum Direction: Int32, Equatable, Sendable {
            case incoming = 0
            case outgoing = 1
            case unknown = 2
        }

        public enum Status: Int32, Equatable, Sendable {
            case completed = 0
            case pending = 1
            case failed = 2
        }

        public enum Peer: Equatable, @unchecked Sendable {
            case user(EnginePeer, address: String, domain: String?)
            case address(String, domain: String?)
            case unsupported
        }

        public struct CollectibleTransfer: Equatable, Sendable {
        }

        public let id: String
        public let presentationId: String
        public let transactionHash: String?
        public let logicalTime: String
        public let timestamp: Int32
        public let kind: Kind
        public let direction: Direction
        public let amount: Int64
        public let fee: Int64
        public let peer: Peer
        public let comment: String?
        public let commentEncrypted: Bool
        public let collectible: CollectibleTransfer?
        public let status: Status

        public init(
            id: String,
            presentationId: String? = nil,
            transactionHash: String? = nil,
            logicalTime: String,
            timestamp: Int32,
            direction: Direction,
            amount: Int64,
            fee: Int64,
            peer: Peer,
            comment: String?,
            commentEncrypted: Bool = false,
            collectible: CollectibleTransfer? = nil,
            status: Status = .completed,
            kind: Kind = .transfer
        ) {
            self.id = id
            self.presentationId = presentationId ?? id
            self.transactionHash = transactionHash
            self.logicalTime = logicalTime
            self.timestamp = timestamp
            self.kind = kind
            self.direction = direction
            self.amount = amount
            self.fee = fee
            self.peer = peer
            self.comment = comment
            self.commentEncrypted = commentEncrypted
            self.collectible = collectible
            self.status = status
        }
    }

    struct TransactionsState: Equatable, Sendable {
        public let items: [Transaction]

        public init(items: [Transaction] = []) {
            self.items = items
        }
    }

    struct PendingTransfer: Equatable, Sendable {
        public enum Status: Int32, Equatable, Sendable {
            case broadcasting = 0
            case pending = 1
            case submissionUnknown = 2
            case confirmed = 3
        }

        public let id: String
        public let collectibleAddress: String?
        public let pendingMessage: WalletPendingTransferMessageReference?
        public let transactionHash: String?
        public let status: Status
    }

    struct State: Equatable, Sendable {
        public let phase: Phase
        public let walletAddress: String?
        public let balance: Resource<Int64>
        public let transactions: TransactionsState
        public let pendingTransfers: [PendingTransfer]
        public let fiat: FiatState

        public init() {
            self.phase = .empty
            self.walletAddress = nil
            self.balance = .idle
            self.transactions = TransactionsState()
            self.pendingTransfers = []
            self.fiat = FiatState()
        }
    }

    enum WalletError: Error, Equatable, Sendable {
        case unavailable
    }

    struct PreparedTransfer: Equatable, Sendable {
        public let id: String
    }

    struct Collectible: Equatable, Sendable {
        public let address: String
    }

    struct TonConnectRequest: Equatable, Sendable {
        public let id: String
        public let applicationName: String
        public let domain: String
        public let icon: WalletTonConnectIcon?
    }

    struct TonConnectSignDataRequest: Equatable, Sendable {
        public let id: String
        public let applicationName: String
        public let domain: String
        public let icon: WalletTonConnectIcon?
    }

    struct TonConnectOperationRequest: Equatable, Sendable {
        public enum Method: Equatable, Sendable {
            case sendTransaction
            case signMessage
            case signData
        }

        public struct Message: Equatable, Sendable {
        }

        public let id: String
        public let applicationName: String
        public let domain: String
        public let icon: WalletTonConnectIcon?
        public let method: Method
        public let messages: [Message]
        public let feeNanograms: Int64?
        public let validUntil: Int64?
        public let relayerWillSubmit: Bool
        public let needsWalletStateInit: Bool
        public let warnings: [String]
        public let actions: [String]
        public let signData: TonConnectSignDataRequest?

        public init(id: String, applicationName: String, domain: String, icon: WalletTonConnectIcon?, method: Method, messages: [Message], feeNanograms: Int64?, validUntil: Int64?, relayerWillSubmit: Bool, needsWalletStateInit: Bool, warnings: [String], actions: [String], signData: TonConnectSignDataRequest?) {
            self.id = id
            self.applicationName = applicationName
            self.domain = domain
            self.icon = icon
            self.method = method
            self.messages = messages
            self.feeNanograms = feeNanograms
            self.validUntil = validUntil
            self.relayerWillSubmit = relayerWillSubmit
            self.needsWalletStateInit = needsWalletStateInit
            self.warnings = warnings
            self.actions = actions
            self.signData = signData
        }
    }

    struct TonConnectActiveRequest: Equatable, Sendable {
        public enum Content: Equatable, Sendable {
            case connect(TonConnectRequest)
            case operation(TonConnectOperationRequest)
            case signData(TonConnectSignDataRequest)
        }

        public let content: Content
        public let status: TonConnectRequestStatus

        public var id: String {
            switch self.content {
            case let .connect(value):
                return value.id
            case let .operation(value):
                return value.id
            case let .signData(value):
                return value.id
            }
        }
    }

    struct TonConnectState: Equatable, Sendable {
        public let active: TonConnectActiveRequest?
        public let presentationEnabled: Bool
        public let diagnostic: TonConnectDiagnostic?
    }

    typealias TonConnectDecisionResult = TonConnectDecision
    typealias TonConnectReturn = TonConnectReturnTarget
}

public struct WalletPendingTransferMessageReference: Equatable, Sendable {
    public let localId: Int32
}

public enum TonConnectFailure: Error, Equatable, Sendable {
    case unavailable

    public var message: String {
        return ""
    }
}

public enum TonConnectReturnTarget: Equatable, Sendable {
    case back
    case none
    case url(String)
}

public struct TonConnectDecision: Equatable, Sendable {
    public let approved: Bool
    public let failure: TonConnectFailure?
    public let returnTarget: TonConnectReturnTarget
}

public enum TonConnectRequestStatus: Equatable, Sendable {
    case ready
    case processing
    case completed(TonConnectDecision)
    case invalidated
}

public struct TonConnectDiagnostic: Equatable, Sendable {
    public let id: UUID
    public let failure: TonConnectFailure
    public let requestId: String?
}
