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

    public var hasTransferBackgroundTasks: Signal<Bool, NoError> {
        return .single(false)
    }

    /// No message widget gets a wallet here.
    public var widgetWalletReady: Signal<Bool, NoError> {
        return .single(false)
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
        public let collectibles: CollectiblesState
        public let pendingTransfers: [PendingTransfer]
        public let fiat: FiatState
        public let cardStickers: [CardSticker]
        public var cardStyle: CardGiftStyle? { self.cardStickers.compactMap(\.style).last }

        public init() {
            self.phase = .empty
            self.walletAddress = nil
            self.balance = .idle
            self.transactions = TransactionsState()
            self.collectibles = .empty
            self.pendingTransfers = []
            self.fiat = FiatState()
            self.cardStickers = []
        }
    }

    enum WalletError: Error, Equatable, Sendable {
        case unavailable
    }

    struct PreparedTransfer: Equatable, Sendable {
        public let id: String
    }

    /// The shape upstream's gift and card code reads; the wallet that would
    /// fill it is absent, so every list of them is empty.
    struct Collectible: Codable, Equatable, Sendable {
        public enum Kind: Int32, Codable, Equatable, Sendable {
            case gift = 0
            case username = 1
            case anonymousNumber = 2
            case other = 3
        }

        public let address: String
        public let name: String
        public let subtitle: String
        public let kind: Kind
        public let description: String?
        public let collectionName: String?
        public let collectionUrl: String?
        public let attributes: [String: String]
        public let giftSlug: String?
        public let nft: WalletNftItem?

        public var image: WalletNftFile? { self.nft?.image ?? self.nft?.imageSmall }
        public var thumbnail: WalletNftFile? { self.nft?.imageSmall ?? self.nft?.image }
        public var lottie: WalletNftFile? { self.nft?.lottie }

        public init(
            address: String,
            name: String,
            subtitle: String = "NFT",
            kind: Kind = .other,
            description: String? = nil,
            collectionName: String? = nil,
            collectionUrl: String? = nil,
            attributes: [String: String] = [:],
            giftSlug: String? = nil,
            nft: WalletNftItem? = nil
        ) {
            self.address = address
            self.name = name
            self.subtitle = subtitle
            self.kind = kind
            self.description = description
            self.collectionName = collectionName
            self.collectionUrl = collectionUrl
            self.attributes = attributes
            self.giftSlug = giftSlug
            self.nft = nft
        }
    }

    struct CollectiblesState: Equatable, Sendable {
        public let items: [Collectible]

        public static var empty: CollectiblesState {
            return CollectiblesState(items: [])
        }
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
            public enum Payload: Equatable, Sendable {
                case empty
                case comment(String)
                case raw(String)
            }

            public let id: String
            public let destination: String
            public let amountNanograms: String
            public let payload: Payload
            public let stateInit: String?

            public init(id: String, destination: String, amountNanograms: String, payload: Payload, stateInit: String?) {
                self.id = id
                self.destination = destination
                self.amountNanograms = amountNanograms
                self.payload = payload
                self.stateInit = stateInit
            }
        }

        public struct Action: Equatable, Sendable {
            public let id: String
            public let kind: String
            public let succeeded: Bool
            public let accounts: [String]
            public let detailsJson: String

            public init(id: String, kind: String, succeeded: Bool, accounts: [String], detailsJson: String = "{}") {
                self.id = id
                self.kind = kind
                self.succeeded = succeeded
                self.accounts = accounts
                self.detailsJson = detailsJson
            }
        }

        public let id: String
        public let applicationName: String
        public let domain: String
        public let icon: WalletTonConnectIcon?
        public let method: Method
        public let messages: [Message]
        public let feeNanograms: String?
        public let validUntil: UInt64?
        public let signData: TonConnectSignDataRequest?
        public let relayerWillSubmit: Bool
        public let needsWalletStateInit: Bool
        public let warnings: [String]
        public let actions: [Action]

        public init(id: String, applicationName: String, domain: String, icon: WalletTonConnectIcon?, method: Method, messages: [Message], feeNanograms: String?, validUntil: UInt64?, relayerWillSubmit: Bool, needsWalletStateInit: Bool, warnings: [String], actions: [Action], signData: TonConnectSignDataRequest? = nil) {
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

// MARK: - Telegram 13.2's card, gift and widget calls, absent (#298)

public extension WalletContext {
    struct CardGiftStyle: Codable, Equatable, Sendable {
        public let innerColor: Int32
        public let outerColor: Int32
        public let patternColor: Int32
        public let patternFile: Data?

        public init(innerColor: Int32, outerColor: Int32, patternColor: Int32, patternFile: Data?) {
            self.innerColor = innerColor
            self.outerColor = outerColor
            self.patternColor = patternColor
            self.patternFile = patternFile
        }
    }

    /// Editor geometry, relative to the untransformed card; the card has none here.
    struct CardSticker: Codable, Equatable, Sendable {
        public let gift: Collectible
        public let x: Double
        public let y: Double
        public let angle: Double
        public let scale: Double
        public let modelFile: Data?
        public let geometryVersion: Int?
        public let aspectRatio: Double?
        public let cornerRadius: Double?
        public let style: CardGiftStyle?
        public let giftStyle: CardGiftStyle?
        public static let minimumScale = 32.0 / 83.4
        public static let maximumScale = 1.1
        public static let widthFraction = 83.4 / 361.0

        public var renderedWidthFraction: Double {
            self.geometryVersion == nil ? 80.0 / 370.0 * (276.0 / 298.0) * self.scale : Self.widthFraction * self.scale
        }

        public func updated(x: Double? = nil, y: Double? = nil, angle: Double? = nil, scale: Double? = nil,
                            modelFile: Data? = nil, geometryVersion: Int? = nil) -> CardSticker {
            CardSticker(gift: self.gift, x: x ?? self.x, y: y ?? self.y, angle: angle ?? self.angle,
                scale: scale ?? self.scale, modelFile: modelFile ?? self.modelFile,
                geometryVersion: geometryVersion ?? self.geometryVersion, style: self.style, giftStyle: self.giftStyle,
                aspectRatio: self.aspectRatio, cornerRadius: self.cornerRadius)
        }

        public func withStyle(_ style: CardGiftStyle?) -> CardSticker {
            CardSticker(gift: self.gift, x: self.x, y: self.y, angle: self.angle, scale: self.scale,
                modelFile: self.modelFile, geometryVersion: self.geometryVersion, style: style, giftStyle: self.giftStyle ?? style,
                aspectRatio: self.aspectRatio, cornerRadius: self.cornerRadius)
        }

        public init(gift: Collectible, x: Double, y: Double, angle: Double, scale: Double, modelFile: Data? = nil, geometryVersion: Int? = nil, style: CardGiftStyle? = nil, giftStyle: CardGiftStyle? = nil,
                    aspectRatio: Double? = nil, cornerRadius: Double? = nil) {
            self.gift = gift
            self.x = x
            self.y = y
            self.angle = angle
            self.scale = scale
            self.modelFile = modelFile
            self.geometryVersion = geometryVersion
            self.aspectRatio = aspectRatio
            self.cornerRadius = cornerRadius
            self.style = style
            self.giftStyle = giftStyle ?? style
        }
    }

    struct ResolvedTransferRecipient: Equatable, Sendable {
        public let address: String
        public let displayName: String?
        public let transferLink: String?

        public var transferInput: String {
            return self.transferLink ?? self.address
        }

        public init(address: String, displayName: String?, transferLink: String? = nil) {
            self.address = address
            self.displayName = displayName
            self.transferLink = transferLink
        }
    }

    /// No text is a TON recipient here, and nothing is the wallet's own address.
    static func transferRecipient(from value: String) -> ResolvedTransferRecipient? {
        return nil
    }

    func resolveTransferRecipient(_ value: String) -> Signal<ResolvedTransferRecipient?, WalletError> {
        return .single(nil)
    }

    static func isSelfTransfer(recipient: String, walletAddress: String?) -> Bool {
        return false
    }

    enum TransferFeeComment: Equatable, Sendable {
        case none
        case plainText(byteCount: Int)
        case encrypted
    }

    struct TransferFeeEstimate: Equatable, Sendable {
        public let fee: Int64
    }

    func estimateTransferFee(address: String, comment: TransferFeeComment) -> Signal<TransferFeeEstimate, WalletError> {
        return .fail(.unavailable)
    }

    enum TransferSubmissionStage: Equatable, Sendable {
        case waitingForPreviousTransfer
        case signing
        case submitted
    }

    func prepareCollectibleDeposit(collectible: Collectible, address: String, payload: Data, amount: Int64) -> Signal<PreparedTransfer, WalletError> {
        return .fail(.unavailable)
    }

    func submitTransfer(
        _ prepared: PreparedTransfer,
        recipientPeerId: EnginePeer.Id? = nil,
        pendingMessageCreated: (@MainActor @Sendable () -> Void)? = nil,
        session: PasscodeSession? = nil,
        stageUpdated: (@MainActor @Sendable (TransferSubmissionStage) -> Void)? = nil
    ) -> Signal<PendingTransfer, WalletError> {
        return .fail(.unavailable)
    }

    /// Who asks: the bot of the widget's message. Bots are off here (Offered),
    /// and no widget reaches a wallet.
    struct WidgetWalletRequester: Equatable, Sendable {
        public let botId: Int64
        public let name: String
        public let username: String?

        public init(botId: Int64, name: String, username: String?) {
            self.botId = botId
            self.name = name
            self.username = username
        }

        public var signDomain: String {
            return "bot\(self.botId)"
        }

        public var displayDomain: String {
            return self.username.map { "@\($0)" } ?? self.name
        }
    }

    enum WidgetWalletFailure: Error, Equatable, Sendable {
        case rejected
        case badRequest
        case insufficientBalance
        case failed
    }

    struct WidgetPreparedTransaction: Equatable, Sendable {
        public let request: TonConnectOperationRequest
    }

    struct WidgetSentTransaction: Equatable {
        public let msgHash: String
        public let wallet: EngineUserWallet
    }

    struct WidgetPreparedSignData: Equatable, Sendable {
        public let request: TonConnectOperationRequest
    }

    struct WidgetSignedData: Equatable {
        public let responseJson: String
        public let wallet: EngineUserWallet
    }

    func prepareWidgetTransaction(json: String, requester: WidgetWalletRequester) -> Signal<WidgetPreparedTransaction, WidgetWalletFailure> {
        return .fail(.failed)
    }

    func discardWidgetTransaction(_ prepared: WidgetPreparedTransaction) {
    }

    func submitWidgetTransaction(_ prepared: WidgetPreparedTransaction) -> Signal<WidgetSentTransaction, WidgetWalletFailure> {
        return .fail(.failed)
    }

    func prepareWidgetSignData(json: String, requester: WidgetWalletRequester) -> Signal<WidgetPreparedSignData, WidgetWalletFailure> {
        return .fail(.failed)
    }

    func signWidgetData(_ prepared: WidgetPreparedSignData) -> Signal<WidgetSignedData, WidgetWalletFailure> {
        return .fail(.failed)
    }
}

public extension WalletContext.CardSticker {
    /// A card sticker from the server: there is no card here, so none.
    init?(serverSticker: WalletCard.Sticker, backgroundNftAddress: String? = nil) {
        return nil
    }
}
