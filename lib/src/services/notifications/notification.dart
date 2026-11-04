/*
 * A notification, as the core raises it: what happened, how loud, and where it
 * may be shown. Plain data, so the core can raise one without knowing how the
 * host shows it; the app's NotificationService renders it (tray, in-app card),
 * and the server edition logs it. Raised through CoreHost.notify.
 */

enum NotificationLevel { info, success, warning, error }

/// Where a notification should be delivered.
enum NotificationScope {
  /// In-app only (snackbar / banner). Default.
  app,

  /// System tray / OS notification only.
  system,

  /// Both in-app and system tray.
  both,
}

/// Value object describing one notification.
class XprsNotification {
  final NotificationLevel level;
  final String title;
  final String? body;

  /// Opaque identifier for where this notification came from. Used by
  /// the history / debug UI. Convention: `"wapp:<wappName>"` for
  /// wapp-sourced notifications, `"host:<service>"` for host-sourced.
  final String source;

  /// Deduplication key. Two notifications with the same tag are the SAME
  /// notification — the second one is suppressed rather than shown again. The
  /// social inbox sets it to the NOSTR event id, because that is what the
  /// notification actually IS.
  final String? tag;

  final NotificationScope scope;

  /// Conversation id inside the source wapp this notification is about
  /// (e.g. the peer pubkey for Mail, a room id for Chat). Tapping the
  /// notification — Android shade or in-app center — opens that
  /// conversation, not just the wapp's front page.
  final String? convo;

  /// A view inside the source wapp — `post:<id>`, `entry:42` — for the wapps
  /// whose tap target is not a conversation. Social's is a THREAD: a
  /// notification saying somebody replied has to open that exchange, not the
  /// feed, or the person has to go and find what they were just told about.
  /// The same string [HeroItem] hands a wapp as `initialView`.
  final String? view;

  final DateTime timestamp;

  XprsNotification({
    required this.level,
    required this.title,
    this.body,
    required this.source,
    this.tag,
    this.scope = NotificationScope.app,
    this.convo,
    this.view,
  }) : timestamp = DateTime.now();
}
