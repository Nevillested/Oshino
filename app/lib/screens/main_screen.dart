import 'package:flutter/material.dart';
import 'package:audioplayers/audioplayers.dart';
import '../widgets/particle_bg.dart';
import '../services/ws_service.dart';
import '../services/api_service.dart';
import '../services/call_service.dart';
import 'chat_screen.dart';
import 'pacman_screen.dart';
import 'call_screen.dart';

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  final List<OshinoDialog> _dialogs = [];
  final Map<String, String> _lastSeenMap = {};
  final Map<String, String> _displayNames = {};
  final List<String> _onlineUsers = [];
  final Map<String, int> _unreadCounts = {};
  final _audioPlayer = AudioPlayer();
  bool _menuOpen = false;
  double _dragStartX = 0;
  double _dragStartY = 0;

  @override
  void initState() {
    super.initState();

    CallService.instance.startListening();
    WsService.instance.connect();

    ApiService.getUnreadCounts().then((counts) {
      if (!mounted) return;
      setState(() => _unreadCounts.addAll(counts));
    });

    WsService.instance.dialogsStream.listen((dialogs) {
      if (!mounted) return;
      setState(() {
        _dialogs.clear();
        _dialogs.addAll(dialogs);
      });
    });

    WsService.instance.onlineStream.listen((data) {
      if (!mounted) return;
      setState(() {
        _onlineUsers.clear();
        _onlineUsers.addAll(List<String>.from(data['online'] ?? []));
        _lastSeenMap
          ..clear()
          ..addAll(Map<String, String>.from(data['last_seen'] ?? {}));
        _displayNames
          ..clear()
          ..addAll(Map<String, String>.from(data['display_names'] ?? {}));
      });
    });

    WsService.instance.messageStream.listen((data) {
      if (!mounted) return;
      final from = (data['from'] ?? '').toString().toLowerCase();
      if (from.isEmpty) return;
      setState(() {
        _unreadCounts[from] = (_unreadCounts[from] ?? 0) + 1;
      });
      final chatOpen = ChatScreen.activeChat?.toLowerCase() == from;
      final seen = chatOpen && ChatScreen.isAtBottom;
      if (!seen) {
        _audioPlayer
            .play(AssetSource('sounds/income_msg.mp3'))
            .catchError((_) {});
      }
    });

    WsService.instance.readStream.listen((data) {
      if (!mounted) return;
      final by = (data['by'] ?? '').toString().toLowerCase();
      if (by.isEmpty) return;
      setState(() => _unreadCounts.remove(by));
    });

    // Только показ UI входящего звонка
    WsService.instance.callSignalStream.listen((data) {
      if (!mounted) return;
      final type = data['_type'];
      if (type == 'call-offer') {
        _showIncomingCall(data);
      }
    });
  }

  void _showIncomingCall(Map<String, dynamic> data) {
    final from = data['from'] ?? '';
    final isVideo = data['call_type'] == 'video';
    final displayName = _getDisplayName(from);
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => CallScreen(
        peerLogin: from,
        displayName: displayName,
        isVideo: isVideo,
        isIncoming: true,
      ),
    ));
  }

  @override
  void dispose() {
    _audioPlayer.dispose();
    super.dispose();
  }

  String _getDisplayName(String login) =>
      _displayNames[login.toLowerCase()] ?? login;

  bool _isOnline(String login) =>
      _onlineUsers.contains(login.toLowerCase());

  String _formatLastSeen(String login) {
    if (_isOnline(login)) return 'в сети';
    final iso = _lastSeenMap[login.toLowerCase()];
    if (iso == null) return 'не в сети';
    final d = DateTime.tryParse(iso);
    if (d == null) return 'не в сети';
    final now = DateTime.now();
    final diff = now.difference(d);
    if (diff.inMinutes < 1) return 'только что';
    if (diff.inMinutes < 60)
      return 'был(а) в сети ${diff.inMinutes} мин. назад';
    String pad(int n) => n.toString().padLeft(2, '0');
    final time = '${pad(d.hour)}:${pad(d.minute)}';
    final sameDay =
        d.day == now.day && d.month == now.month && d.year == now.year;
    if (sameDay) return 'был(а) в сети в $time';
    return 'был(а) в сети ${pad(d.day)}.${pad(d.month)} в $time';
  }

  void _openMenu() => setState(() => _menuOpen = true);
  void _closeMenu() => setState(() => _menuOpen = false);

  void _openChat(String login) {
    setState(() => _unreadCounts.remove(login.toLowerCase()));
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ChatScreen(
          login: login,
          displayName: _getDisplayName(login),
          lastSeen: _formatLastSeen(login),
          isOnline: _isOnline(login),
        ),
      ),
    );
  }

  void _logout() {
    WsService.instance.dispose();
    ApiService.logout();
    Navigator.of(context).pushReplacementNamed('/login');
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final menuWidth = screenWidth * 0.85;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (_menuOpen) _closeMenu();
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF0d0d0d),
        body: Stack(
          children: [
            const Positioned.fill(
              child: ParticleBackground(darkTheme: true),
            ),

            Column(
              children: [
                SafeArea(
                  bottom: false,
                  child: Container(
                    height: 56,
                    color: const Color(0xFF111318).withOpacity(0.92),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12),
                    child: Row(
                      children: [
                        IconButton(
                          icon: const Icon(Icons.menu,
                              color: Colors.white, size: 24),
                          onPressed: _openMenu,
                          padding: EdgeInsets.zero,
                        ),
                        const SizedBox(width: 8),
                        const Text(
                          'Oshino',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                Expanded(
                  child: _dialogs.isEmpty
                      ? const Center(
                          child: CircularProgressIndicator(
                            color: Color(0xFF4a90e2),
                          ),
                        )
                      : ListView.separated(
                          itemCount: _dialogs.length,
                          separatorBuilder: (_, __) => const Divider(
                            height: 1,
                            color: Color(0xFF1e2128),
                          ),
                          itemBuilder: (context, i) {
                            final d = _dialogs[i];
                            final name = _getDisplayName(d.login);
                            final seen = _formatLastSeen(d.login);
                            final online = _isOnline(d.login);
                            final count =
                                _unreadCounts[d.login.toLowerCase()] ??
                                    0;
                            return InkWell(
                              onTap: () => _openChat(d.login),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 16, vertical: 12),
                                color: Colors.transparent,
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(name,
                                              style: const TextStyle(
                                                  color: Colors.white,
                                                  fontSize: 16)),
                                          const SizedBox(height: 2),
                                          Text(seen,
                                              style: TextStyle(
                                                color: online
                                                    ? const Color(
                                                        0xFF4a90e2)
                                                    : const Color(
                                                        0xFF5a5f70),
                                                fontSize: 13,
                                              )),
                                        ],
                                      ),
                                    ),
                                    if (count > 0)
                                      Container(
                                        padding: const EdgeInsets
                                            .symmetric(
                                            horizontal: 7,
                                            vertical: 3),
                                        decoration: BoxDecoration(
                                          color: const Color(
                                              0xFF4a90e2),
                                          borderRadius:
                                              BorderRadius.circular(
                                                  12),
                                        ),
                                        child: Text(
                                          count > 99
                                              ? '99+'
                                              : count.toString(),
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 12,
                                            fontWeight:
                                                FontWeight.w600,
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),

            if (!_menuOpen)
              Positioned.fill(
                child: GestureDetector(
                  onHorizontalDragStart: (d) {
                    _dragStartX = d.globalPosition.dx;
                    _dragStartY = d.globalPosition.dy;
                  },
                  onHorizontalDragUpdate: (d) {
                    final totalDx =
                        (d.globalPosition.dx - _dragStartX).abs();
                    final totalDy =
                        (d.globalPosition.dy - _dragStartY).abs();
                    if (_dragStartX > 20 &&
                        d.globalPosition.dx - _dragStartX > 30 &&
                        totalDx > totalDy * 1.5) {
                      _openMenu();
                    }
                  },
                  behavior: HitTestBehavior.translucent,
                  child: const SizedBox.expand(),
                ),
              ),

            if (_menuOpen)
              Positioned.fill(
                child: GestureDetector(
                  onTap: _closeMenu,
                  child: Container(
                      color: Colors.black.withOpacity(0.4)),
                ),
              ),

            AnimatedPositioned(
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeOut,
              left: _menuOpen ? 0 : -menuWidth,
              top: 0,
              bottom: 0,
              width: menuWidth,
              child: _MenuPanel(
                onClose: _closeMenu,
                onLogout: _logout,
                onStartChat: (login) {
                  _closeMenu();
                  _openChat(login);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MenuPanel extends StatefulWidget {
  final VoidCallback onClose;
  final VoidCallback onLogout;
  final void Function(String login) onStartChat;

  const _MenuPanel({
    required this.onClose,
    required this.onLogout,
    required this.onStartChat,
  });

  @override
  State<_MenuPanel> createState() => _MenuPanelState();
}

class _MenuPanelState extends State<_MenuPanel> {
  final _searchController = TextEditingController();
  List<String> _searchResults = [];
  bool _searching = false;
  double _dragStartX = 0;
  double _dragStartY = 0;

  Future<void> _search(String query) async {
    if (query.trim().isEmpty) {
      setState(() => _searchResults = []);
      return;
    }
    setState(() => _searching = true);
    final results = await ApiService.searchUsers(query.trim());
    if (!mounted) return;
    setState(() {
      _searchResults = results;
      _searching = false;
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onHorizontalDragStart: (d) {
        _dragStartX = d.globalPosition.dx;
        _dragStartY = d.globalPosition.dy;
      },
      onHorizontalDragUpdate: (d) {
        final totalDx =
            (_dragStartX - d.globalPosition.dx).abs();
        final totalDy =
            (d.globalPosition.dy - _dragStartY).abs();
        if (_dragStartX - d.globalPosition.dx > 30 &&
            totalDx > totalDy * 1.5) {
          widget.onClose();
        }
      },
      child: Container(
        color: const Color(0xFF111318),
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: TextField(
                  controller: _searchController,
                  onChanged: _search,
                  decoration: InputDecoration(
                    hintText: 'Найти пользователя...',
                    hintStyle:
                        const TextStyle(color: Color(0xFF5a5f70)),
                    filled: true,
                    fillColor: const Color(0xFF1a1d24),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(20),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 10),
                    suffixIcon: _searching
                        ? const Padding(
                            padding: EdgeInsets.all(10),
                            child: SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Color(0xFF4a90e2),
                              ),
                            ),
                          )
                        : null,
                  ),
                  style: const TextStyle(
                      color: Colors.white, fontSize: 14),
                ),
              ),

              if (_searchResults.isNotEmpty)
                Container(
                  margin:
                      const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF161820),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: _searchResults.length,
                    separatorBuilder: (_, __) => const Divider(
                        height: 1, color: Color(0xFF2a2d38)),
                    itemBuilder: (_, i) => Material(
                      color: Colors.transparent,
                      child: ListTile(
                        dense: true,
                        title: Text(_searchResults[i],
                            style: const TextStyle(
                                color: Color(0xFFd8dce6),
                                fontSize: 14)),
                        onTap: () =>
                            widget.onStartChat(_searchResults[i]),
                      ),
                    ),
                  ),
                ),

              const Expanded(child: SizedBox()),

              const Divider(color: Color(0xFF2a2d38), height: 1),
              _MenuItem(
                icon: Icons.sports_esports,
                label: 'Pac-Man',
                onTap: () {
                  widget.onClose();
                  Navigator.of(context).push(
                    MaterialPageRoute(
                        builder: (_) => const PacmanScreen()),
                  );
                },
              ),
              _MenuItem(
                icon: Icons.settings,
                label: 'Настройки',
                onTap: () {},
              ),
              Padding(
                padding:
                    const EdgeInsets.fromLTRB(12, 4, 12, 12),
                child: SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: widget.onLogout,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF4a90e2),
                      padding: const EdgeInsets.symmetric(
                          vertical: 13),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    child: const Text(
                      'Выход',
                      style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MenuItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _MenuItem(
      {required this.icon,
      required this.label,
      required this.onTap});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading:
          Icon(icon, color: const Color(0xFF8a90a8), size: 20),
      title: Text(label,
          style: const TextStyle(
              color: Color(0xFFd8dce6), fontSize: 15)),
      onTap: onTap,
      dense: true,
    );
  }
}