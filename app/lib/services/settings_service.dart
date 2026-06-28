import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'api_service.dart';
import 'ws_service.dart';

/// Глобальное хранилище пользовательских настроек.
///
/// • [defaultReaction] — эмодзи, проставляемый двойным тапом по сообщению.
///   Хранится на сервере (/settings), локально кэшируется для мгновенного
///   доступа из экрана чата.
/// • [bgAnim] — включена ли анимация фона. Чисто клиентская настройка,
///   персистится в JSON-файл через path_provider (аналог localStorage в вебе).
///
/// Доступ — через [SettingsService.instance]. Значения реактивны
/// (ValueNotifier), поэтому UI и фон обновляются мгновенно при изменении.
class SettingsService {
  SettingsService._();
  static final SettingsService instance = SettingsService._();

  /// Набор эмодзи для выбора реакции по умолчанию — 1:1 с веб-версией.
  static const List<String> emojiSet = [
    '👍', '👎', '❤️', '😂', '😮', '😢', '😡', '🔥', '🎉', '👏',
    '🙏', '💯', '✅', '❌', '🤔', '😍', '😎', '🥳', '😱', '🙌',
  ];

  /// Текущая реакция по умолчанию (двойной тап). Дефолт — как в вебе.
  final ValueNotifier<String> defaultReaction = ValueNotifier<String>('👍');

  /// Включена ли анимация фона.
  final ValueNotifier<bool> bgAnim = ValueNotifier<bool>(true);

  bool _localLoaded = false;

  /// Текущий пользователь — администратор? (логин == "admin", как в вебе).
  bool get isAdmin =>
      WsService.instance.currentLogin.toLowerCase() == 'admin';

  // ── Локальные настройки (без сети) ─────────────────────────────────────────

  /// Загружает клиентские настройки из файла. Вызывать в main() до runApp,
  /// чтобы фон сразу отрисовался в нужном состоянии без мигания.
  Future<void> loadLocal() async {
    if (_localLoaded) return;
    _localLoaded = true;
    try {
      final f = await _settingsFile();
      if (await f.exists()) {
        final data = jsonDecode(await f.readAsString());
        if (data is Map && data['bg_anim'] is bool) {
          bgAnim.value = data['bg_anim'] as bool;
        }
      }
    } catch (_) {}
  }

  Future<File> _settingsFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/oshino_settings.json');
  }

  Future<void> _persistLocal() async {
    try {
      final f = await _settingsFile();
      await f.writeAsString(jsonEncode({'bg_anim': bgAnim.value}));
    } catch (_) {}
  }

  /// Переключение анимированного фона (с сохранением на диск).
  Future<void> setBgAnim(bool enabled) async {
    bgAnim.value = enabled;
    await _persistLocal();
  }

  // ── Реакция по умолчанию (сервер) ──────────────────────────────────────────

  /// Загружает реакцию по умолчанию с сервера. Вызывать после логина.
  Future<void> loadDefaultReaction() async {
    final emoji = await ApiService.getDefaultReaction();
    if (emoji != null && emoji.isNotEmpty) {
      defaultReaction.value = emoji;
    }
  }

  /// Сохраняет новую реакцию по умолчанию на сервер и в кэш.
  Future<bool> setDefaultReaction(String emoji) async {
    final ok = await ApiService.setDefaultReaction(emoji);
    if (ok) defaultReaction.value = emoji;
    return ok;
  }
}
