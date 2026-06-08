import 'package:flutter/material.dart';

import 'tabs/engage_tab.dart';
import 'tabs/tasks_tab.dart';
import 'tabs/game_tab.dart';
import 'tabs/account_tab.dart';
import 'partner_search_screen.dart';
import '../services/status_service.dart';

import 'package:supabase_flutter/supabase_flutter.dart';
import '../services/local_db_service.dart';
import 'video_call_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _currentIndex = 0;
  RealtimeChannel? _globalChannel;
  final Set<String> _processedCalls = {};

  @override
  void initState() {
    super.initState();
    StatusService().startSync();
    _listenForCalls();
  }

  void _listenForCalls() {
    final myId = Supabase.instance.client.auth.currentUser?.id;
    if (myId == null) return;

    _globalChannel = Supabase.instance.client.channel('user_$myId');
    _globalChannel!.onBroadcast(
      event: 'message',
      callback: (payload) {
        final row = Map<String, dynamic>.from(payload);
        
        // Always save incoming messages to local disk immediately!
        if (row['receiver_id'] == myId) {
          LocalDbService().saveMessage(row);

          // Handle incoming calls
          if (row['text'].toString().startsWith('CALL_INVITE_')) {
            String createdAtStr = row['created_at'].toString();
            if (!createdAtStr.endsWith('Z') && !createdAtStr.contains('+')) {
              createdAtStr += 'Z';
            }
            final createdAt = DateTime.parse(createdAtStr).toUtc();
            
            if (DateTime.now().toUtc().difference(createdAt).inSeconds < 45) {
              if (!_processedCalls.contains(row['id'])) {
                _processedCalls.add(row['id']);
                _showIncomingCall(row);
              }
            }
          }
        }
      }
    ).subscribe();
  }

  void _showIncomingCall(Map<String, dynamic> row) async {
    final isVideo = row['text'].toString().startsWith('CALL_INVITE_VIDEO:');
    final parts = row['text'].toString().split(':');
    if (parts.length < 2) return;
    final roomId = parts[1];
    
    // Fetch caller profile
    String callerName = 'Partner';
    try {
      final callerRes = await Supabase.instance.client.from('profiles').select('full_name, username').eq('id', row['author_id']).single();
      callerName = callerRes['full_name'] ?? callerRes['username'] ?? 'Partner';
    } catch (_) {}

    if (!mounted) return;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return AlertDialog(
          backgroundColor: Colors.grey.shade900,
          title: Text('Incoming ${isVideo ? "Video" : "Audio"} Call', style: const TextStyle(color: Colors.white)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.ring_volume, size: 48, color: Colors.pinkAccent),
              const SizedBox(height: 16),
              Text('$callerName is calling you...', style: const TextStyle(color: Colors.white70, fontSize: 16)),
            ],
          ),
          actionsAlignment: MainAxisAlignment.spaceEvenly,
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Decline', style: TextStyle(color: Colors.redAccent, fontSize: 16)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
              onPressed: () {
                Navigator.pop(context);
                Navigator.push(context, MaterialPageRoute(builder: (context) => VideoCallScreen(
                  roomName: roomId,
                  participantName: 'Me',
                  isVideoCall: isVideo,
                )));
              },
              child: const Text('Accept', style: TextStyle(color: Colors.white, fontSize: 16)),
            ),
          ],
        );
      }
    );
  }

  @override
  void dispose() {
    _globalChannel?.unsubscribe();
    StatusService().stopSync();
    super.dispose();
  }

  final List<Widget> _tabs = const [
    EngageTab(),
    TasksTab(),
    GameTab(),
    AccountTab(),
  ];

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: isDark ? Colors.black : Colors.white,
      appBar: AppBar(
        title: Text(
          'fall',
          style: TextStyle(
            fontSize: 28,
            fontWeight: FontWeight.w800,
            letterSpacing: -1.5,
            color: isDark ? Colors.white : Colors.black,
          ),
        ),
        backgroundColor: isDark ? Colors.black : Colors.white,
        elevation: 0,
        actions: [
          IconButton(
            icon: Icon(Icons.favorite_border, color: isDark ? Colors.white : Colors.black),
            onPressed: () {
              Navigator.push(context, MaterialPageRoute(builder: (context) => const PartnerSearchScreen()));
            },
          ),
        ],
      ),
      body: _tabs[_currentIndex],
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: isDark ? Colors.grey.shade900 : Colors.grey.shade200)),
        ),
        child: BottomNavigationBar(
          currentIndex: _currentIndex,
          onTap: (index) => setState(() => _currentIndex = index),
          type: BottomNavigationBarType.fixed,
          backgroundColor: isDark ? Colors.black : Colors.white,
          selectedItemColor: isDark ? Colors.white : Colors.black,
          unselectedItemColor: isDark ? Colors.grey.shade800 : Colors.grey,
          showSelectedLabels: false,
          showUnselectedLabels: false,
          elevation: 0,
          items: const [
            // Placeholder for SVGs. Using Material Icons that closely match requested SVGs
            BottomNavigationBarItem(
              icon: Icon(Icons.maps_ugc_outlined, size: 28),
              activeIcon: Icon(Icons.maps_ugc, size: 28),
              label: 'Engage',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.dashboard_outlined, size: 28),
              activeIcon: Icon(Icons.dashboard, size: 28),
              label: 'Tasks',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.sports_esports_outlined, size: 28),
              activeIcon: Icon(Icons.sports_esports, size: 28),
              label: 'Game',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.person_outline, size: 28),
              activeIcon: Icon(Icons.person, size: 28),
              label: 'Account',
            ),
          ],
        ),
      ),
    );
  }
}
