import Foundation

/// What this client offers, and what it does not offer yet.
///
/// One place, on purpose, and the twin of Offered.java on the other client -
/// the two have to hide the same things or a person moving between their own
/// phones finds a different messenger on each.
///
/// This is a fork of a client built against a server that answers everything,
/// running against a server that answers some of it. So there are buttons here
/// that would open an empty screen, or take an instruction and drop it
/// silently. A button that does nothing is worse than a button that is not
/// there: the first is a fault somebody carries around wondering about, the
/// second is simply a thing this messenger does not do yet.
///
/// Every switch below is false because something behind it is missing, and each
/// says what. Turning one back to true is the last step of restoring it, not
/// the first, and the epic (#83) holds the same list with what each one needs.
///
/// The rule: nothing is hidden anywhere in this client without a switch here.
/// A feature quietly removed and not written down is a feature nobody brings
/// back.
public enum Offered {

    /// Scheduling a message for later.
    ///
    /// Reading the scheduled list is a stub on the server and sending one has
    /// no handler at all, so the picker takes a date and nothing is ever sent
    /// or shown. Issue #26.
    public static let scheduledMessages = false

    /// Translating a message. No implementation anywhere. Issue #27.
    public static let translation = false

    /// The archive. Moving a chat there has no handler, so it slides away and
    /// comes back on the next sync. Issue #25.
    public static let archive = false

    /// Chat folders. Reading returns nothing, creating has no handler. #22.
    public static let folders = false

    /// Chat themes - colours only, the server's list - and name and profile
    /// colours, which save without Premium. #23, #24.
    public static let chatThemes = true
    public static let nameColours = true

    /// Cloud themes: whole app themes shared and made as files. The server
    /// keeps no such file. #23.
    public static let cloudThemes = false

    /// A photo of one's own behind a chat. The server keeps no wallpaper. #23.
    public static let chatWallpapers = false

    /// "Article" in the attachment menu: Telegram's rich-text composer. The
    /// server blocks messages.getRichMessage, so an article goes nowhere, and
    /// App Review counts a way into nothing as a hidden feature (2.3.1(a),
    /// 5 October; #181).
    public static let articles = false

    /// Headings, lists and tables sent as Telegram's rich message: the
    /// structure goes in messages.sendMessage and editMessage beside the
    /// ciphertext, where the server reads it (#253). Off: such text goes
    /// flattened to text with entities, inside the ciphertext - what "Send
    /// without formatting" does - and no Premium prompt is shown for it.
    public static let richMessages = false

    /// A draft synced through the server (messages.saveDraft): it put the words
    /// on the server before anybody decided to send them - here only for chats
    /// without a conversation, on Android for every chat (#264). Off: a draft
    /// stays on this phone, as the checklist says it does.
    public static let cloudDrafts = false

    /// Telegram's own secret chats ("Start Secret Chat" on a profile). The
    /// server has no messages.requestEncryption; every chat here is already
    /// end-to-end encrypted with MLS. #181.
    public static let secretChats = false

    /// The AI button in the message field and in captions. Nothing on this
    /// server answers it; the server's ios_disable_ai_chat hides it as well,
    /// and this holds even against a server that does not say so. #227.
    public static let aiEditor = false

    /// Importing a chat exported from another messenger, which the share
    /// extension offers for a WhatsApp archive. The server imports no history
    /// (messages.initHistoryImport is refused), so the file is shared as the
    /// file it is. #230.
    public static let chatImport = false

    /// Icons behind a name or profile colour. They are custom emoji from
    /// packs, and there are none (#20), so the picker opens empty. #222.
    public static let colourIcons = false

    /// Video chats. Nothing behind them. Issue #28.
    public static let videoChats = false

    /// Voice and video calls between people (#14). The server matches the two
    /// phones and hands out STUN; the media goes device to device. This
    /// switch shows the rows around calls - who may call, call data saving;
    /// the call button itself follows the server's phone_calls_available.
    /// Not #28 above, though the rows for both were once hidden by one switch.
    public static let calls = true

    /// Stories. Nothing behind them, and a private messenger for a few people
    /// is not where they belong first.
    public static let stories = false

    /// Channels and public groups. This is an invitation-only messenger for
    /// conversations between people; broadcasting is a different thing.
    public static let channels = false

    /// An avatar built out of an emoji on a coloured background.
    ///
    /// There are no emoji to build it from: account.getDefaultProfilePhotoEmojis
    /// is an empty stub and no emoji pack can be installed (#20), so the picker
    /// opens empty with a search box that finds nothing. Comes back with the
    /// packs.
    public static let emojiAvatar = false

    /// Reactions: the owner's nine emoji, one per person per message, kept by
    /// the server and told to everybody in the conversation (#18).
    public static let reactions = true

    /// Notifications for reactions. The server tells a phone of a reaction
    /// only while it is connected, and nothing wakes one for it, so a switch
    /// here would promise a notification that never comes.
    public static let reactionNotifications = false

