import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'api_service.dart';

// Канал уведомлений с кастомным звуком (income_msg лежит в res/raw/income_msg.mp3).
// На Android 8+ звук задаётся именно на канале, поэтому он применяется и к
// системным уведомлениям FCM (notification-блок с channel_id), и к локальным.
const String kChannelId = 'oshino_messages';
const String _channelName = 'Сообщения';
const String _channelDesc = 'Входящие сообщения и звонки Oshino';

final FlutterLocalNotificationsPlugin _localNotif =
    FlutterLocalNotificationsPlugin();

/// Фоновый обработчик FCM. Должен быть top-level функцией с аннотацией
/// vm:entry-point, т.к. вызывается в отдельном изоляте, когда приложение в фоне
/// или закрыто. При notification+data сообщении систему показывает Android сам
/// (через указанный канал) — здесь логика не требуется, но обработчик обязателен,
/// чтобы доставлялась data-нагрузка.
@pragma('vm:entry-point')
Future<void> firebaseBackgroundHandler(RemoteMessage message) async {
  debugPrint(
      '[push-bg] получено: from=${message.data['sender']} title=${message.notification?.title} data=${message.data}');
}

class PushService {
  PushService._();
  static final PushService instance = PushService._();

  bool _inited = false;

  /// Инициализация: канал, локальные уведомления, разрешение, foreground-листенер.
  /// Вызывать один раз в main() после Firebase.initializeApp().
  Future<void> init() async {
    if (_inited) return;
    _inited = true;
    if (!Platform.isAndroid) return; // пока пуш только для Android

    const channel = AndroidNotificationChannel(
      kChannelId,
      _channelName,
      description: _channelDesc,
      importance: Importance.high,
      sound: RawResourceAndroidNotificationSound('income_msg'),
      playSound: true,
    );

    final androidImpl = _localNotif.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await androidImpl?.createNotificationChannel(channel);

    await _localNotif.initialize(
      const InitializationSettings(
        android: AndroidInitializationSettings('ic_stat_oshino'),
      ),
    );

    // Разрешение на уведомления (Android 13+ POST_NOTIFICATIONS).
    final settings = await FirebaseMessaging.instance.requestPermission();
    debugPrint('[push] permission: ${settings.authorizationStatus}');
    final granted =
        await androidImpl?.requestNotificationsPermission();
    debugPrint('[push] android notif permission granted: $granted');

    // Foreground: FCM не показывает уведомление автоматически — показываем сами.
    FirebaseMessaging.onMessage.listen((m) {
      debugPrint(
          '[push] onMessage (foreground): from=${m.data['sender']} title=${m.notification?.title}');
      _showForeground(m);
    });

    // Сервер мог сменить токен — отправляем обновлённый.
    FirebaseMessaging.instance.onTokenRefresh.listen((t) {
      if (t.isNotEmpty) ApiService.fcmSubscribe(t);
    });
  }

  /// Получить текущий токен и зарегистрировать его на сервере.
  /// Вызывать после успешного входа / при восстановлении сессии.
  Future<void> registerToken() async {
    if (!Platform.isAndroid) return;
    try {
      final t = await FirebaseMessaging.instance.getToken();
      if (t == null || t.isEmpty) {
        debugPrint('[push] getToken вернул NULL/пусто');
        return;
      }
      final head = t.substring(0, t.length > 16 ? 16 : t.length);
      debugPrint('[push] getToken OK: $head... (len=${t.length})');
      final ok = await ApiService.fcmSubscribe(t);
      debugPrint('[push] fcmSubscribe результат: $ok');
    } catch (e) {
      debugPrint('[push] registerToken ошибка: $e');
    }
  }

  /// Снять регистрацию (явный выход): удалить токен на сервере и локально.
  /// Важно вызывать ДО ApiService.logout(), пока кука сессии ещё валидна.
  Future<void> unregisterToken() async {
    if (!Platform.isAndroid) return;
    try {
      final t = await FirebaseMessaging.instance.getToken();
      if (t != null && t.isNotEmpty) {
        await ApiService.fcmUnsubscribe(t);
      }
      await FirebaseMessaging.instance.deleteToken();
    } catch (_) {}
  }

  void _showForeground(RemoteMessage m) {
    final n = m.notification;
    final title =
        n?.title ?? m.data['title'] ?? m.data['sender'] ?? 'Oshino';
    final body = n?.body ?? m.data['body'] ?? 'Новое сообщение';
    _localNotif.show(
      DateTime.now().millisecondsSinceEpoch.remainder(100000),
      title,
      body,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          kChannelId,
          _channelName,
          channelDescription: _channelDesc,
          importance: Importance.high,
          priority: Priority.high,
          icon: 'ic_stat_oshino',
          sound: RawResourceAndroidNotificationSound('income_msg'),
        ),
      ),
    );
  }
}
