import 'package:flutter/material.dart';
import '../services/api_service.dart';
import '../services/ws_service.dart';
import '../services/settings_service.dart';

// ── Палитра (в тон тёмной темы приложения) ───────────────────────────────────
const _bg = Color(0xFF111318);
const _card = Color(0xFF1a1d24);
const _accent = Color(0xFF4a90e2);
const _text = Color(0xFFd8dce6);
const _textDim = Color(0xFF8a90a8);
const _hint = Color(0xFF5a5f70);
const _divider = Color(0xFF2a2d38);
const _danger = Color(0xFFc0392b);
const _success = Color(0xFF27ae60);

// ── Общие хелперы ─────────────────────────────────────────────────────────────

InputDecoration _dec(String hint) => InputDecoration(
      hintText: hint,
      hintStyle: const TextStyle(color: _hint),
      filled: true,
      fillColor: _card,
      isDense: true,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: _accent, width: 1.4),
      ),
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
    );

Widget _subScaffold({required String title, required Widget body}) {
  return Scaffold(
    backgroundColor: _bg,
    appBar: AppBar(
      backgroundColor: _bg,
      elevation: 0,
      iconTheme: const IconThemeData(color: _text),
      titleSpacing: 0,
      title: Text(title,
          style: const TextStyle(
              color: _text, fontSize: 17, fontWeight: FontWeight.w600)),
    ),
    body: SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        child: body,
      ),
    ),
  );
}

/// Горизонтальный слайд для подменю внутри боковой панели.
Route<T> _panelSlide<T>(Widget page) {
  return PageRouteBuilder<T>(
    transitionDuration: const Duration(milliseconds: 220),
    reverseTransitionDuration: const Duration(milliseconds: 180),
    pageBuilder: (_, __, ___) => page,
    transitionsBuilder: (_, anim, __, child) => SlideTransition(
      position: Tween<Offset>(begin: const Offset(1, 0), end: Offset.zero)
          .animate(CurvedAnimation(parent: anim, curve: Curves.easeOut)),
      child: child,
    ),
  );
}

Future<bool> _confirm(BuildContext context, String message) async {
  final res = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: _bg,
      title: const Text('Подтверждение', style: TextStyle(color: _text)),
      content: Text(message, style: const TextStyle(color: _textDim)),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Отмена', style: TextStyle(color: _textDim)),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Да', style: TextStyle(color: _accent)),
        ),
      ],
    ),
  );
  return res ?? false;
}

/// Кнопка «Сохранить/Создать/…» во всю ширину.
class _SaveButton extends StatelessWidget {
  final String label;
  final bool busy;
  final Color color;
  final VoidCallback onPressed;
  const _SaveButton({
    required this.label,
    required this.busy,
    required this.onPressed,
    this.color = _accent,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        onPressed: busy ? null : onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: color,
          disabledBackgroundColor: color.withOpacity(0.5),
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
          ),
        ),
        child: busy
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: Colors.white),
              )
            : Text(label,
                style: const TextStyle(
                    fontSize: 15, fontWeight: FontWeight.w600)),
      ),
    );
  }
}

/// Строка статуса (ошибка/успех) под формой.
class _StatusLine extends StatelessWidget {
  final String text;
  final bool isError;
  const _StatusLine(this.text, {required this.isError});

  @override
  Widget build(BuildContext context) {
    if (text.isEmpty) return const SizedBox(height: 8);
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Text(
        text,
        style: TextStyle(
          color: isError ? const Color(0xFFe57373) : _success,
          fontSize: 13.5,
        ),
      ),
    );
  }
}

Widget _hintText(String text) => Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Text(text, style: const TextStyle(color: _textDim, fontSize: 13)),
    );

Widget _sectionTitle(String text) => Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 12),
      child: Text(text,
          style: const TextStyle(
              color: _text, fontSize: 15, fontWeight: FontWeight.w600)),
    );