    /// Sticker packs. messages.getAllStickers is answered with an empty list
    /// and installing one has no handler (#20), so every list of packs opens
    /// empty - MY STICKERS was a heading over a footer pointing at a bot that
    /// does not exist here. The emoji and animation settings on the same screen
    /// work and stay.
    public static let stickerPacks = false

    /// The sticker and GIF tabs of the emoji panel, and stickers suggested for
    /// an emoji as it is typed. Every list of them is answered empty, so the
    /// tabs held only what this phone had saved, and each emoji typed asked the
    /// server for stickers to match it. Issue #258.
    public static let stickersAndGifs = false

    /// Sharing a live location. It is a stream of edits the server applies to
    /// a location it can read; in a chat that encrypts it would have to be a
    /// stream of ciphertexts nothing here builds yet. A location sent once
    /// travels encrypted (the step after #258). Issue #258.
    public static let liveLocation = false

    /// Polls and to-do lists. A poll is a count the server keeps, and this
    /// server keeps none: a poll arrived as an unsupported message, after its
    /// question and answers had reached the server. Issues #20, #21, #258.
    public static let polls = false

    /// A lone dice or dart emoji sent as a throw. The server rolls it, so it
    /// has to read it; the emoji goes as the word it is, as it does in
    /// Telegram's secret chats. Issue #258.
    public static let dice = false

    /// A cloud password - the second step asked for when signing in.
    ///
    /// account.getPassword is answered with "there is no password" and nothing
    /// handles setting one, so the screen would take a password, send it, and
    /// leave the account exactly as open as it was. Worse than absent: it reads
    /// as a lock that is on.
    public static let cloudPassword = false

    /// An address to receive login codes at. account.sendVerifyEmailCode is
    /// not implemented, so the screen would take an address and never confirm
    /// it. Android already hides the row unless the account has one.
    public static let loginEmail = false

    /// Gifts. The catalogue is answered with an empty list and nothing can be
    /// bought or sent, so a setting for who may send you one governs nothing.
    public static let gifts = false

    /// Bots and the mini apps that run inside them.
    ///
    /// Not a stub but an absence: the server has no bots service, and not one
    /// bots.* handler exists, so no account can be a bot and there is nothing
    /// for a search over apps to find. The client already knew - its .apps
    /// search returns an empty list without sending a request - and the tab
    /// stayed anyway. Issue #105.
    public static let bots = false

    /// A group's invite link: the row in the add-member picker, the "Invite
    /// Links" row of group info, the screen that sends the raw link to members
    /// the server refused, and the QR behind them.
    ///
    /// Not missing on the server - the link is minted and resolves - but it is
    /// not how anybody gets in here. An invitation is an SMS with a code bound
    /// to a number (#47), so the link is useless to somebody not on ice9; and
    /// the app drops it without a word for somebody signed out. Whoever is
    /// signed in did not need it: any member adds them from contacts. What it
    /// would do is admit anyone holding the hash. Issue #163.
    public static let groupInviteLinks = false

    /// Linking a desktop or web client by QR: the button and the text above
    /// the device list, and the settings-search entry for it. The server half
    /// works (app/bff/qrcode), but there is no ice9 Desktop and no ice9 Web to
    /// sign in, so the door opens on nothing. Issue #107.
    public static let desktop = false

    /// Help: Support, the FAQ, Telegram's features ("Tips") and the privacy
    /// policy - the block in Settings and their settings-search entries (#197).
    ///
    /// Support reaches help.getSupport, which the server refuses outright; the
    /// FAQ and the features led to Telegram's site and channel; the policy
    /// opened telegram.org through the language pack our own server served.
    /// Hidden until there is a page of ours worth opening from inside the app;
    /// the stores are given the address directly.
    public static let help = false

    /// The TON wallet Telegram 13.0 ships: a balance, transfers in chats, TON
    /// Connect. The server offers no TON, and Apple refused 12.9.2 for payment
    /// code it could read in the binary (#181), so the wallet's context and its
    /// screens compile ice9's stubs (#278) and nothing links the Rust engine.
    /// Coming back means a server with TON behind it and a decision about
    /// payments on the App Store, in that order.
    public static let wallet = false

    /// A person's own notification sounds: "Upload Sound" on the sound screen,
    /// "Save for Notifications" on an audio message. The server takes no
    /// uploads (teamgram's licence); the three tones it hands out (Ice9Tones)
    /// are everybody's and nobody's to delete (#282).
    public static let uploadedSounds = false

    /// Saved Messages, the chat with oneself. The server keeps nothing
    /// readable in it (#271): it takes only the ciphertext of a conversation
    /// between this account's own devices (#284), kept like any other.
    public static let savedMessages = true

    // A round video in a conversation that encrypts used to be switched off
    // here: the one message uploaded while it was still being recorded, which
    // an encrypted upload cannot take. It is offered again since #80 - the
    // live upload is given up in ChatControllerMediaRecording where a secret
    // chat already gives it up, and the finished file goes up whole and
    // encrypted like any other video. Kept as a note rather than a switch,
    // so the next person looking for the row finds where it went.
}
