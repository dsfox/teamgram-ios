import Foundation
import UIKit
import Display
import AsyncDisplayKit
import SwiftSignalKit
import TelegramCore
import MessageUI
import TelegramPresentationData
import AccountContext
import ShareController
import AlertUI
import PresentationDataUtils
import SearchUI

public class InviteContactsController: ViewController, MFMessageComposeViewControllerDelegate, UINavigationControllerDelegate {
    private let context: AccountContext
    
    private var contactsNode: InviteContactsControllerNode {
        return self.displayNode as! InviteContactsControllerNode
    }
    
    private var _ready = Promise<Bool>()
    override public var ready: Promise<Bool> {
        return self._ready
    }
    
    private var presentationData: PresentationData
    private var presentationDataDisposable: Disposable?
    
    private var composer: MFMessageComposeViewController?
    private let mintDisposable = MetaDisposable()
    
    private var searchContentNode: NavigationBarSearchContentNode?
    
    public init(context: AccountContext) {
        self.context = context
        
        self.presentationData = context.sharedContext.currentPresentationData.with { $0 }
        
        super.init(navigationBarPresentationData: NavigationBarPresentationData(presentationData: self.presentationData, style: .glass))
        
        self._hasGlassStyle = true
        self.navigationPresentation = .modal
        
        self.statusBar.statusBarStyle = self.presentationData.theme.rootController.statusBarStyle.style
        
        self.title = self.presentationData.strings.Contacts_InviteFriends
        
        self.navigationItem.backBarButtonItem = UIBarButtonItem(title: self.presentationData.strings.Common_Back, style: .plain, target: nil, action: nil)
        
        self.scrollToTop = { [weak self] in
            if let strongSelf = self {
                if let searchContentNode = strongSelf.searchContentNode {
                    searchContentNode.updateExpansionProgress(1.0, animated: true)
                }
                strongSelf.contactsNode.scrollToTop()
            }
        }
        
        self.presentationDataDisposable = (context.sharedContext.presentationData
        |> deliverOnMainQueue).start(next: { [weak self] presentationData in
            if let strongSelf = self {
                let previousTheme = strongSelf.presentationData.theme
                let previousStrings = strongSelf.presentationData.strings
                
                strongSelf.presentationData = presentationData
                
                if previousTheme !== presentationData.theme || previousStrings !== presentationData.strings {
                    strongSelf.updateThemeAndStrings()
                }
            }
        }).strict()
        
        self.searchContentNode = NavigationBarSearchContentNode(theme: self.presentationData.theme, placeholder: self.presentationData.strings.Common_Search, activate: { [weak self] in
            self?.activateSearch()
        })
        self.searchContentNode?.setIsEnabled(false)
        self.navigationBar?.setContentNode(self.searchContentNode, animated: false)
    }
    
    required public init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    deinit {
        self.presentationDataDisposable?.dispose()
        self.mintDisposable.dispose()
    }
    
    private func updateThemeAndStrings() {
        self.statusBar.statusBarStyle = self.presentationData.theme.rootController.statusBarStyle.style
        self.navigationBar?.updatePresentationData(NavigationBarPresentationData(presentationData: self.presentationData, style: .glass), transition: .immediate)
        self.searchContentNode?.updateThemeAndPlaceholder(theme: self.presentationData.theme, placeholder: self.presentationData.strings.Common_Search)
        self.title = self.presentationData.strings.Contacts_InviteFriends
        self.navigationItem.backBarButtonItem = UIBarButtonItem(title: self.presentationData.strings.Common_Back, style: .plain, target: nil, action: nil)
    }
    
