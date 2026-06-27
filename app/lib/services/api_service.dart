import 'dart:convert';
import 'package:http/http.dart' as http;

class ApiService {
  static const String baseUrl = 'https://oshino.space';
  static String? _sessionToken;

  static String? get sessionToken => _sessionToken;

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

  static void logout() {
    _sessionToken = null;
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
}