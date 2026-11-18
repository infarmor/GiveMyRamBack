import Foundation

public enum KnownApps {
    /// Messengers and mail clients: pausing them silences notifications, so onboarding offers
    /// to protect the ones that are installed.
    public static var messengers: [(bundleID: String, name: String)] { [
        ("ru.keepcoder.Telegram", "Telegram"),
        ("org.telegram.desktop", "Telegram Desktop"),
        ("com.tinyspeck.slackmacgap", "Slack"),
        ("com.hnc.Discord", "Discord"),
        ("net.whatsapp.WhatsApp", "WhatsApp"),
        ("desktop.WhatsApp", "WhatsApp"),
        ("org.whispersystems.signal-desktop", "Signal"),
        ("com.microsoft.teams2", "Microsoft Teams"),
        ("com.microsoft.Outlook", "Outlook"),
        ("us.zoom.xos", "Zoom"),
        ("com.viber.osx", "Viber"),
        ("com.facebook.archon", "Messenger"),
        ("com.skype.skype", "Skype"),
        ("com.apple.MobileSMS", String(localized: "Сообщения")),
        ("com.apple.mail", String(localized: "Почта")),
        ("ru.dgis.vkteams", "VK Teams"),
        ("im.riot.app", "Element")
    ] }
}
