import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'screens/login_screen.dart';
import 'screens/main_screen.dart';
import 'services/settings_service.dart';
import 'services/api_service.dart';
import 'services/push_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Загружаем клиентские настройки (анимация фона) до первого кадра,
  // чтобы фон сразу отрисовался в нужном состоянии.
  await SettingsService.instance.loadLocal();

  // Firebase + push. Оборачиваем в try: если google-services.json не добавлен
  // или FCM недоступен — приложение всё равно стартует, просто без пушей.
  try {
    await Firebase.initializeApp();
    FirebaseMessaging.onBackgroundMessage(firebaseBackgroundHandler);
    await PushService.instance.init();
  } catch (_) {}

  // Пытаемся восстановить сохранённую сессию. Если токен валиден (или нет сети,
  // но токен есть) — стартуем сразу с главного экрана, минуя экран входа.
  final loggedIn = await ApiService.restoreSession();

  runApp(OshinoApp(loggedIn: loggedIn));
}

class OshinoApp extends StatelessWidget {
  final bool loggedIn;
  const OshinoApp({super.key, this.loggedIn = false});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Oshino',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0d0d0d),
      ),
      initialRoute: loggedIn ? '/main' : '/login',
      routes: {
        '/login': (_) => const LoginScreen(),
        '/main': (_) => const MainScreen(),
      },
    );
  }
}