// ── Главный экран настроек ────────────────────────────────────────────────────

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  @override
  void initState() {
    super.initState();
    // Если логин ещё не пришёл по WS — обновим UI, когда придёт (для admin-пунктов).
    WsService.instance.currentLoginStream.listen((_) {
      if (mounted) setState(() {});
    });
  }

  void _push(Widget screen) {
    Navigator.of(context).push(_panelSlide(screen));
  }

  Future<void> _killAllSessions() async {
    final ok = await _confirm(
      context,
      'Завершить ВСЕ активные сессии? Все пользователи будут немедленно '
      'выброшены из системы.',
    );
    if (!ok) return;
    final res = await ApiService.adminKillAllSessions();
    if (!mounted) return;
    if (res['error'] != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Ошибка: ${res['error']}')),
      );
      return;
    }
    // Собственная сессия тоже уничтожена — выходим на экран логина.
    WsService.instance.dispose();
    ApiService.logout();
    if (!mounted) return;
    Navigator.of(context, rootNavigator: true)
        .pushNamedAndRemoveUntil('/login', (route) => false);
  }

  @override
  Widget build(BuildContext context) {
    final isAdmin = SettingsService.instance.isAdmin;

    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        elevation: 0,
        iconTheme: const IconThemeData(color: _text),
        titleSpacing: 0,
        title: const Text('Настройки',
            style: TextStyle(
                color: _text, fontSize: 17, fontWeight: FontWeight.w600)),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: [
            _SettingsTile(
              emoji: '😊',
              label: 'Реакции по умолчанию',
              onTap: () => _push(const _DefaultReactionScreen()),
            ),
            _SettingsTile(
              emoji: '✏️',
              label: 'Отображаемое имя',
              onTap: () => _push(const _DisplayNameScreen()),
            ),
            _SettingsTile(
              emoji: '🔑',
              label: 'Смена пароля',
              onTap: () => _push(const _ChangePasswordScreen()),
            ),
            if (isAdmin) ...[
              const _GroupDivider(),
              _SettingsTile(
                emoji: '👤',
                label: 'Добавить пользователя',
                onTap: () => _push(const _AddUserScreen()),
              ),
              _SettingsTile(
                emoji: '🔐',
                label: 'Изменить пароль пользователю',
                onTap: () => _push(const _ChangeUserPasswordScreen()),
              ),
              _SettingsTile(
                emoji: '🚫',
                label: 'Отключить пользователя',
                onTap: () => _push(const _DisableUserScreen()),
              ),
              _SettingsTile(
                emoji: '✅',
                label: 'Включить пользователя',
                onTap: () => _push(const _EnableUserScreen()),
              ),
              _SettingsTile(
                emoji: '⚡',
                label: 'Завершить все сессии',
                danger: true,
                chevron: false,
                onTap: _killAllSessions,
              ),
              const _GroupDivider(),
            ],
            _SettingsTile(
              emoji: '🎨',
              label: 'Анимированный фон',
              onTap: () => _push(const _BgAnimScreen()),
            ),
          ],
        ),
      ),
    );
  }
}

class _GroupDivider extends StatelessWidget {
  const _GroupDivider();
  @override
  Widget build(BuildContext context) => const Padding(
        padding: EdgeInsets.symmetric(vertical: 6, horizontal: 16),
        child: Divider(color: _divider, height: 1),
      );
}

class _SettingsTile extends StatelessWidget {
  final String emoji;
  final String label;
  final VoidCallback onTap;
  final bool danger;
  final bool chevron;

  const _SettingsTile({
    required this.emoji,
    required this.label,
    required this.onTap,
    this.danger = false,
    this.chevron = true,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
        child: Row(
          children: [
            Text(emoji, style: const TextStyle(fontSize: 18)),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  color: danger ? const Color(0xFFe57373) : _text,
                  fontSize: 15,
                  fontWeight: danger ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
            if (chevron)
              const Text('›',
                  style: TextStyle(color: _textDim, fontSize: 22)),
          ],
        ),
      ),
    );
  }
}

// ── Реакции по умолчанию ──────────────────────────────────────────────────────

class _DefaultReactionScreen extends StatefulWidget {
  const _DefaultReactionScreen();
  @override
  State<_DefaultReactionScreen> createState() => _DefaultReactionScreenState();
}

class _DefaultReactionScreenState extends State<_DefaultReactionScreen> {
  Future<void> _select(String emoji) async {
    await SettingsService.instance.setDefaultReaction(emoji);
  }

