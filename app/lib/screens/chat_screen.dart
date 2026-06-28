import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:image_picker/image_picker.dart';
import 'package:record/record.dart';
import 'package:path_provider/path_provider.dart';
import 'package:http/http.dart' as http;
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../models/message.dart';
import '../services/api_service.dart';
import '../services/ws_service.dart';
import '../services/call_service.dart';
import '../services/settings_service.dart';
import '../widgets/particle_bg.dart';
import 'call_screen.dart';

class ChatScreen extends StatefulWidget {
  static String? activeChat;
  static bool isAtBottom = false;

  final String login;
  final String displayName;
  final String lastSeen;
  final bool isOnline;

  const ChatScreen({
    super.key,
    required this.login,
    required this.displayName,
    required this.lastSeen,
    required this.isOnline,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> with WidgetsBindingObserver {
  final List<OshinoMessage> _messages = [];
  final _inputController = TextEditingController();
  final _scrollController = ScrollController();
  final _inputFocusNode = FocusNode();
  final _audioPlayer = AudioPlayer();
  final _voicePlayer = AudioPlayer();
  final _recorder = AudioRecorder();

  bool _loading = false;
  bool _allLoaded = false;
  int _oldestId = 0;
  String _lastSeen = '';
  bool _isOnline = false;
  bool _isAppActive = true;

  bool _isRecording = false;
  int _recordingSeconds = 0;
  String? _playingAudioId;

  // Ответ на сообщение
  OshinoMessage? _replyingTo;

  // Закреплённое сообщение
  Map<String, dynamic>? _pinnedMsg;

  // Переход к закреплённому: ключ на каждое сообщение (для
  // Scrollable.ensureVisible) и id подсвечиваемого после перехода.
  final Map<int, GlobalKey> _messageKeys = {};
  int? _highlightedMsgId;

  // Контекстное меню
  OshinoMessage? _ctxMsg;
  double _ctxGlobalY = 0;
  bool _ctxOwnMessage = false;

  // Режим множественного выбора сообщений (для массовой пересылки).
  bool _selectionMode = false;
  final Set<int> _selectedIds = {};

  // Логика одиночного/двойного тапа
  Timer? _tapTimer;
  OshinoMessage? _pendingTapMsg;
  double _pendingTapY = 0;

  // Свайп слева направо — назад к списку диалогов (те же пороги, что у
  // открытия меню на главной). _swipeBackTriggered защищает от повторного
  // pop во время одного жеста (onHorizontalDragUpdate срабатывает многократно).
  double _dragStartX = 0;
  double _dragStartY = 0;
  bool _swipeBackTriggered = false;

  static const List<String> _reactionEmojis = ['👍','❤️','😂','😮','😢','👏'];

  @override
  void initState() {
    super.initState();
    ChatScreen.activeChat = widget.login;
    ChatScreen.isAtBottom = true;
    WidgetsBinding.instance.addObserver(this);
    _lastSeen = widget.lastSeen;
    _isOnline = widget.isOnline;
    _loadHistory(initial: true);
    _loadPinned();

    _scrollController.addListener(() {
      ChatScreen.isAtBottom = _isAtBottom();
      if (_scrollController.position.pixels <=
              _scrollController.position.minScrollExtent + 100 &&
          !_loading && !_allLoaded) {
        _loadHistory();
      }
      if (_isAtBottom()) _markRead();
    });

    WsService.instance.messageStream.listen((data) {
      if (!mounted) return;
      final from = (data['from'] ?? '').toString().toLowerCase();
      if (from != widget.login.toLowerCase()) return;
      final msg = OshinoMessage.fromJson(
          {...data, 'id': data['msg_id'], 'own': false});
      setState(() => _messages.add(msg));
      _scrollToBottom();
      if (!_isAtBottom()) _playMessageSound();
      if (_isAppActive && _isAtBottom()) _markRead();
    });

    WsService.instance.msgAckStream.listen((data) {
      if (!mounted) return;
      final to = (data['to'] ?? '').toString().toLowerCase();
      if (to != widget.login.toLowerCase()) return;

      final msgId = (data['msg_id'] as num?)?.toInt();
      final hasMedia =
          data['image_id'] != null || data['audio_id'] != null;

      setState(() {
        // Сообщение с таким id уже есть (повторный ack либо медиа, уже
        // добавленное ответом аплоада) — не задваиваем.
        if (msgId != null &&
            msgId > 0 &&
            _messages.any((m) => m.id == msgId)) {
          return;
        }

        if (!hasMedia) {
          // Обычная отправка текста с этого устройства — реконсилим
          // оптимистичный плейсхолдер.
          final idx = _messages.indexWhere((m) =>
              m.pending && m.own && m.imageId == null && m.audioId == null);
          if (idx >= 0) {
            _messages[idx] = _messages[idx].copyWith(
              id: msgId ?? _messages[idx].id,
              createdAt:
                  data['created_at']?.toString() ?? _messages[idx].createdAt,
              pending: false,
            );
            return;
          }
        } else {
          // Медиа: если идёт наша же загрузка (есть незавершённый медиа-
          // плейсхолдер), реконсиляцию сделает ответ аплоада — ack пропускаем.
          final hasPendingMedia = _messages.any((m) =>
              m.pending && m.own && (m.imageId != null || m.audioId != null));
          if (hasPendingMedia) return;
        }

        // Плейсхолдера нет: это пересылка в текущий чат (или отправка с другого
        // устройства) — добавляем сообщение как своё сразу же.
        _messages.add(OshinoMessage.fromJson(
            {...data, 'id': msgId, 'own': true, 'pending': false}));
      });
      _scrollToBottom();
    });

    WsService.instance.readStream.listen((data) {
      if (!mounted) return;
      final by = (data['by'] ?? '').toString().toLowerCase();
      final withUser = (data['with'] ?? '').toString().toLowerCase();
      if (by == widget.login.toLowerCase() ||
          withUser == widget.login.toLowerCase()) {
        setState(() {
          for (int i = 0; i < _messages.length; i++) {
            if (_messages[i].own && !_messages[i].isRead) {
              _messages[i] = _messages[i].copyWith(isRead: true);
            }
          }
        });
      }
    });

    WsService.instance.onlineStream.listen((data) {
      if (!mounted) return;
      final online = List<String>.from(data['online'] ?? []);
      final lastSeen = Map<String, String>.from(data['last_seen'] ?? {});
      setState(() {
        _isOnline = online.contains(widget.login.toLowerCase());
        if (!_isOnline) {
          final iso = lastSeen[widget.login.toLowerCase()];
          if (iso != null) _lastSeen = _formatLastSeen(iso);
        } else {
          _lastSeen = 'в сети';
        }
      });
    });

    // Реакции
    WsService.instance.reactionStream.listen((data) {
      if (!mounted) return;
      final msgId = (data['message_id'] as num?)?.toInt();
      final from = (data['from'] ?? '').toString();
      final emoji = (data['emoji'] ?? '').toString();
      if (msgId == null) return;

      setState(() {
        final idx = _messages.indexWhere((m) => m.id == msgId);
        if (idx >= 0) {
          final reactions = List<Map<String, String>>.from(_messages[idx].reactions);
          reactions.removeWhere((r) => r['from'] == from);
          if (emoji.isNotEmpty) reactions.add({'emoji': emoji, 'from': from});
          _messages[idx] = _messages[idx].copyWith(reactions: reactions);
        }
      });
    });

    // Закреп
    WsService.instance.pinStream.listen((data) {
      if (!mounted) return;
      setState(() {
        if (data['_pinned'] == true) {
          _pinnedMsg = {
            'message_id': data['message_id'],
            'from': data['from'],
            'text': data['text'],
          };
        } else {
          _pinnedMsg = null;
        }
      });
    });
  }

  Future<void> _loadPinned() async {
    final data = await ApiService.getPinned(widget.login);
    if (!mounted) return;
    if (data != null && data['message_id'] != null) {
      setState(() => _pinnedMsg = data);
    }
  }

  // Переход к закреплённому сообщению: догружаем историю, пока сообщение не
  // окажется в списке, затем центрируем и подсвечиваем.
  Future<void> _scrollToMessage(int messageId) async {
    if (messageId <= 0) return;

    // 1. Догрузить историю вверх, пока сообщение не появится в _messages
    //    (или пока не упрёмся в начало переписки).
    int guard = 0;
    while (_messages.indexWhere((m) => m.id == messageId) < 0 &&
        !_allLoaded && guard < 60) {
      guard++;
      final before = _messages.length;
      await _loadHistory();
      if (!mounted) return;
      if (_messages.length == before) break; // больше ничего не грузится
    }

    final idx = _messages.indexWhere((m) => m.id == messageId);
    if (idx < 0) return; // не нашли — тихо выходим

    // 2. Подсветка на ~1.6 с
    setState(() => _highlightedMsgId = messageId);
    Future.delayed(const Duration(milliseconds: 1600), () {
      if (mounted && _highlightedMsgId == messageId) {
        setState(() => _highlightedMsgId = null);
      }
    });

    // 3. Центрировать. ensureVisible работает только для построенного виджета
    //    (в пределах cacheExtent), поэтому если он далеко — сначала прыгаем
    //    примерно по доле индекса, ждём кадр, и так до 8 попыток.
    for (int attempt = 0; attempt < 8; attempt++) {
      final ctx = _messageKeys[messageId]?.currentContext;
      if (ctx != null) {
        await Scrollable.ensureVisible(
          ctx,
          alignment: 0.3,
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeInOut,
        );
        return;
      }
      if (_scrollController.hasClients) {
        final total = _messages.length;
        final ratio = total <= 1 ? 0.0 : idx / (total - 1);
        final pos = _scrollController.position;
        _scrollController.jumpTo(
          (pos.maxScrollExtent * ratio)
              .clamp(pos.minScrollExtent, pos.maxScrollExtent),
        );
      }
      await Future.delayed(const Duration(milliseconds: 50));
      if (!mounted) return;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _isAppActive = state == AppLifecycleState.resumed;
    if (_isAppActive) _markRead();
  }

  bool _isAtBottom() {
    if (!_scrollController.hasClients) return true;
    return _scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 50;
  }

  void _playMessageSound() async {
    try { await _audioPlayer.play(AssetSource('sounds/income_msg.mp3')); } catch (_) {}
  }

  String _formatLastSeen(String iso) {
    final d = DateTime.tryParse(iso);
    if (d == null) return 'не в сети';
    final now = DateTime.now();
    final diff = now.difference(d);
    if (diff.inMinutes < 1) return 'только что';
    if (diff.inMinutes < 60) return 'был(а) в сети ${diff.inMinutes} мин. назад';
    String pad(int n) => n.toString().padLeft(2, '0');
    final time = '${pad(d.hour)}:${pad(d.minute)}';
    final sameDay = d.day == now.day && d.month == now.month && d.year == now.year;
    if (sameDay) return 'был(а) в сети в $time';
    return 'был(а) в сети ${pad(d.day)}.${pad(d.month)} в $time';
  }

  Future<void> _loadHistory({bool initial = false}) async {
    if (_loading) return;
    setState(() => _loading = true);
    final data = await ApiService.loadHistory(widget.login, initial ? 0 : _oldestId, 20);
    if (!mounted) return;
    final msgs = data.map((j) => OshinoMessage.fromJson(j)).toList();
    setState(() {
      if (msgs.length < 20) _allLoaded = true;
      if (msgs.isNotEmpty) _oldestId = msgs.first.id;
      _messages.insertAll(0, msgs);
      _loading = false;
    });
    if (initial) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
      _markRead();
    }
  }

  void _markRead() => ApiService.markRead(widget.login);

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      final pos = _scrollController.position;
      if (pos.maxScrollExtent > 0) {
        _scrollController.jumpTo(pos.maxScrollExtent);
      } else {
        Future.delayed(const Duration(milliseconds: 100), _scrollToBottom);
      }
    });
  }

