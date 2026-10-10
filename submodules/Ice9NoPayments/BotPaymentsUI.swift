import Foundation
import UIKit
import Display
import TelegramCore
import SwiftSignalKit
import AccountContext

/// ice9's BotPaymentsUI: no checkout, no card entry, no Apple Pay (#181). The
/// server answers no invoice and links to one open nothing, so these are not
/// reached; if one ever is, it says it failed and goes away.
public final class BotCheckoutController: ViewController {
    public final class InputData {
        public enum FetchError {
            case generic
            case disallowedStarGifts
            case starGiftsUserLimit
        }

        public let form: BotPaymentForm
        public let validatedFormInfo: BotPaymentValidatedFormInfo?
        public let botPeer: EnginePeer?

        public init(
            form: BotPaymentForm,
            validatedFormInfo: BotPaymentValidatedFormInfo?,
            botPeer: EnginePeer?
        ) {
            self.form = form
            self.validatedFormInfo = validatedFormInfo
            self.botPeer = botPeer
        }

        public static func fetch(context: AccountContext, source: BotPaymentInvoiceSource) -> Signal<InputData, FetchError> {
            return .fail(.generic)
        }
    }

    private let failed: () -> Void
    private var reported = false

    public init(context: AccountContext, invoice: TelegramMediaInvoice, source: BotPaymentInvoiceSource, inputData: Promise<BotCheckoutController.InputData?>, completed: @escaping (String, EngineMessage.Id?) -> Void, pending: @escaping () -> Void = {}, cancelled: @escaping () -> Void = {}, failed: @escaping () -> Void = {}) {
        self.failed = failed
        super.init(navigationBarPresentationData: nil)
    }

    required public init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override public func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if self.reported {
            return
        }
        self.reported = true
        Queue.mainQueue().async { [weak self] in
            self?.failed()
            self?.dismiss(animated: false)
        }
    }
}

public final class BotReceiptController: ViewController {
    private var dismissed = false

    public init(context: AccountContext, messageId: EngineMessage.Id) {
        super.init(navigationBarPresentationData: nil)
    }

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
