import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'api_service.dart';

class OshinoDialog {
  final String login;
  final String lastMsg;
  OshinoDialog({required this.login, required this.lastMsg});
}

class WsService {
  static WsService? _instance;
  static WsService get instance => _instance ??= WsService._();
  WsService._();

  WebSocket? _socket;
  bool _disposed = false;

  final _dialogsController =
      StreamController<List<OshinoDialog>>.broadcast();
  final _currentLoginController = StreamController<String>.broadcast();
  final _onlineController =
      StreamController<Map<String, dynamic>>.broadcast();
  final _messageController =
      StreamController<Map<String, dynamic>>.broadcast();
  final _msgAckController =
      StreamController<Map<String, dynamic>>.broadcast();
  final _readController =
      StreamController<Map<String, dynamic>>.broadcast();
  final _callSignalController =
      StreamController<Map<String, dynamic>>.broadcast();
  final _reactionController =
      StreamController<Map<String, dynamic>>.broadcast();
  final _pinController =
      StreamController<Map<String, dynamic>>.broadcast();

  Stream<List<OshinoDialog>> get dialogsStream => _dialogsController.stream;
  Stream<String> get currentLoginStream => _currentLoginController.stream;
  Stream<Map<String, dynamic>> get onlineStream => _onlineController.stream;
  Stream<Map<String, dynamic>> get messageStream => _messageController.stream;
  Stream<Map<String, dynamic>> get msgAckStream => _msgAckController.stream;
  Stream<Map<String, dynamic>> get readStream => _readController.stream;
  Stream<Map<String, dynamic>> get callSignalStream =>
      _callSignalController.stream;
  Stream<Map<String, dynamic>> get reactionStream => _reactionController.stream;
  Stream<Map<String, dynamic>> get pinStream => _pinController.stream;

  String currentLogin = '';
  List<String> onlineUsers = [];
  Map<String, String> lastSeenMap = {};
  Map<String, String> displayNames = {};
  List<OshinoDialog> lastDialogs = [];

  Future<void> connect() async {
    _disposed = false;
    try {
      final token = ApiService.sessionToken;
      _socket = await WebSocket.connect(
        'wss://oshino.space/ws',
        headers: token != null ? {'Cookie': 'session=$token'} : {},
      );
      _socket!.listen(
        _onMessage,
        onError: (_) => _reconnect(),
        onDone: () => _reconnect(),
      );
      await Future.delayed(const Duration(milliseconds: 300));
      send('getdialogs');
      send('focus');
    } catch (e) {
      _reconnect();
    }
  }

  void _reconnect() {
    if (_disposed) return;
    Future.delayed(const Duration(seconds: 3), connect);
  }

  void send(String msg) {
    _socket?.add(msg);
  }

  void _onMessage(dynamic raw) {
    final message = raw as String;

    if (message.startsWith('user:')) {
      currentLogin = message.substring(5);
      _currentLoginController.add(currentLogin);

    } else if (message.startsWith('dialogs:')) {
      final list = jsonDecode(message.substring(8)) as List;
      final dialogs = list.map((e) {
        if (e is String) return OshinoDialog(login: e, lastMsg: '');
        return OshinoDialog(
          login: e['login'] as String,
          lastMsg: e['last_msg'] ?? '',
        );
      }).toList();
      lastDialogs = dialogs;
      _dialogsController.add(dialogs);

    } else if (message.startsWith('online:')) {
      final data = jsonDecode(message.substring(7));
      if (data is List) {
        onlineUsers = List<String>.from(data);
      } else {
        onlineUsers = List<String>.from(data['online'] ?? []);
        lastSeenMap = Map<String, String>.from(data['last_seen'] ?? {});
        displayNames =
            Map<String, String>.from(data['display_names'] ?? {});
      }
      _onlineController.add({
        'online': onlineUsers,
        'last_seen': lastSeenMap,
        'display_names': displayNames,
      });

    } else if (message.startsWith('msgack:')) {
      try {
        final data = jsonDecode(message.substring(7));
        _msgAckController.add(data as Map<String, dynamic>);
      } catch (_) {}

    } else if (message.startsWith('msg:')) {
      try {
        final data = jsonDecode(message.substring(4));
        _messageController.add(data as Map<String, dynamic>);
      } catch (_) {}

    } else if (message.startsWith('read:')) {
      try {
        final data = jsonDecode(message.substring(5));
        _readController.add(data as Map<String, dynamic>);
      } catch (_) {}

    } else if (message.startsWith('reaction:')) {
      try {
        final data = jsonDecode(message.substring(9));
        _reactionController.add(data as Map<String, dynamic>);
      } catch (_) {}

    } else if (message.startsWith('pin:')) {
      try {
        final data = jsonDecode(message.substring(4));
        _pinController.add({...data, '_pinned': true});
      } catch (_) {}

    } else if (message.startsWith('unpin:')) {
      try {
        // Тело unpin несёт {message_id:0, with:"<собеседник>"} — сохраняем
        // with, чтобы экран чата мог отфильтровать событие по диалогу
        // (иначе открепление в одном чате погасит баннер в другом).
        final data = jsonDecode(message.substring(6));
        _pinController.add({...data, '_pinned': false});
      } catch (_) {}

    } else if (message.startsWith('call-offer:')) {
      try {
        final data = jsonDecode(message.substring(11));
        _callSignalController.add({...data, '_type': 'call-offer'});
      } catch (_) {}

    } else if (message.startsWith('call-answer:')) {
      try {
        final data = jsonDecode(message.substring(12));
        _callSignalController.add({...data, '_type': 'call-answer'});
      } catch (_) {}

    } else if (message.startsWith('call-ice:')) {
      try {
        final data = jsonDecode(message.substring(9));
        _callSignalController.add({...data, '_type': 'call-ice'});
      } catch (_) {}

    } else if (message.startsWith('call-end:')) {
      try {
        final data = jsonDecode(message.substring(9));
        _callSignalController.add({...data, '_type': 'call-end'});
      } catch (_) {}

    } else if (message.startsWith('call-video-on:')) {
      try {
        final data = jsonDecode(message.substring(14));
        _callSignalController.add({...data, '_type': 'call-video-on'});
      } catch (_) {}

    } else if (message.startsWith('call-video-enabled:')) {
      try {
        final data = jsonDecode(message.substring(19));
        _callSignalController.add({...data, '_type': 'call-video-enabled'});
      } catch (_) {}

    } else if (message.startsWith('call-video-disabled:')) {
      try {
        final data = jsonDecode(message.substring(20));
        _callSignalController.add({...data, '_type': 'call-video-disabled'});
      } catch (_) {}
    }
  }

  void dispose() {
    _disposed = true;
    _socket?.close();
  }
}