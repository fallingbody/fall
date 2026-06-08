import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:go_router/go_router.dart';

import 'screens/auth_wrapper.dart';
import 'screens/chat_screen.dart';
import 'services/local_db_service.dart';
import 'screens/calendar_screen.dart';
import 'screens/memories_screen.dart';
import 'screens/call_screen.dart';
import 'screens/achievements_screen.dart';
import 'screens/games_screen.dart';
import 'screens/settings_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Load environment variables
  await dotenv.load(fileName: ".env").catchError((_) {
    // Ignore error if .env is not found yet
  });

  // Initialize Supabase if keys are present
  final supabaseUrl = dotenv.env['SUPABASE_URL'];
  final supabaseAnonKey = dotenv.env['SUPABASE_ANON_KEY'];
  
  if (supabaseUrl != null && supabaseUrl.isNotEmpty && supabaseAnonKey != null && supabaseAnonKey.isNotEmpty) {
    await Supabase.initialize(
      url: supabaseUrl,
      anonKey: supabaseAnonKey,
    );
  }

  // Initialize local database
  await LocalDbService().init();

  runApp(const LdrApp());
}

final GoRouter _router = GoRouter(
  initialLocation: '/',
  routes: <RouteBase>[
    GoRoute(
      path: '/',
      builder: (BuildContext context, GoRouterState state) {
        return const AuthWrapper();
      },
    ),
    GoRoute(
      path: '/chat',
      builder: (BuildContext context, GoRouterState state) {
        final conn = state.extra as Map<String, dynamic>?;
        return ChatScreen(connection: conn);
      },
    ),
    GoRoute(
      path: '/calendar',
      builder: (BuildContext context, GoRouterState state) {
        return const CalendarScreen();
      },
    ),
    GoRoute(
      path: '/memories',
      builder: (BuildContext context, GoRouterState state) {
        return const MemoriesScreen();
      },
    ),
    GoRoute(
      path: '/call',
      builder: (BuildContext context, GoRouterState state) {
        return const CallScreen();
      },
    ),
    GoRoute(
      path: '/achievements',
      builder: (BuildContext context, GoRouterState state) {
        return const AchievementsScreen();
      },
    ),
    GoRoute(
      path: '/games',
      builder: (BuildContext context, GoRouterState state) {
        return const GamesScreen();
      },
    ),
    GoRoute(
      path: '/settings',
      builder: (BuildContext context, GoRouterState state) {
        return const SettingsScreen();
      },
    ),
  ],
);

class LdrApp extends StatelessWidget {
  const LdrApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'fall',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.black, brightness: Brightness.light),
        useMaterial3: true,
        textTheme: GoogleFonts.outfitTextTheme(Theme.of(context).textTheme),
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.black, brightness: Brightness.dark),
        useMaterial3: true,
        textTheme: GoogleFonts.outfitTextTheme(ThemeData.dark().textTheme),
      ),
      themeMode: ThemeMode.system,
      routerConfig: _router,
    );
  }
}