  // ── Тап: одиночный = меню, двойной = реакция ─────────────────────────────

  void _handleMessageTap(OshinoMessage msg, double globalY) {
    if (_tapTimer != null && _tapTimer!.isActive && _pendingTapMsg?.id == msg.id) {
      _tapTimer!.cancel();
      _tapTimer = null;
      _pendingTapMsg = null;
      _sendReaction(msg, SettingsService.instance.defaultReaction.value);
      return;
    }
    _tapTimer?.cancel();
    _pendingTapMsg = msg;
    _pendingTapY = globalY;
    _tapTimer = Timer(const Duration(milliseconds: 280), () {
      _tapTimer = null;
      if (!mounted) return;
      final m = _pendingTapMsg;
      final y = _pendingTapY;
      _pendingTapMsg = null;
      if (m != null) _showContextMenu(m, y);
    });
  }

  void _showContextMenu(OshinoMessage msg, double globalY) {
    setState(() {
      _ctxMsg = msg;
      _ctxGlobalY = globalY;
      _ctxOwnMessage = msg.own;
    });
  }

  void _dismissContextMenu() {
    if (_ctxMsg != null) setState(() => _ctxMsg = null);
  }

  // ── Множественный выбор сообщений ─────────────────────────────────────────

  void _enterSelection(OshinoMessage msg) {
    if (msg.id <= 0) return;
    // Гасим возможное контекстное меню / ожидающий двойной тап.
    _dismissContextMenu();
    _tapTimer?.cancel();
    _tapTimer = null;
    _pendingTapMsg = null;
    setState(() {
      _selectionMode = true;
      _selectedIds.add(msg.id);
    });
  }

