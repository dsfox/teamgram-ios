import Foundation
import TelegramCore

/// What settings search may find (#91, #197).
///
/// Settings search is a second copy of the whole settings tree: a flat list of
/// every destination in settings, built by a dozen functions of upstream's in
/// SettingsSearchableItems.swift. The sweeps of #91 took the switched-off rows
/// out of the screens that draw them, and the list went on offering every one
/// of them - typing "calls" found seven settings for calls nobody could place;
/// "channels", "stories", "gifts" and the cloud password were all one search
/// away from screens that no longer show them.
///
/// So the list passes through `offeredSearchItems` once, and this file decides:
/// single ids, which are stable across carries where the code around them is
/// not, and whole groups by the first part of their ids, so that an entry
/// upstream adds to premium tomorrow is hidden with the rest. Each says what is
/// missing, in the same words as Offered. tests/test_settings_doors.py checks
/// that every id and group here is still built upstream.

private let notOfferedSearchItems: [String: String] = {
    var table = alwaysNotOfferedSearchItems
    // Calls follow their switch (#14): the rows come back on the screens with
    // Offered.calls, and search has to find them the same day.
    if !Offered.calls {
        table.merge(callSearchItemsWhileCallsAreOff) { current, _ in current }
    }
    // Reactions are offered (#18); notifications for them are not.
    if !Offered.reactionNotifications {
        table.merge(reactionNotificationSearchItemsWhileOff) { current, _ in current }
    }
    if !Offered.nameColours {
        table.merge(nameColourSearchItemsWhileOff) { current, _ in current }
    }
    if !Offered.cloudThemes {
        table.merge(cloudThemeSearchItemsWhileOff) { current, _ in current }
    }
    if !Offered.colourIcons {
        table.merge(colourIconSearchItemsWhileOff) { current, _ in current }
    }
    // The settings row is hidden with the chat itself (#284).
    if !Offered.savedMessages {
        table["saved-messages"] = "#284"
    }
    return table
}()

private let colourIconSearchItemsWhileOff: [String: String] = [
    "profile-color/profile/add-icons": "#222", "profile-color/name/add-icons": "#222",
]

private let nameColourSearchItemsWhileOff: [String: String] = [
    "edit/your-color": "#24", "profile-color": "#24",
    "profile-color/profile": "#24", "profile-color/name": "#24",
]

private let cloudThemeSearchItemsWhileOff: [String: String] = [
    "appearance/themes": "#23", "appearance/themes/edit": "#23",
    "appearance/themes/create": "#23",
]

private let reactionNotificationSearchItemsWhileOff: [String: String] = [
    "notifications/reactions": "#18", "notifications/reactions/messages": "#18",
    "notifications/reactions/stories": "#18",
    "notifications/reactions/show-sender": "#18",
    "notifications/reactions/sound": "#18",
]

private let callSearchItemsWhileCallsAreOff: [String: String] = [
    "privacy/calls": "#14", "privacy/calls/never": "#14",
    "privacy/calls/always": "#14", "privacy/calls/p2p": "#14",
    "privacy/calls/p2p/never": "#14", "privacy/calls/p2p/always": "#14",
    "privacy/calls/ios-integration": "#14",
    "data/less-data-calls": "#14", "data/proxy/use-for-calls": "#14",
]

