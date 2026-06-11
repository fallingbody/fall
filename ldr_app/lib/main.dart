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
import 'screens/global_call_overlay.dart';
import 'services/call_state.dart';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'package:flutter_callkit_incoming/entities/call_event.dart';
import 'package:flutter_callkit_incoming/entities/call_kit_params.dart';
import 'package:flutter_callkit_incoming/entities/android_params.dart';
import 'package:flutter_callkit_incoming/entities/ios_params.dart';
import 'firebase_options.dart';
import 'screens/video_call_screen.dart';

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();
final Map<String, bool> activeCallsVideoStatus = {};

@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  debugPrint("Handling a background message: ${message.messageId}");

  final data = message.data;
  if (data['type'] == 'CALL_INVITE') {
    final callerName = data['caller_name'] ?? 'Partner';
    final roomId = data['id'] ?? '';
    final text = data['text']?.toString() ?? '';
    final isVideo = text.startsWith('CALL_INVITE_VIDEO:');
    
    activeCallsVideoStatus[roomId] = isVideo;

    final callKitParams = CallKitParams(
      id: roomId, // Use roomId directly so actionCallAccept has it
      nameCaller: callerName,
      appName: 'fall',
      handle: isVideo ? 'Video Call' : 'Audio Call',
      type: isVideo ? 1 : 0, // 0 = audio, 1 = video
      duration: 45000,
      extra: <String, dynamic>{'roomId': roomId, 'isVideo': isVideo},
      android: const AndroidParams(
        isCustomNotification: true,
        isShowLogo: false,
        ringtonePath: 'system_ringtone_default',
        backgroundColor: '#E91E63', // Pinkish
        actionColor: '#4CAF50',
      ),
      ios: IOSParams(
        iconName: 'CallKitLogo',
        handleType: 'generic',
        supportsVideo: isVideo,
        maximumCallGroups: 1,
        maximumCallsPerCallGroup: 1,
        audioSessionMode: 'default',
        audioSessionActive: true,
        audioSessionPreferredSampleRate: 44100.0,
        audioSessionPreferredIOBufferDuration: 0.005,
        supportsDTMF: true,
        supportsHolding: false,
        supportsGrouping: false,
        supportsUngrouping: false,
        ringtonePath: 'system_ringtone_default',
      ),
    );
    await FlutterCallkitIncoming.showCallkitIncoming(callKitParams);
  }
}

void _setupGlobalCallKitListener() {
  FlutterCallkitIncoming.onEvent.listen((CallEvent? event) {
    if (event == null) return;
    if (event is CallEventActionCallAccept) {
      final roomId = event.id; // Correctly mapped to roomId
      final isVideo = activeCallsVideoStatus[roomId] ?? true;
      final callerName = 'Partner'; // Extracted from DB later if needed
      
      globalCallState.value = CallData(
        roomId: roomId,
        callerName: callerName,
        isVideo: isVideo,
        isCaller: false, // I am accepting, so I am not the caller
      );
    }
  });
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Load environment variables
  await dotenv.load(fileName: ".env").catchError((_) {
    // Ignore error if .env is not found yet
  });

  // Initialize Firebase
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

  // Initialize Supabase if keys are present
  final supabaseUrl = dotenv.env['SUPABASE_URL'];
  final supabaseAnonKey = dotenv.env['SUPABASE_ANON_KEY'];
  
  if (supabaseUrl != null && supabaseUrl.isNotEmpty && supabaseAnonKey != null && supabaseAnonKey.isNotEmpty) {
    await Supabase.initialize(
      url: supabaseUrl,
      anonKey: supabaseAnonKey,
    );
  }

  // Setup CallKit listener globally
  _setupGlobalCallKitListener();

  // Initialize local database
  await LocalDbService().init();

  runApp(const LdrApp());
}

final GoRouter _router = GoRouter(
  navigatorKey: navigatorKey,
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
      builder: (context, child) {
        return Stack(
          children: [
            if (child != null) child,
            const GlobalCallOverlay(),
          ],
        );
      },
    );
  }
}
