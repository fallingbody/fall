import 'package:flutter/material.dart';
import 'package:flutter_chat_ui/flutter_chat_ui.dart';
import 'package:flutter_chat_types/flutter_chat_types.dart' as types;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

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
  
  @override
  void initState() {
    super.initState();
    _initUsers();
    _checkSupabase();
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
      final client = Supabase.instance.client;
      if (mounted) {
        setState(() {});
      }
      _listenToMessages(client);
    } catch (e) {
      debugPrint('Error configuring Supabase stream: $e');
    }
  }

  void _listenToMessages(SupabaseClient client) {
    client
        .from('messages')
        .stream(primaryKey: ['id'])
        .order('created_at', ascending: false) // flutter_chat_ui wants newest first
        .listen((List<Map<String, dynamic>> data) {
      
      // Filter strictly for this connection (messages sent by me to them, or them to me)
      final filteredData = data.where((row) => 
          (row['author_id'] == _user.id && row['receiver_id'] == _partner.id) || 
          (row['author_id'] == _partner.id && row['receiver_id'] == _user.id)).toList();

      final mappedMessages = filteredData.map((row) {
        types.Status msgStatus = types.Status.sent;
        if (row['status'] == 'seen') {
          msgStatus = types.Status.seen;
        } else if (row['status'] == 'delivered') {
          msgStatus = types.Status.delivered;
        }

        // Convert the Postgres timestamp to UTC securely so chat UI maps it to local correctly
        String createdAtStr = row['created_at'] as String;
        if (!createdAtStr.endsWith('Z')) {
          createdAtStr += 'Z'; // Force UTC parsing if Supabase dropped the Z
        }
        final dt = DateTime.parse(createdAtStr).toUtc();

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
    });
  }

  void _handleSendPressed(types.PartialText message) async {
    try {
      await Supabase.instance.client.from('messages').insert({
        'id': const Uuid().v4(),
        'author_id': _user.id,
        'receiver_id': _partner.id,
        'text': message.text,
        'status': 'sent',
        // Send strictly as UTC to sync globally
        'created_at': DateTime.now().toUtc().toIso8601String(),
      });
    } catch (e) {
      debugPrint('Error sending message: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to send message')),
        );
      }
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
                          Text('Online', style: TextStyle(fontSize: 12, color: Colors.green.shade600)),
                        ],
                      ),
                      const Spacer(),
                      IconButton(icon: const Icon(Icons.videocam, color: Colors.blue), onPressed: () {}),
                      IconButton(icon: const Icon(Icons.call, color: Colors.green), onPressed: () {}),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.start,
                    children: [
                      _buildHeaderIcon(Icons.battery_charging_full, '85%', Colors.green, isDark),
                      const SizedBox(width: 8),
                      _buildHeaderIcon(Icons.location_on, '1.2km', Colors.redAccent, isDark),
                      const SizedBox(width: 8),
                      _buildHeaderIcon(Icons.wb_sunny, '22°C', Colors.orange, isDark),
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
