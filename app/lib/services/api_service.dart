import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

class ApiService {
  static const String baseUrl = 'https://oshino.space';
  static String? _sessionToken;

  static String? get sessionToken => _sessionToken;

  // ── Персистентное хранение токена сессии ───────────────────────────────────
  //
  // Токен пишется в файл рядом с настройками (path_provider, как oshino_settings).
  // Это убирает разлогин при перезапуске приложения: сессия живёт на сервере
  // (TTL 1 год), пока пользователь сам не нажмёт «Выход» или админ не выполнит
  // kill-all-sessions. В обоих случаях запись в messenger.sessions удаляется,
  // и проверка restoreSession() получит 401 → локальный токен будет стёрт.

  static Future<File> _tokenFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/oshino_session');
  }

  static Future<void> _persistToken(String token) async {
    try {
      final f = await _tokenFile();
      await f.writeAsString(token);
    } catch (_) {}
  }

  static Future<void> _clearToken() async {
    try {
      final f = await _tokenFile();
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  /// Восстановление сессии при старте приложения.
  /// Возвращает true, если сохранённый токен ещё действителен на сервере.
  ///
  /// • Нет файла / пустой токен → false (показываем экран входа).
  /// • Сервер ответил 200 на авторизованный запрос → true.
  /// • Сервер ответил 401 (logout/kill-all-sessions/истёк) → чистим токен, false.
  /// • Нет сети на старте → НЕ разлогиниваем: оставляем токен в памяти и пускаем
  ///   в приложение (true), WS-сервис переподключится сам, когда сеть появится.
  static Future<bool> restoreSession() async {
    try {
      final f = await _tokenFile();
      if (!await f.exists()) return false;
      final token = (await f.readAsString()).trim();
      if (token.isEmpty) return false;
      _sessionToken = token;

      final response = await http
          .get(
            Uri.parse('$baseUrl/unread-counts'),
            headers: authHeaders,
          )
          .timeout(const Duration(seconds: 8));

      if (response.statusCode == 200) return true;

      if (response.statusCode == 401) {
        _sessionToken = null;
        await _clearToken();
        return false;
      }

      // Прочие коды (5xx и т.п.) — не считаем сессию мёртвой, пускаем внутрь.
      return true;
    } catch (_) {
      // Таймаут/отсутствие сети: оставляем сохранённый токен в силе.
      return _sessionToken != null && _sessionToken!.isNotEmpty;
    }
  }

  static Future<String?> login(String login, String password) async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/login'),
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body:
            'login=${Uri.encodeComponent(login)}&password=${Uri.encodeComponent(password)}',
      );
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['error'] != null) return data['error'];
        final cookie = response.headers['set-cookie'];
        if (cookie != null) {
          _sessionToken = _extractSessionToken(cookie);
        }
        // На случай отсутствия set-cookie (прокси и т.п.) — токен есть и в теле.
        if ((_sessionToken == null || _sessionToken!.isEmpty) &&
            data['token'] != null) {
          _sessionToken = data['token'].toString();
        }
        if (_sessionToken != null && _sessionToken!.isNotEmpty) {
          await _persistToken(_sessionToken!);
        }
        return null;
      } else {
        return 'Ошибка сервера: ${response.statusCode}';
      }
    } catch (e) {
      return 'Нет соединения с сервером';
    }
  }

  static String? _extractSessionToken(String cookieHeader) {
    for (final part in cookieHeader.split(';')) {
      final trimmed = part.trim();
      if (trimmed.startsWith('session=')) {
        return trimmed.substring('session='.length);
      }
    }
    return null;
  }

  static Map<String, String> get authHeaders => {
        if (_sessionToken != null) 'Cookie': 'session=$_sessionToken',
      };

  /// Явный выход: гасим сессию на сервере (best-effort) и стираем локальный токен,
  /// чтобы при следующем запуске приложение показало экран входа.
  static Future<void> logout() async {
    final token = _sessionToken;
    _sessionToken = null;
    await _clearToken();
    if (token != null && token.isNotEmpty) {
      try {
        await http
            .get(
              Uri.parse('$baseUrl/logout'),
              headers: {'Cookie': 'session=$token'},
            )
            .timeout(const Duration(seconds: 5));
      } catch (_) {}
    }
  }

  static Future<List<String>> searchUsers(String query) async {
    try {
      final response = await http.get(
        Uri.parse('$baseUrl/search?q=${Uri.encodeComponent(query)}'),
        headers: authHeaders,
      );
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data is List) return List<String>.from(data);
      }
    } catch (_) {}
    return [];
  }

  // ── FCM (push для нативного приложения) ─────────────────────────────────────

  static Future<bool> fcmSubscribe(String token) async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/fcm-subscribe'),
        headers: {
          ...authHeaders,
          'Content-Type': 'application/json',
        },
        body: jsonEncode({'token': token}),
      );
      return response.statusCode == 200;
    } catch (_) {}
    return false;
  }

  static Future<bool> fcmUnsubscribe(String token) async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/fcm-unsubscribe'),
        headers: {
          ...authHeaders,
          'Content-Type': 'application/json',
        },
        body: jsonEncode({'token': token}),
      );
      return response.statusCode == 200;
    } catch (_) {}
    return false;
  }

  static Future<List<Map<String, dynamic>>> loadHistory(
      String withUser, int beforeId, int limit) async {
    try {
      final response = await http.get(
        Uri.parse(
            '$baseUrl/history?with=${Uri.encodeComponent(withUser)}&before_id=$beforeId&limit=$limit'),
        headers: authHeaders,
      );
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data is List) return List<Map<String, dynamic>>.from(data);
      }
    } catch (_) {}
    return [];
  }

  static Future<void> markRead(String withUser) async {
    try {
      await http.get(
        Uri.parse('$baseUrl/mark-read?with=${Uri.encodeComponent(withUser)}'),
        headers: authHeaders,
      );
    } catch (_) {}
  }

  static Future<Map<String, int>> getUnreadCounts() async {
    try {
      final response = await http.get(
        Uri.parse('$baseUrl/unread-counts'),
        headers: authHeaders,
      );
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data is Map) {
          return Map<String, int>.from(
              data.map((k, v) => MapEntry(k.toString(), (v as num).toInt())));
        }
      }
    } catch (_) {}
    return {};
  }

  static Future<Map<String, dynamic>?> uploadImage(
      String filePath, String toUser) async {
    try {
      final request =
          http.MultipartRequest('POST', Uri.parse('$baseUrl/upload-image'));
      request.headers.addAll(authHeaders);
      request.fields['to'] = toUser;
      request.files.add(await http.MultipartFile.fromPath('file', filePath));
      final streamed = await request.send();
      final response = await http.Response.fromStream(streamed);
      if (response.statusCode == 200) {
        return jsonDecode(response.body) as Map<String, dynamic>;
      }
    } catch (_) {}
    return null;
  }

  static Future<Map<String, dynamic>?> uploadAudio(
      String filePath, String toUser, int duration) async {
    try {
      final request =
          http.MultipartRequest('POST', Uri.parse('$baseUrl/upload-audio'));
      request.headers.addAll(authHeaders);
      request.fields['to'] = toUser;
      request.fields['duration'] = duration.toString();
      request.files.add(await http.MultipartFile.fromPath('file', filePath,
          filename: 'voice.m4a'));
      final streamed = await request.send();
      final response = await http.Response.fromStream(streamed);
      if (response.statusCode == 200) {
        return jsonDecode(response.body) as Map<String, dynamic>;
      }
    } catch (_) {}
    return null;
  }

  // ── Реакции ───────────────────────────────────────────────────────────────

  static Future<bool> react(int messageId, String emoji) async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/react'),
        headers: {
          ...authHeaders,
          'Content-Type': 'application/x-www-form-urlencoded',
        },
        body: 'message_id=$messageId&emoji=${Uri.encodeComponent(emoji)}',
      );
      return response.statusCode == 200;
    } catch (_) {}
    return false;
  }

  // ── Закреп ────────────────────────────────────────────────────────────────

  static Future<Map<String, dynamic>?> getPinned(String withUser) async {
    try {
      final response = await http.get(
        Uri.parse('$baseUrl/pinned?with=${Uri.encodeComponent(withUser)}'),
        headers: authHeaders,
      );
      if (response.statusCode == 200 && response.body.isNotEmpty) {
        final data = jsonDecode(response.body);
        if (data is Map<String, dynamic>) return data;
      }
    } catch (_) {}
    return null;
  }

  static Future<bool> pin(String withUser, int messageId) async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/pin'),
        headers: {
          ...authHeaders,
          'Content-Type': 'application/x-www-form-urlencoded',
        },
        body:
            'with=${Uri.encodeComponent(withUser)}&message_id=$messageId',
      );
      return response.statusCode == 200;
    } catch (_) {}
    return false;
  }

  static Future<bool> unpin(String withUser) async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/unpin'),
        headers: {
          ...authHeaders,
          'Content-Type': 'application/x-www-form-urlencoded',
        },
        body: 'with=${Uri.encodeComponent(withUser)}',
      );
      return response.statusCode == 200;
    } catch (_) {}
    return false;
  }

  // ── Пересылка ─────────────────────────────────────────────────────────────

  static Future<bool> forward(int messageId, String toUser) async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/forward'),
        headers: {
          ...authHeaders,
          'Content-Type': 'application/x-www-form-urlencoded',
        },
        body:
            'message_id=$messageId&to=${Uri.encodeComponent(toUser)}',
      );
      return response.statusCode == 200;
    } catch (_) {}
    return false;
  }

  // ── Настройки: реакция по умолчанию (/settings) ────────────────────────────

  static Future<String?> getDefaultReaction() async {
    try {
      final response = await http.get(
        Uri.parse('$baseUrl/settings'),
        headers: authHeaders,
      );
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data is Map && data['default_reaction'] != null) {
          return data['default_reaction'].toString();
        }
      }
    } catch (_) {}
    return null;
  }

  static Future<bool> setDefaultReaction(String emoji) async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/settings'),
        headers: {
          ...authHeaders,
          'Content-Type': 'application/x-www-form-urlencoded',
        },
        body: 'default_reaction=${Uri.encodeComponent(emoji)}',
      );
      return response.statusCode == 200;
    } catch (_) {}
    return false;
  }

  // ── Настройки: отображаемое имя (/display-name) ─────────────────────────────

  static Future<String> getDisplayName() async {
    try {
      final response = await http.get(
        Uri.parse('$baseUrl/display-name'),
        headers: authHeaders,
      );
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data is Map && data['display_name'] != null) {
          return data['display_name'].toString();
        }
      }
    } catch (_) {}
    return '';
  }

  static Future<Map<String, dynamic>> setDisplayName(String name) async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/display-name'),
        headers: {
          ...authHeaders,
          'Content-Type': 'application/x-www-form-urlencoded',
        },
        body: 'display_name=${Uri.encodeComponent(name)}',
      );
      try {
        final data = jsonDecode(response.body);
        if (data is Map<String, dynamic>) return data;
      } catch (_) {}
      if (response.statusCode == 200) return {'success': 'ok'};
      return {'error': 'Ошибка сервера (${response.statusCode})'};
    } catch (_) {
      return {'error': 'Ошибка соединения'};
    }
  }

  // ── Настройки: смена своего пароля (/change-password) ───────────────────────

  static Future<Map<String, dynamic>> changePassword(
      String newPassword) async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/change-password'),
        headers: {
          ...authHeaders,
          'Content-Type': 'application/x-www-form-urlencoded',
        },
        body: 'new_password=${Uri.encodeComponent(newPassword)}',
      );
      if (response.statusCode == 200) return {'success': 'ok'};
      final body = response.body.trim();
      return {
        'error': body.isNotEmpty
            ? body
            : 'Ошибка сервера (${response.statusCode})'
      };
    } catch (_) {
      return {'error': 'Ошибка соединения'};
    }
  }

  // ── Админ-операции (только для login == "admin") ───────────────────────────

  static Future<Map<String, dynamic>> _adminPost(
      String path, String body) async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl$path'),
        headers: {
          ...authHeaders,
          'Content-Type': 'application/x-www-form-urlencoded',
        },
        body: body,
      );
      try {
        final data = jsonDecode(response.body);
        if (data is Map<String, dynamic>) return data;
      } catch (_) {}
      if (response.statusCode == 200) return {'success': 'ok'};
      if (response.statusCode == 403) return {'error': 'Недостаточно прав'};
      return {'error': 'Ошибка сервера (${response.statusCode})'};
    } catch (_) {
      return {'error': 'Ошибка соединения'};
    }
  }

  static Future<Map<String, dynamic>> adminAddUser(
          String login, String password) =>
      _adminPost(
          '/admin/add-user',
          'new_login=${Uri.encodeComponent(login)}'
          '&new_password=${Uri.encodeComponent(password)}');

  static Future<Map<String, dynamic>> adminChangeUserPassword(
          String targetLogin, String newPassword) =>
      _adminPost(
          '/admin/change-user-password',
          'target_login=${Uri.encodeComponent(targetLogin)}'
          '&new_password=${Uri.encodeComponent(newPassword)}');

  static Future<Map<String, dynamic>> adminDisableUser(String targetLogin) =>
      _adminPost('/admin/disable-user',
          'target_login=${Uri.encodeComponent(targetLogin)}');

  static Future<Map<String, dynamic>> adminEnableUser(String targetLogin) =>
      _adminPost('/admin/enable-user',
          'target_login=${Uri.encodeComponent(targetLogin)}');

  static Future<Map<String, dynamic>> adminKillAllSessions() =>
      _adminPost('/admin/kill-all-sessions', '');
}
