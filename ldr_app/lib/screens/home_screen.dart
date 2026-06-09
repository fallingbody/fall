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
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'package:flutter_callkit_incoming/entities/entities.dart';
import 'package:flutter_callkit_incoming/entities/ios_params.dart';
import '../main.dart';
import 'dart:async';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _currentIndex = 0;
  StreamSubscription<List<Map<String, dynamic>>>? _messageSub;
  StreamSubscription<List<Map<String, dynamic>>>? _requestsSub;
  final Set<String> _processedCalls = {};
  final Set<String> _processedMessages = {};
  bool _hasPendingRequests = false;

  @override
  void initState() {
    super.initState();
    StatusService().startSync();
    _listenForCalls();
    _listenForRequests();
    _setupPushNotifications();
  }

  void _listenForRequests() {
    final myId = Supabase.instance.client.auth.currentUser?.id;
    if (myId == null) return;

    _requestsSub = Supabase.instance.client
        .from('connection_requests')
        .stream(primaryKey: ['id'])
        .listen((data) {
      if (!mounted) return;
      final hasPending = data.any((row) => row['receiver_id'] == myId && row['status'] == 'pending');
      setState(() {
        _hasPendingRequests = hasPending;
      });
    });
  }

  Future<void> _setupPushNotifications() async {
    final messaging = FirebaseMessaging.instance;
    await messaging.requestPermission();
    final token = await messaging.getToken();
    if (token != null) {
      final myId = Supabase.instance.client.auth.currentUser?.id;
      if (myId != null) {
        try {
          await Supabase.instance.client.from('profiles').update({'fcm_token': token}).eq('id', myId);
        } catch (e) {
          debugPrint("Note: fcm_token column might not exist yet: $e");
        }
      }
    }

    FirebaseMessaging.onMessage.listen((RemoteMessage message) async {
      // Handle foreground notifications if needed
      final data = message.data;
      if (data['type'] == 'CALL_INVITE') {
        final callerName = data['caller_name'] ?? 'Partner';
        final roomId = data['id'] ?? '';
        final text = data['text']?.toString() ?? '';
        final isVideo = text.startsWith('CALL_INVITE_VIDEO:');
        
        activeCallsVideoStatus[roomId] = isVideo;

        final callKitParams = CallKitParams(
          id: roomId,
          nameCaller: callerName,
          appName: 'fall',
          handle: isVideo ? 'Video Call' : 'Audio Call',
          type: isVideo ? 1 : 0,
          duration: 45000,
          extra: <String, dynamic>{'roomId': roomId, 'isVideo': isVideo},
          android: const AndroidParams(
            isCustomNotification: true,
            isShowLogo: false,
            ringtonePath: 'system_ringtone_default',
            backgroundColor: '#E91E63',
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
    });
  }

  void _listenForCalls() {
    final myId = Supabase.instance.client.auth.currentUser?.id;
    if (myId == null) return;

    _messageSub = Supabase.instance.client
        .from('messages')
        .stream(primaryKey: ['id'])
        .listen((data) async {
      for (var row in data) {
        if (row['receiver_id'] == myId) {
          final msgId = row['id'];

          if (_processedMessages.contains(msgId)) {
            // Already processed this message in a previous stream event.
            // Just try to ensure it's deleted and skip processing.
            try {
              await Supabase.instance.client.from('messages').delete().eq('id', msgId);
            } catch (_) {}
            continue;
          }

          _processedMessages.add(msgId);
          final text = row['text'].toString();

          // 1. Check if it's a control message (Receipt or Sync)
          if (text.startsWith('RECEIPT_DELIVERED:')) {
            final targetMsgId = text.substring(18);
            await LocalDbService().updateMessageStatus(targetMsgId, 'delivered');
          } else if (text.startsWith('RECEIPT_SEEN:')) {
            final targetMsgId = text.substring(13);
            await LocalDbService().updateMessageStatus(targetMsgId, 'seen');
          } else if (text.startsWith('DELETE_MESSAGE:')) {
            final targetMsgId = text.substring(15);
            await LocalDbService().deleteMessage(targetMsgId);
          } else if (text.startsWith('EDIT_MESSAGE:')) {
            final payload = text.substring(13);
            final parts = payload.split('|:');
            if (parts.length == 2) {
              await LocalDbService().editMessageText(parts[0], parts[1]);
            }
          } else {
            // Handle incoming calls
            if (text.startsWith('CALL_INVITE_')) {
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

            // Handle Image Download (Fire and forget, or await)
            if (text.startsWith('[IMAGE]:')) {
              await _processIncomingImage(row);
            } else {
              // Save standard text/call message
              row['status'] = 'delivered'; // mark my local copy as delivered
              await LocalDbService().saveMessage(row);
            }

            // Send back a Delivered receipt to the author!
            try {
              await Supabase.instance.client.from('messages').insert({
                'id': const Uuid().v4(),
                'author_id': myId,
                'receiver_id': row['author_id'],
                'text': 'RECEIPT_DELIVERED:${row['id']}',
                'status': 'sent',
                'created_at': DateTime.now().toUtc().toIso8601String(),
              });
            } catch (e) {
              debugPrint('Failed to send delivered receipt: $e');
            }
          }

          // Always Dequeue! Delete from Supabase permanent storage
          try {
            await Supabase.instance.client.from('messages').delete().eq('id', row['id']);
          } catch (e) {
            debugPrint('Error deleting queued message: $e');
          }
        }
      }
    });
  }

  Future<void> _processIncomingImage(Map<String, dynamic> row) async {
    final url = row['text'].toString().substring(8); // remove '[IMAGE]:'
    
    try {
      final response = await http.get(Uri.parse(url));
      if (response.statusCode == 200) {
        final dir = await getApplicationDocumentsDirectory();
        final fileName = row['id'] + '.jpg';
        final localPath = '\${dir.path}/\$fileName';
        final file = File(localPath);
        await file.writeAsBytes(response.bodyBytes);
        
        // Update the row text to point to the local file
        row['text'] = '[LOCAL_IMAGE]:\$localPath';
        await LocalDbService().saveMessage(row);

        // Delete the cloud file from the drop-box
        await Supabase.instance.client.storage.from('chat_media').remove([fileName]);
      } else {
         await LocalDbService().saveMessage(row); // Save original if failed
      }
    } catch (e) {
      debugPrint('Error downloading image: \$e');
      await LocalDbService().saveMessage(row);
    }
  }

  void _showIncomingCall(Map<String, dynamic> row) async {
    final isVideo = row['text'].toString().startsWith('CALL_INVITE_VIDEO:');
    final parts = row['text'].toString().split(':');
    if (parts.length < 2) return;
    final roomId = parts[1];
    
    // Save to global map for listener
    activeCallsVideoStatus[roomId] = isVideo;
    
    // Fetch caller profile
    String callerName = 'Partner';
    try {
      final callerRes = await Supabase.instance.client.from('profiles').select('full_name, username').eq('id', row['author_id']).single();
      callerName = callerRes['full_name'] ?? callerRes['username'] ?? 'Partner';
    } catch (_) {}

    CallKitParams callKitParams = CallKitParams(
      id: roomId, // Send the explicit roomId!
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
        backgroundColor: '#E91E63',
        actionColor: '#4CAF50',
      ),
      ios: IOSParams(
        iconName: 'CallKitLogo',
        handleType: 'generic',
        supportsVideo: isVideo,
        maximumCallGroups: 2,
        maximumCallsPerCallGroup: 1,
        audioSessionMode: 'default',
        audioSessionActive: true,
        audioSessionPreferredSampleRate: 44100.0,
        audioSessionPreferredIOBufferDuration: 0.005,
        supportsDTMF: true,
        supportsHolding: true,
        supportsGrouping: false,
        supportsUngrouping: false,
        ringtonePath: 'system_ringtone_default',
      ),
    );

    await FlutterCallkitIncoming.showCallkitIncoming(callKitParams);
  }

  @override
  void dispose() {
    _messageSub?.cancel();
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
            icon: Badge(
              isLabelVisible: _hasPendingRequests,
              backgroundColor: Colors.red,
              child: Icon(Icons.favorite_border, color: isDark ? Colors.white : Colors.black),
            ),
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
