import Foundation
import UIKit
import Display
import AsyncDisplayKit
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import ProgressNavigationButtonNode

/// The wording for the server-choice screen.
///
/// Ours rather than upstream's, and the app ships two languages, so they are
/// written here instead of going through the generated string table - adding a
/// key there means regenerating a table built from Telegram's own translations,
/// which is a poor trade for five sentences. The same reasoning, and the same
/// shape, as the recovery phrase screen next door.
func serverChoiceIsRussian(_ strings: PresentationStrings) -> Bool {
    return strings.baseLanguageCode.hasPrefix("ru")
}

func serverChoiceTitle(_ strings: PresentationStrings) -> String {
    return serverChoiceIsRussian(strings) ? "Какой сервер" : "Which server"
}

func serverChoiceNotice(_ strings: PresentationStrings) -> String {
    return serverChoiceIsRussian(strings)
        ? "Приложение говорит с одним сервером, и вы выбираете, с каким. Наш уже вписан — оставьте его или впишите свой: IP-адрес или имя."
        : "This app talks to one server, and you choose which. Ours is filled in - keep it, or put in your own: an IP address or a name."
}

/// An IP is as good an answer as a name, and the field has to say so: somebody
/// who has just put a server on a machine has its address long before it has a
/// name, and a hint that only shows a name reads as a refusal to take one.
func serverChoicePlaceholder(_ strings: PresentationStrings) -> String {
    return serverChoiceIsRussian(strings) ? "адрес или имя:порт" : "address or name:port"
}

/// Where the instructions for putting one up live. On the site because that is
/// the public place we have - the repository is private, so there is no other
/// link to give.
let serverChoiceInstructions = "https://ice9.app/server"

func serverChoiceOwnServer(_ strings: PresentationStrings) -> String {
    return serverChoiceIsRussian(strings)
        ? "Важно! Свой сервер поднимается за 5–10 минут по инструкции. Это просто — попробуйте."
        : "Important: your own server goes up in 5-10 minutes, and here is how. It is easy - try it."
}

func serverChoiceUseDefault(_ strings: PresentationStrings) -> String {
    return serverChoiceIsRussian(strings) ? "Сервер по умолчанию" : "Use default"
}

func serverChoiceMalformed(_ strings: PresentationStrings) -> String {
    return serverChoiceIsRussian(strings)
        ? "Это не адрес. Имя или IP, и порт через двоеточие, если он не обычный."
        : "That is not an address. A name or an IP, and a port after a colon if it is not the usual one."
}

func serverChoiceSilent(_ strings: PresentationStrings) -> String {
    return serverChoiceIsRussian(strings)
        ? "По этому адресу никто не ответил."
        : "Nothing answered at that address."
}

/// How long to wait before calling silence an answer. A wrong address does not
/// refuse - it says nothing at all - so somebody has to decide when to stop
/// waiting. Longer than any handshake we have measured, short enough to be an
/// answer rather than a spinner.
private let serverChoiceTimeout: Double = 15.0

/// Which server this phone talks to, asked once and before anything else.
///
/// It stands after the splash and before the phone number: the code that signs
/// somebody in comes from the server, so the question cannot wait until after
/// it. Not asked on a later sign-in and not when a second account is added -
/// those happen against the server already chosen.
///
/// An address is kept only after it has answered a real handshake. An address
/// stored without that is a person carrying an app that connects to nothing and
/// cannot be told why, and from inside the app there is no way back to this
/// screen.
final class AuthorizationSequenceServerController: ViewController {
    private var controllerNode: AuthorizationSequenceServerControllerNode {
        return self.displayNode as! AuthorizationSequenceServerControllerNode
    }

    private let strings: PresentationStrings
    private let theme: PresentationTheme
    private let network: Network
    private let store: ServerAddressStore
    private let openUrl: (String) -> Void

    /// Somebody named a server and it answered. The address is already kept and
    /// the client is already pointed at it.
    var completed: (() -> Void)?

    private let checkDisposable = MetaDisposable()
    private let hapticFeedback = HapticFeedback()

    /// What the check was interrupting, kept for as long as the check runs so
    /// that giving up can put it back.
    private var checkingFrom: ServerAddress?