  void _toggleSelection(OshinoMessage msg) {
    if (msg.id <= 0) return;
    setState(() {
      if (_selectedIds.contains(msg.id)) {
        _selectedIds.remove(msg.id);
      } else {
        _selectedIds.add(msg.id);
      }
      if (_selectedIds.isEmpty) _selectionMode = false;
    });
  }

  void _exitSelection() {
    if (!_selectionMode && _selectedIds.isEmpty) return;
    setState(() {
      _selectionMode = false;
      _selectedIds.clear();
    });
  }

  void _forwardSelected() {
    final ids = _selectedIds.toList()..sort(); // в хронологическом порядке
    if (ids.isEmpty) return;
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1a1d24),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
        child: _ForwardSheet(
          onSelect: (login) async {
            Navigator.pop(ctx);
            int okCount = 0;
            // Последовательно — чтобы сообщения пришли в исходном порядке.
            for (final id in ids) {
              final ok = await ApiService.forward(id, login);
              if (ok) okCount++;
            }
            if (!mounted) return;
            _exitSelection();
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text(okCount > 0
                  ? 'Переслано пользователю $login: $okCount'
                  : 'Ошибка пересылки'),
              duration: const Duration(seconds: 2),
            ));
          },
        ),
      ),
    );
  }

  // Кружок-галочка слева/справа от сообщения в режиме выбора.
  Widget _selectionCheck(bool selected) {
    return Container(
      width: 22,
      height: 22,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: selected ? const Color(0xFF4a90e2) : Colors.transparent,
        border: Border.all(
          color: selected ? const Color(0xFF4a90e2) : const Color(0xFF5a5f70),
          width: 2,
        ),
      ),
      child: selected
          ? const Icon(Icons.check, size: 14, color: Colors.white)
          : null,
    );
  }

  void _sendReaction(OshinoMessage msg, String emoji) {
    ApiService.react(msg.id, emoji);
    // Оптимистично обновляем локально
    final me = WsService.instance.currentLogin;
    setState(() {
      final idx = _messages.indexWhere((m) => m.id == msg.id);
      if (idx >= 0) {
        final reactions = List<Map<String, String>>.from(_messages[idx].reactions);
        reactions.removeWhere((r) => r['from'] == me);
        reactions.add({'emoji': emoji, 'from': me});
        _messages[idx] = _messages[idx].copyWith(reactions: reactions);
      }
    });
  }

  void _sendMessage() {
    final text = _inputController.text.trim();
    if (text.isEmpty) return;
    _inputController.clear();

    final replyMsg = _replyingTo;
    setState(() => _replyingTo = null);

    final replyAuthor = replyMsg == null
        ? null
        : (replyMsg.own ? 'Вы' : widget.displayName);

    final placeholder = OshinoMessage(
      id: -(DateTime.now().millisecondsSinceEpoch),
      own: true,
      text: text,
      createdAt: DateTime.now().toIso8601String(),
      pending: true,
      replyToId: replyMsg?.id,
      replyPreview: replyMsg != null
          ? (replyMsg.text.isNotEmpty ? replyMsg.text : '[медиа]')
          : null,
      replyFromLogin: replyAuthor,
    );
    setState(() => _messages.add(placeholder));
    _scrollToBottom();

    WsService.instance.send('msg:${jsonEncode({
          'from': WsService.instance.currentLogin,
          'to': widget.login,
          'text': text,
          if (replyMsg != null) 'reply_to_id': replyMsg.id,
        })}');
  }

  Future<void> _sendImage() async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(source: ImageSource.gallery, imageQuality: 85);
    if (picked == null) return;
    final replyMsg = _replyingTo;
    setState(() => _replyingTo = null);

    final placeholder = OshinoMessage(
      id: -(DateTime.now().millisecondsSinceEpoch),
      own: true,
      text: '',
      createdAt: DateTime.now().toIso8601String(),
      pending: true,
      imageId: picked.path,
    );
    setState(() => _messages.add(placeholder));
    _scrollToBottom();

    final result = await ApiService.uploadImage(picked.path, widget.login);
    if (!mounted) return;
    setState(() {
      final idx = _messages.indexWhere(
          (m) => m.pending && m.own && m.imageId == picked.path);
      if (idx >= 0) {
        if (result != null && result['image_id'] != null) {
          _messages[idx] = _messages[idx].copyWith(
            id: (result['id'] as num?)?.toInt() ?? _messages[idx].id,
            createdAt: result['created_at']?.toString() ?? _messages[idx].createdAt,
            imageId: result['image_id'].toString(),
            pending: false,
          );
        } else {
          _messages.removeAt(idx);
        }
      }
    });
  }

  Future<void> _toggleRecording() async {
    if (_isRecording) { await _stopRecording(); } else { await _startRecording(); }
  }

  Future<void> _startRecording() async {
    final hasPermission = await _recorder.hasPermission();
    if (!hasPermission) return;
    final dir = await getTemporaryDirectory();
    final path = '${dir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
    await _recorder.start(const RecordConfig(encoder: AudioEncoder.aacLc), path: path);
    setState(() { _isRecording = true; _recordingSeconds = 0; });
    Future.doWhile(() async {
      await Future.delayed(const Duration(seconds: 1));
      if (!_isRecording || !mounted) return false;
      setState(() => _recordingSeconds++);
      return true;
    });
  }

  Future<void> _stopRecording({bool cancel = false}) async {
    if (!_isRecording) return;
    final path = await _recorder.stop();
    final duration = _recordingSeconds;
    setState(() { _isRecording = false; _recordingSeconds = 0; });
    if (cancel || path == null || duration == 0) return;
    final placeholder = OshinoMessage(
      id: -(DateTime.now().millisecondsSinceEpoch),
      own: true, text: '',
      createdAt: DateTime.now().toIso8601String(),
      pending: true, audioId: 'local', audioDuration: duration,
    );
    setState(() => _messages.add(placeholder));
    _scrollToBottom();
    final result = await ApiService.uploadAudio(path, widget.login, duration);
    if (!mounted) return;
    setState(() {
      final idx = _messages.indexWhere((m) => m.pending && m.own && m.audioId == 'local');
      if (idx >= 0) {
        if (result != null && result['audio_id'] != null) {
          _messages[idx] = _messages[idx].copyWith(
            id: (result['id'] as num?)?.toInt() ?? _messages[idx].id,
            createdAt: result['created_at']?.toString() ?? _messages[idx].createdAt,
            audioId: result['audio_id'].toString(),
            audioDuration: duration,
            pending: false,
          );
        } else {
          _messages.removeAt(idx);
        }
      }
    });
    try { File(path).deleteSync(); } catch (_) {}
  }

  Future<void> _toggleVoicePlayback(OshinoMessage msg) async {
    if (_playingAudioId == msg.audioId) {
      await _voicePlayer.stop();
      setState(() => _playingAudioId = null);
      return;
    }
    setState(() => _playingAudioId = msg.audioId);
    try {
      final response = await http.get(
        Uri.parse('https://oshino.space/audio/${msg.audioId}'),
        headers: ApiService.authHeaders,
      );
      if (response.statusCode == 200) {
        final dir = await getTemporaryDirectory();
        final file = File('${dir.path}/audio_${msg.audioId}.mp3');
        await file.writeAsBytes(response.bodyBytes);
        await _voicePlayer.play(DeviceFileSource(file.path));
        _voicePlayer.onPlayerComplete.listen((_) {
          if (mounted) setState(() => _playingAudioId = null);
        });
      } else {
        setState(() => _playingAudioId = null);
      }
    } catch (_) { setState(() => _playingAudioId = null); }
  }

  // ── Пересылка ─────────────────────────────────────────────────────────────