  @override
  Widget build(BuildContext context) {
    return _subScaffold(
      title: 'Реакции по умолчанию',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionTitle('Реакция по умолчанию'),
          _hintText('Проставляется двойным тапом по сообщению'),
          ValueListenableBuilder<String>(
            valueListenable: SettingsService.instance.defaultReaction,
            builder: (context, current, _) {
              return Wrap(
                spacing: 10,
                runSpacing: 10,
                children: SettingsService.emojiSet.map((emoji) {
                  final selected = emoji == current;
                  return GestureDetector(
                    onTap: () => _select(emoji),
                    child: Container(
                      width: 48,
                      height: 48,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: selected
                            ? _accent.withOpacity(0.22)
                            : _card,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: selected ? _accent : Colors.transparent,
                          width: 1.6,
                        ),
                      ),
                      child: Text(emoji,
                          style: const TextStyle(fontSize: 24)),
                    ),
                  );
                }).toList(),
              );
            },
          ),
        ],
      ),
    );
  }
}

// ── Отображаемое имя ──────────────────────────────────────────────────────────

class _DisplayNameScreen extends StatefulWidget {
  const _DisplayNameScreen();
  @override
  State<_DisplayNameScreen> createState() => _DisplayNameScreenState();
}

class _DisplayNameScreenState extends State<_DisplayNameScreen> {
  final _controller = TextEditingController();
  bool _busy = false;
  bool _loading = true;
  String _status = '';
  bool _statusErr = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final name = await ApiService.getDisplayName();
    if (!mounted) return;
    setState(() {
      _controller.text = name;
      _loading = false;
    });
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _status = '';
    });
    final res = await ApiService.setDisplayName(_controller.text.trim());
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (res['error'] != null) {
        _statusErr = true;
        _status = res['error'].toString();
      } else {
        _statusErr = false;
        _status = 'Сохранено';
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _subScaffold(
      title: 'Отображаемое имя',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionTitle('Отображаемое имя'),
          _hintText(
              'Видно другим пользователям вместо логина. Оставьте пустым — '
              'будет показан логин.'),
          if (_loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 20),
              child: Center(
                child: CircularProgressIndicator(color: _accent),
              ),
            )
          else ...[
            TextField(
              controller: _controller,
              maxLength: 32,
              style: const TextStyle(color: _text, fontSize: 15),
              decoration: _dec('Имя'),
            ),
            const SizedBox(height: 8),
            _SaveButton(label: 'Сохранить', busy: _busy, onPressed: _save),
            _StatusLine(_status, isError: _statusErr),
          ],
        ],
      ),
    );
  }
}

// ── Смена своего пароля ───────────────────────────────────────────────────────

class _ChangePasswordScreen extends StatefulWidget {
  const _ChangePasswordScreen();
  @override
  State<_ChangePasswordScreen> createState() => _ChangePasswordScreenState();
}

class _ChangePasswordScreenState extends State<_ChangePasswordScreen> {
  final _new = TextEditingController();
  final _confirm = TextEditingController();
  bool _busy = false;
  String _status = '';
  bool _statusErr = false;

  Future<void> _save() async {
    final np = _new.text;
    final cp = _confirm.text;
    setState(() {
      _status = '';
      _statusErr = false;
    });
    if (np.isEmpty) {
      setState(() {
        _statusErr = true;
        _status = 'Введите новый пароль';
      });
      return;
    }
    if (np != cp) {
      setState(() {
        _statusErr = true;
        _status = 'Пароли не совпадают';
      });
      return;
    }
    setState(() => _busy = true);
    final res = await ApiService.changePassword(np);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (res['error'] != null) {
        _statusErr = true;
        _status = res['error'].toString();
      } else {
        _statusErr = false;
        _status = 'Пароль изменён';
        _new.clear();
        _confirm.clear();
      }
    });
  }

  @override
  void dispose() {
    _new.dispose();
    _confirm.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _subScaffold(
      title: 'Смена пароля',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionTitle('Новый пароль'),
          TextField(
            controller: _new,
            obscureText: true,
            style: const TextStyle(color: _text, fontSize: 15),
            decoration: _dec('Новый пароль'),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _confirm,
            obscureText: true,
            style: const TextStyle(color: _text, fontSize: 15),
            decoration: _dec('Подтверждение нового пароля'),
          ),
          const SizedBox(height: 14),
          _SaveButton(label: 'Сохранить', busy: _busy, onPressed: _save),
          _StatusLine(_status, isError: _statusErr),
        ],
      ),
    );
  }
}

