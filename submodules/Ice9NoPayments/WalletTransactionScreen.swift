import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import AccountContext
import WalletContext

/// ice9's WalletTransactionScreen: no wallet here (#278). The app never makes a WalletContext
/// and `WalletConfiguration.isAvailable` is false, so nothing reaches this
/// screen; if something does, it goes away. Each initializer keeps upstream's
/// labels and ignores every argument.

public final class WalletTransactionScreen: ViewController {
    public init(context: AccountContext, updatedPresentationData: (initial: PresentationData, signal: Signal<PresentationData, NoError>)? = nil, walletContext: WalletContext? = nil, transaction: WalletContext.Transaction, fromChat: Bool, decryptCommentOnOpen: Bool = false) {
        super.init(navigationBarPresentationData: nil)
    }

    private var dismissed = false

    required public init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override public func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if self.dismissed {
            return
        }
        self.dismissed = true
        Queue.mainQueue().async { [weak self] in
            self?.dismiss(animated: false)
        }
    }
}

public final class WalletTransactionPreviewScreen: ViewController {
    public init(context: AccountContext, updatedPresentationData: (initial: PresentationData, signal: Signal<PresentationData, NoError>)? = nil, walletContext: WalletContext, preparedTransfer: WalletContext.PreparedTransfer, dismissSendScreen: @escaping () -> Void) {
        super.init(navigationBarPresentationData: nil)
    }

    public init(context: AccountContext, updatedPresentationData: (initial: PresentationData, signal: Signal<PresentationData, NoError>)? = nil, walletContext: WalletContext, address: String, recipientPeer: EnginePeer? = nil, amount: Int64, sendAll: Bool, comment: String?, collectible: WalletContext.Collectible? = nil, initialFee: Int64? = nil, dismissSendScreen: @escaping () -> Void) {
        super.init(navigationBarPresentationData: nil)
    }

    private var dismissed = false

    required public init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override public func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if self.dismissed {
            return
        }
        self.dismissed = true
        Queue.mainQueue().async { [weak self] in
            self?.dismiss(animated: false)
        }
    }
}
