import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import AccountContext
import WalletContext

/// ice9's WalletReceiveScreen: no wallet here (#278). The app never makes a WalletContext
/// and `WalletConfiguration.isAvailable` is false, so nothing reaches this
/// screen; if something does, it goes away. Each initializer keeps upstream's
/// labels and ignores every argument.

public final class WalletReceiveScreen: ViewController {
    public init(context: AccountContext, address: String, appeared: (() -> Void)? = nil) {
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
