import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_chat_ui/flutter_chat_ui.dart';
import 'package:flutter_chat_types/flutter_chat_types.dart' as types;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'video_call_screen.dart';
import 'map_screen.dart';
import '../services/local_db_service.dart';
import 'package:image_picker/image_picker.dart';
import 'dart:io';

class ChatScreen extends StatefulWidget {
  final Map<String, dynamic>? connection;

  const ChatScreen({super.key, this.connection});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  List<types.Message> _messages = [];
  
  late types.User _user;
  late types.User _partner;
  StreamSubscription? _localDbSub;

  // Real-time status data
  Timer? _statusTimer;
  Map<String, dynamic>? _partnerProfile;
  double? _myLat;
  double? _myLon;
  String _distanceStr = 'Calculating...';
  
  @override
  void initState() {
    super.initState();
    _initUsers();
    _checkSupabase();
    _startStatusTracking();
  }

  @override
  void dispose() {
    _statusTimer?.cancel();
    _localDbSub?.cancel();
    super.dispose();
  }

  void _startStatusTracking() async {
    _fetchPartnerProfile();
    _fetchMyLocation();
    
    _statusTimer = Timer.periodic(const Duration(seconds: 30), (timer) {
      _fetchPartnerProfile();
    });
  }

  void _fetchMyLocation() async {
    try {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) return;
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.whileInUse || permission == LocationPermission.always) {
        Position position = await Geolocator.getCurrentPosition(locationSettings: const LocationSettings(accuracy: LocationAccuracy.low));
        _myLat = position.latitude;
        _myLon = position.longitude;
        _calculateDistance();
      }
    } catch (e) {
      debugPrint('Error fetching my location: $e');
    }
  }

  void _fetchPartnerProfile() async {
    try {
      final res = await Supabase.instance.client
          .from('profiles')
          .select('last_seen, battery_level, battery_state, latitude, longitude, weather_temp, weather_condition')
          .eq('id', _partner.id)
          .maybeSingle();
      if (res != null && mounted) {
        setState(() {
          _partnerProfile = res;
          _calculateDistance();
        });
      }
    } catch (e) {
      debugPrint('Error fetching partner profile: $e');
    }
  }

  void _calculateDistance() {
    if (_myLat != null && _myLon != null && _partnerProfile != null) {
      final pLat = _partnerProfile!['latitude'];
      final pLon = _partnerProfile!['longitude'];
      if (pLat != null && pLon != null) {
        double distanceMeters = Geolocator.distanceBetween(_myLat!, _myLon!, pLat, pLon);
        setState(() {
          if (distanceMeters < 1000) {
            _distanceStr = '${distanceMeters.toStringAsFixed(0)}m away';
          } else {
            _distanceStr = '${(distanceMeters / 1000).toStringAsFixed(1)}km away';
          }
        });
      }
    }
  }

  void _openPartnerLocation() {
    if (_partnerProfile == null || _myLat == null || _myLon == null) return;
    final pLat = _partnerProfile!['latitude'];
    final pLon = _partnerProfile!['longitude'];
    if (pLat != null && pLon != null) {
      Navigator.push(context, MaterialPageRoute(builder: (context) => MapScreen(
        myLat: _myLat!,
        myLon: _myLon!,
        partnerLat: pLat,
        partnerLon: pLon,
        partnerName: _partner.firstName ?? 'Partner',
      )));
    }
  }

  void _initUsers() {
    final currentUserId = Supabase.instance.client.auth.currentUser?.id ?? 'user_1_id';
    _user = types.User(id: currentUserId, firstName: 'Me');
    
    if (widget.connection != null) {
      final profile = widget.connection!['profile'];
      _partner = types.User(id: widget.connection!['other_user_id'], firstName: profile['full_name'] ?? profile['username'] ?? 'Unknown');
    } else {
      _partner = const types.User(id: 'partner_id', firstName: 'Partner');
    }
  }

  void _checkSupabase() async {
    try {
      if (mounted) {
        setState(() {});
      }
      _listenToMessages();
    } catch (e) {
      debugPrint('Error configuring Supabase stream: $e');
    }
  }

  void _loadLocalMessages() {
    final localData = LocalDbService().getMessagesForConnection(_user.id, _partner.id);
    
    final mappedMessages = localData.map((row) {
      types.Status msgStatus = types.Status.sent;
      if (row['status'] == 'seen') {
        msgStatus = types.Status.seen;
      } else if (row['status'] == 'delivered') {
        msgStatus = types.Status.delivered;
      }

      String createdAtStr = row['created_at'].toString();
      if (!createdAtStr.endsWith('Z') && !createdAtStr.contains('+')) {
        createdAtStr += 'Z';
      }
      final dt = DateTime.parse(createdAtStr).toUtc();

      if (row['text'].toString().startsWith('CALL_INVITE_')) {
        return types.CustomMessage(
          id: row['id'],
          author: row['author_id'] == _user.id ? _user : _partner,
          createdAt: dt.millisecondsSinceEpoch,
          status: msgStatus,
          metadata: {'type': 'call_invite'},
        );
      }

      if (row['text'].toString().startsWith('[LOCAL_IMAGE]:')) {
        final path = row['text'].toString().substring(14);
        return types.ImageMessage(
          id: row['id'],
          author: row['author_id'] == _user.id ? _user : _partner,
          createdAt: dt.millisecondsSinceEpoch,
          status: msgStatus,
          name: 'image.jpg',
          size: 1000,
          uri: 'file://$path',
        );
      }

      if (row['text'].toString().startsWith('[IMAGE]:')) {
        final url = row['text'].toString().substring(8);
        return types.ImageMessage(
          id: row['id'],
          author: row['author_id'] == _user.id ? _user : _partner,
          createdAt: dt.millisecondsSinceEpoch,
          status: msgStatus,
          name: 'image.jpg',
          size: 1000,
          uri: url,
        );
      }

      return types.TextMessage(
        id: row['id'],
        author: row['author_id'] == _user.id ? _user : _partner,
        createdAt: dt.millisecondsSinceEpoch,
        status: msgStatus,
        text: row['text'],
      );
    }).toList();

    if (mounted) {
      setState(() {
        _messages = mappedMessages;
      });
    }
  }

  void _listenToMessages() {
    _loadLocalMessages();

    // Listen to local DB changes (powered by the global home_screen daemon!)
    _localDbSub = LocalDbService().watchMessages().listen((event) {
      if (mounted) {
        _loadLocalMessages();
      }
    });
  }

  void _handleSendPressed(types.PartialText message) async {
    try {
      final msgData = {
        'id': const Uuid().v4(),
        'author_id': _user.id,
        'receiver_id': _partner.id,
        'text': message.text,
        'status': 'sent',
        'created_at': DateTime.now().toUtc().toIso8601String(),
      };

      // 1. Save to local disk immediately
      await LocalDbService().saveMessage(msgData);

      // 2. Insert into Supabase queue
      await Supabase.instance.client.from('messages').insert({
        'id': msgData['id'],
        'author_id': msgData['author_id'],
        'receiver_id': msgData['receiver_id'],
        'text': msgData['text'],
        'status': msgData['status'],
        'created_at': msgData['created_at'],
      });

      // 3. Update UI
      _loadLocalMessages();

    } catch (e) {
      debugPrint('Error sending message: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to send message')),
        );
      }
    }
  }

  void _handleAttachmentPressed() async {
    final picker = ImagePicker();
    final pickedFile = await picker.pickImage(source: ImageSource.gallery);
    if (pickedFile == null) return;

    final bytes = await pickedFile.readAsBytes();
    final fileExt = pickedFile.path.split('.').last;
    final msgId = const Uuid().v4();
    final fileName = '$msgId.$fileExt';

    try {
      // Upload to Supabase temporary drop-box bucket
      await Supabase.instance.client.storage.from('chat_media').uploadBinary(fileName, bytes);
      final publicUrl = Supabase.instance.client.storage.from('chat_media').getPublicUrl(fileName);

      final msgData = {
        'id': msgId,
        'author_id': _user.id,
        'receiver_id': _partner.id,
        'text': '[IMAGE]:$publicUrl',
        'status': 'sent',
        'created_at': DateTime.now().toUtc().toIso8601String(),
      };

      // 1. Save local copy for me so I don't download what I uploaded
      final localMsgData = Map<String, dynamic>.from(msgData);
      localMsgData['text'] = '[LOCAL_IMAGE]:${pickedFile.path}';
      await LocalDbService().saveMessage(localMsgData);

      // 2. Insert queue URL for partner
      await Supabase.instance.client.from('messages').insert(msgData);
      
      _loadLocalMessages();
    } catch (e) {
      debugPrint('Upload error: $e');
    }
  }

  Widget _buildHeaderIcon(IconData icon, String label, Color color, bool isDark) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: isDark ? Colors.grey.shade900 : Colors.grey.shade100,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: isDark ? Colors.grey.shade800 : Colors.grey.shade300),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 4),
          Text(label, style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: isDark ? Colors.grey.shade300 : Colors.grey.shade700)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // Use category from connection to determine icon/color if available
    String category = widget.connection?['category'] ?? 'friend';
    IconData icon;
    Color iconColor;
    if (category == 'partner') {
      icon = Icons.favorite;
      iconColor = Colors.pinkAccent;
    } else if (category == 'family') {
      icon = Icons.home;
      iconColor = Colors.orangeAccent;
    } else {
      icon = Icons.group;
      iconColor = Colors.blueAccent;
    }

    String onlineStatus = 'Offline';
    if (_partnerProfile != null && _partnerProfile!['last_seen'] != null) {
      final lastSeenStr = _partnerProfile!['last_seen'] as String;
      final lastSeen = DateTime.parse(lastSeenStr.endsWith('Z') ? lastSeenStr : '${lastSeenStr}Z').toLocal();
      final diff = DateTime.now().difference(lastSeen);
      if (diff.inMinutes < 3) {
        onlineStatus = 'Online';
      } else if (diff.inMinutes < 60) {
        onlineStatus = 'Seen ${diff.inMinutes}m ago';
      } else if (diff.inHours < 24) {
        onlineStatus = 'Seen ${diff.inHours}h ago';
      } else {
        onlineStatus = 'Seen ${diff.inDays}d ago';
      }
    }

    String batteryStr = '--%';
    IconData batteryIcon = Icons.battery_unknown;
    Color batteryColor = Colors.grey;
    if (_partnerProfile != null && _partnerProfile!['battery_level'] != null) {
      final level = _partnerProfile!['battery_level'] as int;
      final state = _partnerProfile!['battery_state'] as String?;
      batteryStr = '$level%';
      if (state == 'charging') {
        batteryIcon = Icons.battery_charging_full;
        batteryColor = Colors.green;
      } else if (level <= 20) {
        batteryIcon = Icons.battery_alert;
        batteryColor = Colors.red;
      } else {
        batteryIcon = Icons.battery_full;
        batteryColor = Colors.green;
      }
    }

    String weatherStr = '--°C';
    IconData weatherIcon = Icons.cloud;
    if (_partnerProfile != null && _partnerProfile!['weather_temp'] != null) {
      weatherStr = _partnerProfile!['weather_temp'];
      final weatherCondition = _partnerProfile!['weather_condition'] ?? 'Unknown';
      if (weatherCondition.toLowerCase().contains('sun') || weatherCondition.toLowerCase().contains('clear')) {
        weatherIcon = Icons.wb_sunny;
      } else if (weatherCondition.toLowerCase().contains('rain')) {
        weatherIcon = Icons.water_drop;
      } else {
        weatherIcon = Icons.cloud;
      }
    }

    return Scaffold(
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(100),
        child: AppBar(
          backgroundColor: isDark ? Colors.black : Colors.white,
          foregroundColor: isDark ? Colors.white : Colors.black,
          elevation: 1,
          flexibleSpace: SafeArea(
            child: Padding(
              padding: const EdgeInsets.only(top: 6.0, left: 50.0, right: 16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      CircleAvatar(
                        radius: 18,
                        backgroundColor: iconColor,
                        child: Icon(icon, color: Colors.white, size: 18),
                      ),
                      const SizedBox(width: 10),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(_partner.firstName ?? 'Unknown', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                          Text(onlineStatus, style: TextStyle(fontSize: 12, color: onlineStatus == 'Online' ? Colors.green.shade600 : Colors.grey.shade500)),
                        ],
                      ),
                      const Spacer(),
                      IconButton(
                        icon: SvgPicture.string(
                          '''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="24" height="24" fill="none" stroke="#2196F3" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polygon points="23 7 16 12 23 17 23 7"></polygon><rect x="1" y="5" width="15" height="14" rx="2" ry="2"></rect></svg>''',
                          width: 24,
                          height: 24,
                        ), 
                        onPressed: () async {
                          if (widget.connection == null) return;
                          
                          final callData = {
                            'id': const Uuid().v4(),
                            'author_id': _user.id,
                            'receiver_id': _partner.id,
                            'text': 'CALL_INVITE_VIDEO:${widget.connection!["connection_id"]}',
                            'status': 'sent',
                            'created_at': DateTime.now().toUtc().toIso8601String(),
                          };

                          await LocalDbService().saveMessage(callData);
                          await Supabase.instance.client.from('messages').insert(callData);
                          _loadLocalMessages();

                          if (context.mounted) {
                            Navigator.push(context, MaterialPageRoute(builder: (context) => VideoCallScreen(
                              roomName: widget.connection!['connection_id'],
                              participantName: _user.firstName ?? 'Me',
                            )));
                          }
                        }
                      ),
                      IconButton(
                        icon: SvgPicture.string(
                          '''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="24" height="24" fill="none" stroke="#4CAF50" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M22 16.92v3a2 2 0 0 1-2.18 2 19.79 19.79 0 0 1-8.63-3.07 19.5 19.5 0 0 1-6-6 19.79 19.79 0 0 1-3.07-8.67A2 2 0 0 1 4.11 2h3a2 2 0 0 1 2 1.72 12.84 12.84 0 0 0 .7 2.81 2 2 0 0 1-.45 2.11L8.09 9.91a16 16 0 0 0 6 6l1.27-1.27a2 2 0 0 1 2.11-.45 12.84 12.84 0 0 0 2.81.7A2 2 0 0 1 22 16.92z"></path></svg>''',
                          width: 24,
                          height: 24,
                        ), 
                        onPressed: () async {
                          if (widget.connection == null) return;
                          
                          final callData = {
                            'id': const Uuid().v4(),
                            'author_id': _user.id,
                            'receiver_id': _partner.id,
                            'text': 'CALL_INVITE_AUDIO:${widget.connection!["connection_id"]}',
                            'status': 'sent',
                            'created_at': DateTime.now().toUtc().toIso8601String(),
                          };

                          await LocalDbService().saveMessage(callData);
                          await Supabase.instance.client.from('messages').insert(callData);
                          _loadLocalMessages();

                          if (context.mounted) {
                            Navigator.push(context, MaterialPageRoute(builder: (context) => VideoCallScreen(
                              roomName: widget.connection!['connection_id'],
                              participantName: _user.firstName ?? 'Me',
                              isVideoCall: false,
                            )));
                          }
                        }
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.start,
                    children: [
                      _buildHeaderIcon(batteryIcon, batteryStr, batteryColor, isDark),
                      const SizedBox(width: 8),
                      InkWell(
                        onTap: _openPartnerLocation,
                        child: _buildHeaderIcon(Icons.location_on, _distanceStr, Colors.redAccent, isDark),
                      ),
                      const SizedBox(width: 8),
                      _buildHeaderIcon(weatherIcon, weatherStr, Colors.orange, isDark),
                    ],
                  )
                ],
              ),
            ),
          ),
        ),
      ),
      body: Chat(
        messages: _messages,
        onSendPressed: _handleSendPressed,
        onAttachmentPressed: _handleAttachmentPressed,
        user: _user,
        showUserAvatars: true,
        showUserNames: true,
        theme: DefaultChatTheme(
          primaryColor: Colors.pink, // Fixes white on white blending! Solid vibrant color!
          backgroundColor: isDark ? Colors.black : Colors.white,
          inputBackgroundColor: isDark ? Colors.grey.shade900 : const Color(0xFFF5F5F5),
          inputTextColor: isDark ? Colors.white : Colors.black,
          sendButtonIcon: Icon(Icons.send, color: isDark ? Colors.white : Colors.black),
          seenIcon: const Text('✓✓', style: TextStyle(color: Colors.blue, fontSize: 10)),
          deliveredIcon: const Text('✓✓', style: TextStyle(color: Colors.grey, fontSize: 10)),
        ),
      ),
    );
  }
}