void _showForwardDialog(OshinoMessage msg) {
  _dismissContextMenu();
  showModalBottomSheet(
    context: context,
    backgroundColor: const Color(0xFF1a1d24),
    isScrollControlled: true, // позволяет расширяться над клавиатурой
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
    builder: (ctx) => Padding(
      // Отступ снизу = высота клавиатуры
      padding: EdgeInsets.only(
          bottom: MediaQuery.of(ctx).viewInsets.bottom),
      child: _ForwardSheet(
        onSelect: (login) async {
          Navigator.pop(ctx);
          final ok = await ApiService.forward(msg.id, login);
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(ok
                ? 'Переслано пользователю $login'
                : 'Ошибка пересылки'),
            duration: const Duration(seconds: 2),
          ));
        },
      ),
    ),
  );
}

  String _formatTime(String iso) {
    final d = DateTime.tryParse(iso);
    if (d == null) return '';
    String pad(int n) => n.toString().padLeft(2, '0');
    return '${pad(d.hour)}:${pad(d.minute)}';
  }

  String _formatRecordingTime() {
    final m = _recordingSeconds ~/ 60;
    final s = _recordingSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  @override
  void dispose() {
    _tapTimer?.cancel();
    ChatScreen.activeChat = null;
    ChatScreen.isAtBottom = false;
    WidgetsBinding.instance.removeObserver(this);
    _inputController.dispose();
    _inputFocusNode.dispose();
    _scrollController.dispose();
    _audioPlayer.dispose();
    _voicePlayer.dispose();
    _recorder.dispose();
    super.dispose();
  }

  // ── BUILD ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final screenHeight = MediaQuery.of(context).size.height;
    return PopScope(
      canPop: !_selectionMode,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && _selectionMode) _exitSelection();
      },
      child: Scaffold(
      backgroundColor: const Color(0xFF0d0d0d),
      body: Stack(
        children: [
          const Positioned.fill(child: OshinoBackground()),
          Column(
            children: [
              // Топбар
              SafeArea(
                bottom: false,
                child: Container(
                  color: const Color(0xFF111318).withOpacity(0.92),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        height: 60,
                        child: _selectionMode
                            ? _buildSelectionBar()
                            : Row(
                          children: [
                            IconButton(
                              icon: const Icon(Icons.arrow_back, color: Colors.white, size: 22),
                              onPressed: () => Navigator.of(context).pop(),
                            ),
                            Expanded(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(widget.displayName,
                                      style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600),
                                      overflow: TextOverflow.ellipsis),
                                  Text(_lastSeen,
                                      style: TextStyle(
                                          color: _isOnline ? const Color(0xFF4a90e2) : const Color(0xFF5a5f70),
                                          fontSize: 12)),
                                ],
                              ),
                            ),
                            IconButton(
                              icon: const Icon(Icons.call, color: Colors.white, size: 22),
                              onPressed: () async {
                                await CallService.instance.startCall(widget.login);
                                if (!mounted) return;
                                Navigator.of(context).push(MaterialPageRoute(
                                  builder: (_) => CallScreen(
                                    peerLogin: widget.login, displayName: widget.displayName,
                                    isVideo: false, isIncoming: false),
                                ));
                              },
                            ),
                            IconButton(
                              icon: const Icon(Icons.videocam, color: Colors.white, size: 22),
                              onPressed: () async {
                                await CallService.instance.startCall(widget.login, video: true);
                                if (!mounted) return;
                                Navigator.of(context).push(MaterialPageRoute(
                                  builder: (_) => CallScreen(
                                    peerLogin: widget.login, displayName: widget.displayName,
                                    isVideo: true, isIncoming: false),
                                ));
                              },
                            ),
                          ],
                        ),
                      ),
                      // Закреп
                      if (_pinnedMsg != null) _buildPinBanner(),
                    ],
                  ),
                ),
              ),

              // Сообщения
              Expanded(
                child: Stack(
                  children: [
                    _loading && _messages.isEmpty
                        ? const Center(child: CircularProgressIndicator(color: Color(0xFF4a90e2)))
                        : ListView.builder(
                            controller: _scrollController,
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            itemCount: _messages.length + (_loading && _messages.isNotEmpty ? 1 : 0),
                            itemBuilder: (context, i) {
                              if (i == 0 && _loading && _messages.isNotEmpty) {
                                return const Padding(
                                  padding: EdgeInsets.all(8),
                                  child: Center(child: SizedBox(width: 20, height: 20,
                                      child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF4a90e2)))));
                              }
                              final idx = _loading && _messages.isNotEmpty ? i - 1 : i;
                              return _buildMessageRow(_messages[idx]);
                            },
                          ),
                    // Свайп слева направо — назад к списку диалогов. Те же пороги,
                    // что у открытия меню на главной (main_screen). Поверх ленты,
                    // translucent — тап и вертикальный скролл проходят сквозь.
                    // Отключаем, пока открыто контекстное меню.
                    if (_ctxMsg == null)
                      Positioned.fill(
                        child: GestureDetector(
                          behavior: HitTestBehavior.translucent,
                          onHorizontalDragStart: (d) {
                            _dragStartX = d.globalPosition.dx;
                            _dragStartY = d.globalPosition.dy;
                            _swipeBackTriggered = false;
                          },
                          onHorizontalDragUpdate: (d) {
                            if (_swipeBackTriggered) return;
                            final totalDx = (d.globalPosition.dx - _dragStartX).abs();
                            final totalDy = (d.globalPosition.dy - _dragStartY).abs();
                            if (_dragStartX > 20 &&
                                d.globalPosition.dx - _dragStartX > 30 &&
                                totalDx > totalDy * 1.5) {
                              _swipeBackTriggered = true;
                              if (_selectionMode) {
                                _exitSelection();
                              } else {
                                Navigator.of(context).pop();
                              }
                            }
                          },
                          onHorizontalDragEnd: (_) => _swipeBackTriggered = false,
                          child: const SizedBox.expand(),
                        ),
                      ),
                  ],
                ),
              ),

              // Панель ввода
              SafeArea(
                top: false,
                child: Container(
                  color: const Color(0xFF111318).withOpacity(0.92),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_replyingTo != null) _buildReplyBar(),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                        child: _isRecording ? _buildRecordingBar() : _buildInputBar(),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),

          // Затемнение
          if (_ctxMsg != null)
            Positioned.fill(
              child: GestureDetector(
                onTap: _dismissContextMenu,
                behavior: HitTestBehavior.opaque,
                child: Container(color: Colors.black.withOpacity(0.35)),
              ),
            ),

          // Меню
          if (_ctxMsg != null) _buildContextMenuOverlay(screenHeight),
        ],
      ),
      ),
    );
  }

  // Верхняя панель в режиме выбора: закрыть · счётчик · переслать.
  Widget _buildSelectionBar() {
    return Row(
      children: [
        IconButton(
          icon: const Icon(Icons.close, color: Colors.white, size: 22),
          onPressed: _exitSelection,
        ),
        Expanded(
          child: Text(
            'Выбрано: ${_selectedIds.length}',
            style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w600),
          ),
        ),
        IconButton(
          icon: const Icon(Icons.forward, color: Colors.white, size: 22),
          tooltip: 'Переслать',
          onPressed: _selectedIds.isEmpty ? null : _forwardSelected,
        ),
      ],
    );
  }

  // ── ЗАКРЕП ────────────────────────────────────────────────────────────────

  Widget _buildPinBanner() {
    final pinnedId = (_pinnedMsg!['message_id'] as num?)?.toInt();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: Color(0xFF2a2d38), width: 0.5)),
      ),
      child: Row(
        children: [
          // Тап по телу баннера — переход к закреплённому сообщению
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: pinnedId != null ? () => _scrollToMessage(pinnedId) : null,
              child: Row(
                children: [
                  const Icon(Icons.push_pin,
                      size: 14, color: Color(0xFF4a90e2)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('${_pinnedMsg!['from'] ?? 'Закреплено'}',
                            style: const TextStyle(
                                color: Color(0xFF4a90e2),
                                fontSize: 11,
                                fontWeight: FontWeight.w600)),
                        Text(_pinnedMsg!['text']?.toString() ?? '',
                            style: const TextStyle(
                                color: Colors.white70, fontSize: 12),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          GestureDetector(
            onTap: () async {
              await ApiService.unpin(widget.login);
              if (mounted) setState(() => _pinnedMsg = null);
            },
            child: const Padding(
              padding: EdgeInsets.only(left: 8),
              child: Icon(Icons.close, size: 16, color: Colors.white38),
            ),
          ),
        ],
      ),
    );
  }

  // ── БРЕД ОТВЕТА ──────────────────────────────────────────────────────────

  Widget _buildReplyBar() {
    final msg = _replyingTo!;
    final author = msg.own ? 'Вы' : widget.displayName;
    final preview = msg.text.isNotEmpty ? msg.text : '[медиа]';
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Color(0xFF2a2d38), width: 0.5)),
      ),
      child: Row(
        children: [
          Container(width: 3, height: 36, color: const Color(0xFF4a90e2), margin: const EdgeInsets.only(right: 10)),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(author, style: const TextStyle(color: Color(0xFF4a90e2), fontSize: 12, fontWeight: FontWeight.w600)),
                Text(preview,
                    style: const TextStyle(color: Colors.white70, fontSize: 13),
                    maxLines: 1, overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, color: Colors.white38, size: 18),
            onPressed: () => setState(() => _replyingTo = null),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
          ),
        ],
      ),
    );
  }

  // ── КОНТЕКСТНОЕ МЕНЮ ──────────────────────────────────────────────────────
