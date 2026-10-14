import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import AccountContext
import WalletContext

/// ice9's WalletWordsScreen: no wallet here (#278). The app never makes a WalletContext
/// and `WalletConfiguration.isAvailable` is false, so nothing reaches this
/// screen; if something does, it goes away. Each initializer keeps upstream's
/// labels and ignores every argument.

public final class WalletWordsScreen: ViewController {
    public init(context: AccountContext, words: [String], mode: WalletWordsScreenMode, dismissOnBackgroundOrLock: Bool = false, completion: (() -> Void)?) {
        super.init(navigationBarPresentationData: nil)
    }

    public init(context: AccountContext, words: [String], verify: Bool, dismissOnBackgroundOrLock: Bool = false, completion: (() -> Void)?) {
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