    private var inProgress: Bool = false {
        didSet {
            if self.inProgress {
                self.navigationItem.rightBarButtonItem = UIBarButtonItem(customDisplayNode: ProgressNavigationButtonNode(color: self.theme.rootController.navigationBar.accentTextColor))
                // Fifteen seconds is a long time to be sure you have made a
                // mistake and be unable to say so. There is no back button on
                // this screen, so the left side is free for the one thing
                // somebody might want while it spins.
                self.navigationItem.leftBarButtonItem = UIBarButtonItem(title: self.strings.Common_Cancel, style: .plain, target: self, action: #selector(self.cancelPressed))
            } else {
                self.navigationItem.rightBarButtonItem = UIBarButtonItem(title: self.strings.Common_Next, style: .done, target: self, action: #selector(self.nextPressed))
                self.navigationItem.leftBarButtonItem = nil
            }
            self.controllerNode.inProgress = self.inProgress
        }
    }

    init(strings: PresentationStrings, theme: PresentationTheme, network: Network, store: ServerAddressStore, openUrl: @escaping (String) -> Void) {
        self.strings = strings
        self.theme = theme
        self.network = network
        self.store = store
        self.openUrl = openUrl

        super.init(navigationBarPresentationData: NavigationBarPresentationData(theme: AuthorizationSequenceController.navigationBarTheme(theme), strings: NavigationBarStrings(presentationStrings: strings)))

        self.supportedOrientations = ViewControllerSupportedOrientations(regularSize: .all, compactSize: .portrait)

        self.hasActiveInput = true

        self.statusBar.statusBarStyle = theme.intro.statusBarStyle.style

        // Nothing can happen until this is answered, so there is nowhere behind
        // it to go.
        self.attemptNavigation = { _ in
            return false
        }

        self.navigationItem.rightBarButtonItem = UIBarButtonItem(title: self.strings.Common_Next, style: .done, target: self, action: #selector(self.nextPressed))
    }

    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        self.checkDisposable.dispose()
    }

    override func loadDisplayNode() {
        self.displayNode = AuthorizationSequenceServerControllerNode(strings: self.strings, theme: self.theme, address: self.store.effective)
        self.displayNodeDidLoad()

        self.controllerNode.enterAddress = { [weak self] address in
            self?.submit(address)
        }
        self.controllerNode.openInstructions = { [weak self] in
            self?.openUrl(serverChoiceInstructions)
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        self.controllerNode.activateInput()
    }

    override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)

        self.controllerNode.containerLayoutUpdated(layout, navigationBarHeight: self.navigationBar?.frame.maxY ?? 0.0, transition: transition)
    }

    @objc private func nextPressed() {
        self.submit(self.controllerNode.currentAddress)
    }

    private func submit(_ typed: String) {
        if self.inProgress {
            return
        }
        guard let address = ServerAddress.parse(typed) else {
            self.refuse(serverChoiceMalformed(self.strings))
            return
        }

        let previous = self.store.effective
        self.view.endEditing(true)
        self.inProgress = true

        // Try it before keeping it. Pointing the client at it costs nothing to
        // undo here - nobody has signed in yet, so there is no history keyed to
        // a server - and it is the only way to ask the question that matters,
        // which is whether a server of ours is there.
        //
        // Unless it is where the client is already pointed, which is the common
        // case: the field is filled in with ours and the answer is one tap.
        // Reseeding then would throw away a key that was just agreed with this
        // very server and make somebody wait through a second handshake to be
        // told what the client already knew.
        let moved = address != previous
        if moved {
            reseedFromAddress(network: self.network, address: address)
            self.checkingFrom = previous
        } else {
            self.checkingFrom = nil
        }

        self.checkDisposable.set((askWhetherServerAnswers(network: self.network, timeout: serverChoiceTimeout)
        |> deliverOnMainQueue).startStrict(next: { [weak self] answer in
            guard let self else {
                return
            }
            self.inProgress = false
            self.checkingFrom = nil
            switch answer {
            case .answered:
                self.controllerNode.showError(nil)
                self.store.store(address)
                self.completed?()
            case let .refused(text):
                self.putBack(previous, ifMoved: moved, saying: text)
            case .silent:
                self.putBack(previous, ifMoved: moved, saying: serverChoiceSilent(self.strings))
            }
        }))
    }

    /// Stops waiting. The address goes back to what it was and the screen says
    /// nothing about it: somebody who changed their mind has not been refused,
    /// and a complaint in front of them would read as one.
    @objc private func cancelPressed() {
        guard self.inProgress else {
            return
        }
        self.checkDisposable.set(nil)
        self.inProgress = false
        if let from = self.checkingFrom {
            reseedFromAddress(network: self.network, address: from)
        }
        self.checkingFrom = nil
        self.controllerNode.showError(nil)
        self.controllerNode.activateInput()
    }

    /// Puts back the address that was there, so that a phone left standing on
    /// this screen is still pointing at something real. Nothing to put back when
    /// nothing moved - and reseeding onto the address the client is already
    /// using would throw away a working key to no purpose.
    private func putBack(_ address: ServerAddress, ifMoved moved: Bool, saying complaint: String) {
        if moved {
            reseedFromAddress(network: self.network, address: address)
        }
        self.refuse(complaint)
    }

    private func refuse(_ complaint: String) {
        self.hapticFeedback.error()
        self.controllerNode.showError(complaint)
        self.controllerNode.animateError()
    }
}