private let alwaysNotOfferedSearchItems: [String: String] = [
    // A desktop to link by QR: there is none. #107.
    "devices/link-desktop": "#107",

    // Channels: none of it is built, here or on the server. #16.
    "edit/channel": "#16",
    "notifications/channels": "#16", "notifications/channels/edit": "#16",
    "notifications/channels/show": "#16", "notifications/channels/preview": "#16",
    "notifications/channels/sound": "#16",
    "notifications/channels/add-exception": "#16",
    "notifications/channels/delete-exceptions": "#16",
    "notifications/include-channels": "#16",
    "data/save-to-photos/channels": "#16",
    "data/save-to-photos/channels/max-video-size": "#16",
    "data/save-to-photos/channels/add-exception": "#16",
    "data/save-to-photos/channels/delete-all": "#16",

    // Stories: nothing behind them. #17.
    "my-profile/posts": "#17", "my-profile/posts/all-stories": "#17",
    "my-profile/posts/add-album": "#17", "my-profile/archived-posts": "#17",
    "notifications/stories": "#17", "notifications/stories/new": "#17",
    "notifications/stories/important": "#17",
    "notifications/stories/show-sender": "#17",
    "notifications/stories/sound": "#17",
    "notifications/stories/add-exception": "#17",
    "notifications/stories/delete-exceptions": "#17",
    "data/auto-download/mobile/stories": "#17",
    "data/auto-download/wifi/stories": "#17",

    // Sticker packs: every list of them opens empty. #20.
    "appearance/stickers-and-emoji/trending": "#20",
    "appearance/stickers-and-emoji/archived": "#20",
    "appearance/stickers-and-emoji/archived/edit": "#20",
    "appearance/stickers-and-emoji/emoji/archived": "#20",
    "appearance/stickers-and-emoji/emoji/archived/edit": "#20",

    // The archive: moving a chat there has no handler. #25.
    "privacy/archive-and-mute": "#25",

    // Translation: no implementation anywhere. #27.
    "language/show-button": "#27", "language/translate-chats": "#27",
    "language/do-not-translate": "#27",

    // A gift colour comes from gifts, which are not offered. The colours
    // themselves are (#24).
    "profile-color/profile/use-gift": "gifts", "profile-color/name/use-gift": "gifts",

    // Gifts: the catalogue is empty and nothing can be bought or sent.
    "my-profile/gifts": "gifts", "privacy/gifts": "gifts",
    "privacy/gifts/show-icon": "gifts", "privacy/gifts/never": "gifts",
    "privacy/gifts/always": "gifts", "privacy/gifts/accepted-types": "gifts",

    // A cloud password the server never stores: account.getPassword always
    // answers "no password" and nothing handles setting one.
    "privacy/2sv": "cloud password", "privacy/2sv/change": "cloud password",
    "privacy/2sv/disable": "cloud password",
    "privacy/2sv/change-email": "cloud password",

    // Passkeys: all six handlers on the server are blocked.
    "privacy/passkey": "passkeys", "privacy/passkey/create": "passkeys",

    // An address to receive login codes at: account.sendVerifyEmailCode is not
    // implemented, so it would be taken and never confirmed.
    "privacy/login-email": "login email",

    // Bots and the websites they log you into: there is no bots service on the
    // server, not one bots.* handler, and no payments service either. #105.
    "privacy/active-websites": "#105",
    "privacy/active-websites/edit": "#105",
    "privacy/active-websites/disconnect-all": "#105",
    "privacy/data-settings/bot-settings": "#105",
    "privacy/data-settings/clear-payment-info": "#105",

]

/// Whole groups, by the first part of an id ("premium/no-ads" is in "premium").
private let notOfferedSearchGroups: [String: String] = {
    // Premium, and everything sold through it - business, stars, TON, sending
    // a gift. Four of the five handlers behind it on the server are blocked
    // and nothing can be bought, so every entry opened a shop with no counter.
    var groups: [String: String] = [
        "premium": "premium", "business": "premium", "stars": "premium",
        "ton": "premium", "send-gift": "premium",
    ]
    // Reading folders answers with an empty list and creating one has no
    // handler at all. #22.
    if !Offered.folders {
        groups["folders"] = "#22"
    }
    // Support, the FAQ, Telegram's features and the privacy policy: the rows
    // are hidden, and search found every one of them. #197.
    if !Offered.help {
        for id in ["ask-question", "faq", "features", "privacy-policy"] {
            groups[id] = "help"
        }
    }
    return groups
}()

/// Upstream's list without what this fork does not offer.
///
/// An id upstream renames is a door open again with nothing complaining, and
/// tests/test_settings_doors.py is what complains: it reads every id here
/// against upstream's file. Not this function - which ids a screen builds
/// depends on its state (linking a desktop needs the sessions, the two-step
/// rows a password), and a trap here on an id not built took every debug
/// build down the moment settings search opened (#197).
func offeredSearchItems(_ items: [SettingsSearchableItem]) -> [SettingsSearchableItem] {
    return items.filter { item in
        guard let id = item.id.base as? String else {
            return true
        }
        let group = id.split(separator: "/", maxSplits: 1).first.map(String.init) ?? id
        return notOfferedSearchItems[id] == nil && notOfferedSearchGroups[group] == nil
    }
}
