import 'package:flutter/material.dart';
import 'screens/login_screen.dart';
import 'screens/main_screen.dart';
import 'services/settings_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Загружаем клиентские настройки (анимация фона) до первого кадра,
  // чтобы фон сразу отрисовался в нужном состоянии.
  await SettingsService.instance.loadLocal();
  runApp(const OshinoApp());
}

class OshinoApp extends StatelessWidget {
  const OshinoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Oshino',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0d0d0d),
      ),
      initialRoute: '/login',
      routes: {
        '/login': (_) => const LoginScreen(),
        '/main': (_) => const MainScreen(),
      },
    );
  }
}