Widget _buildContextMenuOverlay(double screenHeight) {
  final msg = _ctxMsg!;
  final keyboardHeight = MediaQuery.of(context).viewInsets.bottom;
  // Реальная высота Stack (Scaffold сжимается при открытой клавиатуре)
  final stackHeight = screenHeight - keyboardHeight;

  // Клампируем Y в пределах видимой области Stack
  final clampedY = _ctxGlobalY.clamp(80.0, stackHeight - 20.0);
  final showAbove = clampedY > stackHeight * 0.55;

  final top = showAbove ? null : (clampedY + 8);
  final bottom = showAbove ? (stackHeight - clampedY + 8) : null;

  return Positioned(
    top: top,
    bottom: bottom,
    left: _ctxOwnMessage ? null : 12,
    right: _ctxOwnMessage ? 12 : null,
    child: TweenAnimationBuilder<double>(
      key: ValueKey(msg.id),
      tween: Tween(begin: 0.0, end: 1.0),
      duration: const Duration(milliseconds: 150),
      curve: Curves.easeOutBack,
      builder: (context, value, child) {
        final alignment = _ctxOwnMessage
            ? (showAbove ? Alignment.bottomRight : Alignment.topRight)
            : (showAbove ? Alignment.bottomLeft : Alignment.topLeft);
        return Transform.scale(
          scale: value.clamp(0.0, 1.1),
          alignment: alignment,
          child: Opacity(opacity: value.clamp(0.0, 1.0), child: child),
        );
      },
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: 240,
          decoration: BoxDecoration(
            color: const Color(0xFF1e2128),
            borderRadius: BorderRadius.circular(14),
            boxShadow: const [BoxShadow(
                color: Colors.black54, blurRadius: 14, offset: Offset(0, 4))],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 10, 8, 6),
                child: Row(
                  children: _reactionEmojis.map((emoji) {
                    return Expanded(
                      child: GestureDetector(
                        onTap: () {
                          final m = _ctxMsg!;
                          _dismissContextMenu();
                          _sendReaction(m, emoji);
                        },
                        child: Center(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            child: Text(emoji,
                                style: const TextStyle(fontSize: 22)),
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ),
              const Divider(height: 1, color: Color(0xFF2a2d38), thickness: 1),
              if (msg.text.isNotEmpty)
                _ctxItem(Icons.copy_outlined, 'Копировать', () {
                  final m = _ctxMsg!;
                  _dismissContextMenu();
                  Clipboard.setData(ClipboardData(text: m.text));
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                      content: Text('Скопировано'),
                      duration: Duration(seconds: 1)));
                }),
              _ctxItem(Icons.reply_outlined, 'Ответить', () {
                final m = _ctxMsg!;
                _dismissContextMenu();
                setState(() => _replyingTo = m);
                _inputFocusNode.requestFocus();
              }),
              _ctxItem(Icons.push_pin_outlined, 'Закрепить', () async {
                final m = _ctxMsg!;
                _dismissContextMenu();
                final ok = await ApiService.pin(widget.login, m.id);
                if (!mounted) return;
                if (ok) {
                  setState(() => _pinnedMsg = {
                        'message_id': m.id,
                        'from': m.own
                            ? WsService.instance.currentLogin
                            : widget.login,
                        'text': m.text.isNotEmpty ? m.text : '[медиа]',
                      });
                }
              }),
              _ctxItem(Icons.forward_outlined, 'Переслать', () {
                final m = _ctxMsg!;
                _showForwardDialog(m);
              }, isLast: true),
            ],
          ),
        ),
      ),
    ),
  );
}

  Widget _ctxItem(IconData icon, String label, VoidCallback onTap, {bool isLast = false}) {
    return InkWell(
      onTap: onTap,
      borderRadius: isLast ? const BorderRadius.vertical(bottom: Radius.circular(14)) : BorderRadius.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
        child: Row(
          children: [
            Icon(icon, color: const Color(0xFF8a90a8), size: 18),
            const SizedBox(width: 12),
            Text(label, style: const TextStyle(color: Color(0xFFd8dce6), fontSize: 14)),
          ],
        ),
      ),
    );
  }

  // ── СООБЩЕНИЯ ─────────────────────────────────────────────────────────────

  Widget _buildMessageRow(OshinoMessage msg) {
    if (msg.callType != null) return _buildCallLog(msg);
    // Ключ на сообщение — для перехода к закреплённому (Scrollable.ensureVisible).
    final key = msg.id > 0
        ? _messageKeys.putIfAbsent(msg.id, () => GlobalKey())
        : null;
    final highlighted = _highlightedMsgId == msg.id;
    final selectable = msg.id > 0;
    final selected = _selectionMode && _selectedIds.contains(msg.id);

    final bubble = AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 2),
      decoration: BoxDecoration(
        color: highlighted ? const Color(0x334a90e2) : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment:
            msg.own ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          if (msg.forwardedFrom != null)
            Padding(
              padding: EdgeInsets.only(left: msg.own ? 0 : 4, right: msg.own ? 4 : 0, bottom: 2),
              child: Text('↗ Переслано от ${msg.forwardedFrom}',
                  style: const TextStyle(color: Color(0xFF4a90e2), fontSize: 11)),
            ),
          if (msg.imageId != null)
            _buildImageMessage(msg)
          else if (msg.audioId != null)
            _buildAudioMessage(msg)
          else
            _buildTextMessage(msg),
          // Реакции
          _buildReactions(msg),
        ],
      ),
    );

    // В режиме выбора — кружок-галочка: слева у сообщений собеседника,
    // справа у своих. Невыбираемые (pending) — кружок не показываем.
    Widget rowChild;
    if (_selectionMode) {
      final check = Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Opacity(
          opacity: selectable ? 1 : 0,
          child: _selectionCheck(selected),
        ),
      );
      rowChild = Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: msg.own
            ? [Expanded(child: bubble), const SizedBox(width: 4), check]
            : [check, const SizedBox(width: 4), Expanded(child: bubble)],
      );
    } else {
      rowChild = bubble;
    }

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapUp: (details) {
        if (_selectionMode) {
          _toggleSelection(msg);
        } else {
          _handleMessageTap(msg, details.globalPosition.dy);
        }
      },
      onLongPress: selectable
          ? () {
              if (_selectionMode) {
                _toggleSelection(msg);
              } else {
                _enterSelection(msg);
              }
            }
          : null,
      child: AnimatedContainer(
        key: key,
        duration: const Duration(milliseconds: 150),
        color: selected ? const Color(0x1a4a90e2) : Colors.transparent,
        // В режиме выбора игнорируем внутренние нажатия (воспроизведение
        // голосового, открытие фото) — любой тап по строке = выбор.
        child: _selectionMode ? IgnorePointer(child: rowChild) : rowChild,
      ),
    );
  }

  Widget _buildReactions(OshinoMessage msg) {
    final grouped = msg.reactionsGrouped;
    if (grouped.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: EdgeInsets.only(
          top: 3, left: msg.own ? 0 : 4, right: msg.own ? 4 : 0),
      child: Wrap(
        spacing: 4,
        children: grouped.entries.map((e) {
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
            decoration: BoxDecoration(
              color: const Color(0xFF2a2d38),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFF3a3f52), width: 0.5),
            ),
            child: Text(
              '${e.key}${e.value.length > 1 ? ' ${e.value.length}' : ''}',
              style: const TextStyle(fontSize: 13),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildReplyQuote(OshinoMessage msg) {
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
      decoration: BoxDecoration(
        border: Border(
          left: BorderSide(
              color: msg.own ? Colors.white54 : const Color(0xFF4a90e2), width: 3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (msg.replyFromLogin != null)
            Text(msg.replyFromLogin!,
                style: TextStyle(
                    color: msg.own ? Colors.white70 : const Color(0xFF4a90e2),
                    fontSize: 11,
                    fontWeight: FontWeight.w600)),
          Text(msg.replyPreview ?? '',
              style: TextStyle(
                  color: msg.own ? Colors.white60 : const Color(0xFF8a90a8),
                  fontSize: 12),
              maxLines: 1,
              overflow: TextOverflow.ellipsis),
        ],
      ),
    );
  }

  Widget _buildTextMessage(OshinoMessage msg) {
    final time = _formatTime(msg.createdAt);
    return Align(
      alignment: msg.own ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.75),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: msg.own
              ? const Color(0xFF4a90e2).withOpacity(msg.pending ? 0.5 : 0.85)
              : const Color(0xFF1e2128).withOpacity(0.85),
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(12),
            topRight: const Radius.circular(12),
            bottomLeft: Radius.circular(msg.own ? 12 : 2),
            bottomRight: Radius.circular(msg.own ? 2 : 12),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (msg.replyPreview != null) _buildReplyQuote(msg),
            Text(msg.text, style: const TextStyle(color: Colors.white, fontSize: 14)),
            const SizedBox(height: 2),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(time, style: const TextStyle(color: Colors.white54, fontSize: 10)),
                if (msg.own) ...[
                  const SizedBox(width: 3),
                  Icon(
                    msg.pending ? Icons.access_time : msg.isRead ? Icons.done_all : Icons.done,
                    size: 12,
                    color: msg.isRead ? Colors.white : Colors.white54,
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildImageMessage(OshinoMessage msg) {
    final time = _formatTime(msg.createdAt);
    final isLocal = msg.imageId != null && msg.imageId!.startsWith('/');
    return Align(
      alignment: msg.own ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.65),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: isLocal
                  ? Image.file(File(msg.imageId!), fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => _imagePlaceholder())
                  : Image.network('https://oshino.space/image/${msg.imageId}',
                      headers: ApiService.authHeaders, fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => _imagePlaceholder()),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 2, right: 2),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(time, style: const TextStyle(color: Colors.white54, fontSize: 10)),
                  if (msg.own) ...[
                    const SizedBox(width: 3),
                    Icon(
                      msg.pending ? Icons.access_time : msg.isRead ? Icons.done_all : Icons.done,
                      size: 12,
                      color: msg.isRead ? Colors.white : Colors.white54,
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _imagePlaceholder() => Container(
      width: 200, height: 150,
      color: const Color(0xFF1e2128),
      child: const Icon(Icons.broken_image, color: Colors.white38));

  Widget _buildAudioMessage(OshinoMessage msg) {
    final time = _formatTime(msg.createdAt);
    final dur = msg.audioDuration ?? 0;
    final durStr = '${dur ~/ 60}:${(dur % 60).toString().padLeft(2, '0')}';
    final isPlaying = _playingAudioId == msg.audioId;
    final canPlay = msg.audioId != null && msg.audioId != 'local' && !msg.pending;
    return Align(
      alignment: msg.own ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: msg.own
              ? const Color(0xFF4a90e2).withOpacity(msg.pending ? 0.5 : 0.85)
              : const Color(0xFF1e2128).withOpacity(0.85),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            GestureDetector(
              onTap: canPlay ? () => _toggleVoicePlayback(msg) : null,
              child: Icon(isPlaying ? Icons.pause_circle : Icons.play_circle,
                  color: canPlay ? Colors.white : Colors.white38, size: 28),
            ),
            const SizedBox(width: 8),
            Text(durStr, style: const TextStyle(color: Colors.white, fontSize: 13)),
            const SizedBox(width: 8),
            Text(time, style: const TextStyle(color: Colors.white54, fontSize: 10)),
            if (msg.own) ...[
              const SizedBox(width: 4),
              Icon(
                msg.pending ? Icons.access_time : msg.isRead ? Icons.done_all : Icons.done,
                size: 12, color: msg.isRead ? Colors.white : Colors.white54,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildCallLog(OshinoMessage msg) {
    final answered = msg.callStatus == 'answered';
    final isVideo = msg.callType == 'video';
    final dur = msg.callDuration;
    String text;
    if (answered && dur != null) {
      final m = dur ~/ 60;
      final s = (dur % 60).toString().padLeft(2, '0');
      text = isVideo ? 'Видеозвонок $m:$s' : 'Аудиозвонок $m:$s';
    } else if (msg.callStatus == 'declined') {
      text = isVideo ? 'Видеозвонок отклонён' : 'Аудиозвонок отклонён';
    } else {
      text = isVideo ? 'Пропущенный видеозвонок' : 'Пропущенный аудиозвонок';
    }
    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: answered
              ? const Color(0xFF1e2128).withOpacity(0.8)
              : const Color(0xFF3a1a1a).withOpacity(0.8),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(isVideo ? Icons.videocam : Icons.call, size: 14,
                color: answered ? const Color(0xFF4a90e2) : const Color(0xFFe05555)),
            const SizedBox(width: 6),
            Text(text,
                style: TextStyle(
                    color: answered ? const Color(0xFF8a90a8) : const Color(0xFFe05555),
                    fontSize: 12)),
          ],
        ),
      ),
    );
  }

  // ── ПАНЕЛЬ ВВОДА ──────────────────────────────────────────────────────────

  Widget _buildInputBar() {
    return Row(
      children: [
        IconButton(
          icon: const Icon(Icons.image, color: Color(0xFF8a90a8), size: 22),
          onPressed: _sendImage,
        ),
        IconButton(
          icon: const Icon(Icons.mic, color: Color(0xFF8a90a8), size: 22),
          onPressed: _toggleRecording,
        ),
        Expanded(
          child: TextField(
            controller: _inputController,
            focusNode: _inputFocusNode,
            decoration: InputDecoration(
              hintText: 'Сообщение...',
              hintStyle: const TextStyle(color: Color(0xFF5a5f70)),
              filled: true,
              fillColor: const Color(0xFF1a1d24),
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(20), borderSide: BorderSide.none),
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            ),
            style: const TextStyle(color: Colors.white, fontSize: 14),
            maxLines: 4, minLines: 1,
            textInputAction: TextInputAction.send,
            onSubmitted: (_) => _sendMessage(),
            onTap: _dismissContextMenu,
          ),
        ),
        const SizedBox(width: 6),
        ElevatedButton(
          onPressed: _sendMessage,
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF4a90e2),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            minimumSize: Size.zero,
          ),
          child: const Text('Отправить', style: TextStyle(fontSize: 13)),
        ),
      ],
    );
  }

  Widget _buildRecordingBar() {
    return Row(
      children: [
        GestureDetector(
          onTap: () => _stopRecording(cancel: true),
          child: const Padding(padding: EdgeInsets.all(8),
              child: Icon(Icons.close, color: Color(0xFFe05555), size: 22)),
        ),
        const SizedBox(width: 8),
        Container(width: 8, height: 8,
            decoration: const BoxDecoration(color: Color(0xFFe05555), shape: BoxShape.circle)),
        const SizedBox(width: 8),
        Text(_formatRecordingTime(),
            style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w500)),
        const Expanded(
          child: Padding(padding: EdgeInsets.only(left: 8),
              child: Text('Идёт запись...', style: TextStyle(color: Color(0xFF5a5f70), fontSize: 13))),
        ),
        GestureDetector(
          onTap: () => _stopRecording(),
          child: Container(
            padding: const EdgeInsets.all(8),
            decoration: const BoxDecoration(color: Color(0xFF4a90e2), shape: BoxShape.circle),
            child: const Icon(Icons.send, color: Colors.white, size: 18),
          ),
        ),
      ],
    );
  }
}

// ── Диалог пересылки ──────────────────────────────────────────────────────────

class _ForwardSheet extends StatefulWidget {
  final void Function(String login) onSelect;
  const _ForwardSheet({required this.onSelect});

  @override
  State<_ForwardSheet> createState() => _ForwardSheetState();
}

class _ForwardSheetState extends State<_ForwardSheet> {
  final _searchController = TextEditingController();
  List<String> _results = [];
  bool _searching = false;

  @override
  void initState() {
    super.initState();
    // Показываем существующие диалоги по умолчанию
    setState(() {
      _results = WsService.instance.lastDialogs
          .map((d) => d.login)
          .toList();
    });
  }

  Future<void> _search(String query) async {
    if (query.trim().isEmpty) {
      setState(() => _results = WsService.instance.lastDialogs.map((d) => d.login).toList());
      return;
    }
    setState(() => _searching = true);
    final res = await ApiService.searchUsers(query.trim());
    if (!mounted) return;
    setState(() { _results = res; _searching = false; });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Text('Переслать',
              style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: TextField(
            controller: _searchController,
            onChanged: _search,
            decoration: InputDecoration(
              hintText: 'Найти пользователя...',
              hintStyle: const TextStyle(color: Color(0xFF5a5f70)),
              filled: true,
              fillColor: const Color(0xFF111318),
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(20), borderSide: BorderSide.none),
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              suffixIcon: _searching
                  ? const Padding(padding: EdgeInsets.all(10),
                      child: SizedBox(width: 16, height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF4a90e2))))
                  : null,
            ),
            style: const TextStyle(color: Colors.white, fontSize: 14),
          ),
        ),
        ConstrainedBox(
          constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.4),
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: _results.length,
            itemBuilder: (_, i) => ListTile(
              title: Text(_results[i],
                  style: const TextStyle(color: Colors.white)),
              leading: const CircleAvatar(
                  backgroundColor: Color(0xFF2a2d38),
                  child: Icon(Icons.person, color: Color(0xFF8a90a8), size: 18)),
              onTap: () => widget.onSelect(_results[i]),
            ),
          ),
        ),
        SizedBox(height: MediaQuery.of(context).padding.bottom + 8),
      ],
    );
  }
}