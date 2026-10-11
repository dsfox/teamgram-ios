import UIKit
import AsyncDisplayKit
import Display
import SwiftSignalKit
import TelegramCore
import ContextUI
import QuickShareScreen

extension ChatControllerImpl {
    func displayQuickShare(id: EngineMessage.Id, node: ASDisplayNode, gesture: ContextGesture) {
        let controller = QuickShareScreen(
            context: self.context,
            sourceNode: node,
            gesture: gesture,
            completion: { [weak self] peer, sourceFrame in
                guard let self else {
                    return
                }
                self.window?.forEachController({ controller in
                    if let controller = controller as? QuickShareToastScreen {
                        controller.dismissWithCommitAction()
                    }
                })
                let toastScreen = QuickShareToastScreen(
                    context: self.context,
                    peer: peer,
                    sourceFrame: sourceFrame,
                    action: { [weak self] action in
                        guard let self else {
                            return
                        }
                        switch action {
                        case .info:
                            self.openPeer(peer: peer, navigation: .chat(textInputState: nil, subject: nil, peekData: nil), fromMessage: nil)
                        case .commit:
                            // ice9: forwarded through enqueueMessages, so it is encrypted (#232)
                            let _ = enqueueMessages(account: self.context.account, peerId: peer.id, messages: [.forward(source: id, threadId: nil, grouping: .auto, attributes: [], correlationId: nil)]).startStandalone()
                        }
                    }
                )
                self.present(toastScreen, in: .window(.root))
            }
        )
        self.presentInGlobalOverlay(controller)
    }
}