    override public func loadDisplayNode() {
        self.displayNode = InviteContactsControllerNode(context: self.context)
        self._ready.set(self.contactsNode.ready)
        
        self.contactsNode.navigationBar = self.navigationBar
        
        self.contactsNode.loadedContacts = { [weak self] in
            self?.searchContentNode?.setIsEnabled(true)
        }
        
        self.contactsNode.requestDeactivateSearch = { [weak self] in
            self?.deactivateSearch()
        }
        
        self.contactsNode.requestActivateSearch = { [weak self] in
            self?.activateSearch()
        }
        
        self.contactsNode.requestShareTelegram = { [weak self] in
            if let strongSelf = self {
                let url = strongSelf.presentationData.strings.InviteText_URL
                let body = strongSelf.presentationData.strings.InviteText_SingleContact(url).string
                presentExternalShare(context: strongSelf.context, text: body, parentController: strongSelf)
                
                strongSelf.contactsNode.listNode.clearHighlightAnimated(true)
            }
        }
        
        self.contactsNode.requestShare = { [weak self] numbers in
            guard let strongSelf = self, let first = numbers.first, let phone = first.0.phoneNumbers.first?.value else {
                return
            }
            // The code is bound to this number on the server (#47): only the
            // phone the carrier delivers the SMS to can sign in with it.
            strongSelf.mintDisposable.set((strongSelf.context.engine.contacts.mintInvitation(phone: phone)
            |> deliverOnMainQueue).start(next: { code in
                guard let strongSelf = self, MFMessageComposeViewController.canSendText() else {
                    return
                }
                let strings = strongSelf.presentationData.strings
                let composer = MFMessageComposeViewController()
                composer.messageComposeDelegate = strongSelf
                composer.recipients = [phone]
                composer.body = strings.InviteText_SingleContact(strings.InviteText_URL).string + "\n" + strings.Invite_CodeLine(code).string
                strongSelf.composer = composer
                if let window = strongSelf.view.window {
                    window.rootViewController?.present(composer, animated: true)
                }
            }, error: { error in
                guard let strongSelf = self else {
                    return
                }
                // Said, not swallowed: an SMS without a code is useless.
                let strings = strongSelf.presentationData.strings
                let text: String
                switch error {
                case .alreadyHere:
                    text = strings.Invite_AlreadyHere
                case .generic:
                    text = strings.Invite_NoCode
                }
                strongSelf.present(textAlertController(context: strongSelf.context, title: nil, text: text, actions: [TextAlertAction(type: .defaultAction, title: strings.Common_OK, action: {})]), in: .window(.root))
            }))
        }
        
        self.contactsNode.listNode.visibleContentOffsetChanged = { [weak self] offset, _ in
            if let strongSelf = self, let searchContentNode = strongSelf.searchContentNode {
                searchContentNode.updateListVisibleContentOffset(offset)
            }
        }
        
        self.contactsNode.listNode.didEndScrolling = { [weak self] _ in
            if let strongSelf = self, let searchContentNode = strongSelf.searchContentNode {
                let _ = fixNavigationSearchableListNodeScrolling(strongSelf.contactsNode.listNode, searchNode: searchContentNode)
            }
        }
        
        self.displayNodeDidLoad()
    }
    
    override public func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
    }
    
    override public func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
    }
    
    override public func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        
        self.contactsNode.containerLayoutUpdated(layout, navigationBarHeight: self.cleanNavigationHeight, actualNavigationBarHeight: self.navigationLayout(layout: layout).navigationFrame.maxY, transition: transition)
    }
    
    private func activateSearch() {
        if self.displayNavigationBar {
            if let scrollToTop = self.scrollToTop {
                scrollToTop()
            }
            if let searchContentNode = self.searchContentNode {
                self.contactsNode.activateSearch(placeholderNode: searchContentNode.placeholderNode)
            }
            self.setDisplayNavigationBar(false, transition: .animated(duration: 0.5, curve: .spring))
        }
    }
    
    private func deactivateSearch() {
        if !self.displayNavigationBar {
            self.setDisplayNavigationBar(true, transition: .animated(duration: 0.5, curve: .spring))
            if let searchContentNode = self.searchContentNode {
                self.contactsNode.deactivateSearch(placeholderNode: searchContentNode.placeholderNode)
            }
        }
    }
    
    @objc public func messageComposeViewController(_ controller: MFMessageComposeViewController, didFinishWith result: MessageComposeResult) {
        self.composer = nil
        
        controller.dismiss(animated: true, completion: nil)
        
        guard case .sent = result else {
            return
        }
        
        self.contactsNode.selectionState = self.contactsNode.selectionState.withClearedSelection()
    }
}
