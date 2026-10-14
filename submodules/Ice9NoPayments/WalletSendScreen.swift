import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import AccountContext
import WalletContext
import AttachmentUI
import PremiumDiamondComponent

/// ice9's WalletSendScreen: no wallet here (#278). The app never makes a WalletContext
/// and `WalletConfiguration.isAvailable` is false, so nothing reaches this
/// screen; if something does, it goes away. Each initializer keeps upstream's
/// labels and ignores every argument.

public typealias WalletSendTransferAnimation = (String, WalletSendTransferAnimationSource?) -> Bool

/// Where a sent transfer's diamond would fly from. Nothing makes one.
public final class WalletSendTransferAnimationSource {
    public let diamond: InteractiveDiamondComponent.View
    public weak var window: UIWindow?
    public let center: CGPoint
    public let width: CGFloat
    public let rotation: CGFloat

    private init(diamond: InteractiveDiamondComponent.View, window: UIWindow, center: CGPoint, width: CGFloat, rotation: CGFloat) {
        self.diamond = diamond
        self.window = window
        self.center = center
        self.width = width
        self.rotation = rotation
    }

    public func updateFlightHaptics(at time: CFTimeInterval) {
    }
}

public final class WalletSendScreen: ViewController, AttachmentContainable {
    public var transferAnimationWillStart: ((String) -> Void)?

    public var requestAttachmentMenuExpansion: () -> Void = {}
    public var updateNavigationStack: (@escaping ([AttachmentContainable]) -> ([AttachmentContainable], AttachmentMediaPickerContext?)) -> Void = { _ in }
    public var parentController: () -> ViewController? = { nil }
    public var updateTabBarAlpha: (CGFloat, ContainedViewLayoutTransition) -> Void = { _, _ in }
    public var updateTabBarVisibility: (Bool, ContainedViewLayoutTransition) -> Void = { _, _ in }
    public var cancelPanGesture: () -> Void = {}
    public var isContainerPanning: () -> Bool = { false }
    public var isContainerExpanded: () -> Bool = { false }

    public var mediaPickerContext: AttachmentMediaPickerContext? {
        return nil
    }

    public var isMinimized: Bool = false

    public var isMinimizable: Bool {
        return false
    }

    public func requestMinimize(topEdgeOffset: CGFloat?, initialVelocity: CGFloat?) {
    }

    public func makeContentSnapshotView() -> UIView? {
        return nil
    }

    public init(context: AccountContext, updatedPresentationData: (initial: PresentationData, signal: Signal<PresentationData, NoError>)? = nil, useDefaultAccent: Bool = true, peer: EnginePeer, walletContext: WalletContext, resolvedAddress: WalletUserAddress? = nil, initialAddress: String = "", initialAmountNanograms: Int64? = nil, refreshBalanceOnOpen: Bool = true, allowOpenRecipientChat: Bool = true, transferAnimation: WalletSendTransferAnimation? = nil, completed: (() -> Void)? = nil) {
        super.init(navigationBarPresentationData: nil)
    }

    public init(context: AccountContext, updatedPresentationData: (initial: PresentationData, signal: Signal<PresentationData, NoError>)? = nil, useDefaultAccent: Bool = true, walletContext: WalletContext, address: String, initialAmountNanograms: Int64? = nil, refreshBalanceOnOpen: Bool = true, transferAnimation: WalletSendTransferAnimation? = nil, completed: (() -> Void)? = nil) {
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