// ── Анимированный фон ─────────────────────────────────────────────────────────

class _BgAnimScreen extends StatelessWidget {
  const _BgAnimScreen();

  @override
  Widget build(BuildContext context) {
    return _subScaffold(
      title: 'Анимированный фон',
      body: ValueListenableBuilder<bool>(
        valueListenable: SettingsService.instance.bgAnim,
        builder: (context, on, _) {
          return Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Expanded(
                child: Text(
                  'Включить наркоманию на фоне',
                  style: TextStyle(color: _text, fontSize: 15),
                ),
              ),
              Switch(
                value: on,
                activeColor: Colors.white,
                activeTrackColor: _accent,
                inactiveThumbColor: Colors.white,
                inactiveTrackColor: const Color(0xFF3a3f4b),
                onChanged: (v) => SettingsService.instance.setBgAnim(v),
              ),
            ],
          );
        },
      ),
    );
  }
}

// ── Добавить пользователя (admin) ─────────────────────────────────────────────

class _AddUserScreen extends StatefulWidget {
  const _AddUserScreen();
  @override
  State<_AddUserScreen> createState() => _AddUserScreenState();
}

class _AddUserScreenState extends State<_AddUserScreen> {
  final _login = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  String _status = '';
  bool _statusErr = false;

  Future<void> _save() async {
    final login = _login.text.trim();
    final pass = _password.text;
    setState(() {
      _status = '';
      _statusErr = false;
    });
    if (login.isEmpty || pass.isEmpty) {
      setState(() {
        _statusErr = true;
        _status = 'Заполните оба поля';
      });
      return;
    }
    setState(() => _busy = true);
    final res = await ApiService.adminAddUser(login, pass);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (res['error'] != null) {
        _statusErr = true;
        _status = res['error'].toString();
      } else {
        _statusErr = false;
        _status = 'Пользователь «$login» создан';
        _login.clear();
        _password.clear();
      }
    });
  }

  @override
  void dispose() {
    _login.dispose();
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _subScaffold(
      title: 'Добавить пользователя',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionTitle('Новый пользователь'),
          TextField(
            controller: _login,
            style: const TextStyle(color: _text, fontSize: 15),
            decoration: _dec('Логин'),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _password,
            obscureText: true,
            style: const TextStyle(color: _text, fontSize: 15),
            decoration: _dec('Пароль'),
          ),
          const SizedBox(height: 14),
          _SaveButton(label: 'Создать', busy: _busy, onPressed: _save),
          _StatusLine(_status, isError: _statusErr),
        ],
      ),
    );
  }
}

// ── Изменить пароль пользователю (admin) ──────────────────────────────────────

class _ChangeUserPasswordScreen extends StatefulWidget {
  const _ChangeUserPasswordScreen();
  @override
  State<_ChangeUserPasswordScreen> createState() =>
      _ChangeUserPasswordScreenState();
}

class _ChangeUserPasswordScreenState
    extends State<_ChangeUserPasswordScreen> {
  final _login = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  bool _busy = false;
  String _status = '';
  bool _statusErr = false;

  Future<void> _save() async {
    final login = _login.text.trim();
    final pass = _password.text;
    final conf = _confirm.text;
    setState(() {
      _status = '';
      _statusErr = false;
    });
    if (login.isEmpty || pass.isEmpty || conf.isEmpty) {
      setState(() {
        _statusErr = true;
        _status = 'Заполните все поля';
      });
      return;
    }
    if (pass != conf) {
      setState(() {
        _statusErr = true;
        _status = 'Пароли не совпадают';
      });
      return;
    }
    setState(() => _busy = true);
    final res = await ApiService.adminChangeUserPassword(login, pass);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (res['error'] != null) {
        _statusErr = true;
        _status = res['error'].toString();
      } else {
        _statusErr = false;
        _status = 'Пароль пользователя «$login» изменён';
        _login.clear();
        _password.clear();
        _confirm.clear();
      }
    });
  }

  @override
  void dispose() {
    _login.dispose();
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _subScaffold(
      title: 'Изменить пароль пользователю',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionTitle('Смена пароля'),
          TextField(
            controller: _login,
            style: const TextStyle(color: _text, fontSize: 15),
            decoration: _dec('Логин пользователя'),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _password,
            obscureText: true,
            style: const TextStyle(color: _text, fontSize: 15),
            decoration: _dec('Новый пароль'),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _confirm,
            obscureText: true,
            style: const TextStyle(color: _text, fontSize: 15),
            decoration: _dec('Подтверждение пароля'),
          ),
          const SizedBox(height: 14),
          _SaveButton(label: 'Сохранить', busy: _busy, onPressed: _save),
          _StatusLine(_status, isError: _statusErr),
        ],
      ),
    );
  }
}

