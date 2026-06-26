import 'dart:convert';
import 'package:http/http.dart' as http;

class ApiService {
  static const String baseUrl = 'https://oshino.space';
  static String? _sessionToken;

  static String? get sessionToken => _sessionToken;

  // Логин — возвращает null если успешно, строку с ошибкой если нет
  static Future<String?> login(String login, String password) async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/login'),
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: 'login=${Uri.encodeComponent(login)}&password=${Uri.encodeComponent(password)}',
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
}