// ── Отключить пользователя (admin) ────────────────────────────────────────────

class _DisableUserScreen extends StatefulWidget {
  const _DisableUserScreen();
  @override
  State<_DisableUserScreen> createState() => _DisableUserScreenState();
}

class _DisableUserScreenState extends State<_DisableUserScreen> {
  final _login = TextEditingController();
  bool _busy = false;
  String _status = '';
  bool _statusErr = false;

  Future<void> _save() async {
    final target = _login.text.trim();
    setState(() {
      _status = '';
      _statusErr = false;
    });
    if (target.isEmpty) {
      setState(() {
        _statusErr = true;
        _status = 'Введите логин пользователя';
      });
      return;
    }
    final ok = await _confirm(
      context,
      'Отключить пользователя «$target»? Он будет немедленно выброшен из '
      'системы.',
    );
    if (!ok) return;
    if (!mounted) return;
    setState(() => _busy = true);
    final res = await ApiService.adminDisableUser(target);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (res['error'] != null) {
        _statusErr = true;
        _status = res['error'].toString();
      } else {
        _statusErr = false;
        _status = 'Пользователь «$target» отключён';
        _login.clear();
      }
    });
  }

  @override
  void dispose() {
    _login.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _subScaffold(
      title: 'Отключить пользователя',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionTitle('Отключить пользователя'),
          _hintText(
              'Пользователь будет немедленно выброшен из системы и не сможет '
              'войти снова.'),
          TextField(
            controller: _login,
            style: const TextStyle(color: _text, fontSize: 15),
            decoration: _dec('Логин пользователя'),
          ),
          const SizedBox(height: 14),
          _SaveButton(
            label: 'Отключить',
            busy: _busy,
            color: _danger,
            onPressed: _save,
          ),
          _StatusLine(_status, isError: _statusErr),
        ],
      ),
    );
  }
}

// ── Включить пользователя (admin) ─────────────────────────────────────────────

class _EnableUserScreen extends StatefulWidget {
  const _EnableUserScreen();
  @override
  State<_EnableUserScreen> createState() => _EnableUserScreenState();
}

class _EnableUserScreenState extends State<_EnableUserScreen> {
  final _login = TextEditingController();
  bool _busy = false;
  String _status = '';
  bool _statusErr = false;

  Future<void> _save() async {
    final target = _login.text.trim();
    setState(() {
      _status = '';
      _statusErr = false;
    });
    if (target.isEmpty) {
      setState(() {
        _statusErr = true;
        _status = 'Введите логин пользователя';
      });
      return;
    }
    setState(() => _busy = true);
    final res = await ApiService.adminEnableUser(target);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (res['error'] != null) {
        _statusErr = true;
        _status = res['error'].toString();
      } else {
        _statusErr = false;
        _status = 'Пользователь «$target» включён';
        _login.clear();
      }
    });
  }

  @override
  void dispose() {
    _login.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _subScaffold(
      title: 'Включить пользователя',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionTitle('Включить пользователя'),
          _hintText('Разрешает пользователю снова входить в систему.'),
          TextField(
            controller: _login,
            style: const TextStyle(color: _text, fontSize: 15),
            decoration: _dec('Логин пользователя'),
          ),
          const SizedBox(height: 14),
          _SaveButton(
            label: 'Включить',
            busy: _busy,
            color: _success,
            onPressed: _save,
          ),
          _StatusLine(_status, isError: _statusErr),
        ],
      ),
    );
  }
}
