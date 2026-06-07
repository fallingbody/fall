import 'package:flutter/material.dart';
import 'package:flutter_chat_ui/flutter_chat_ui.dart';
import 'package:flutter_chat_types/flutter_chat_types.dart' as types;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  List<types.Message> _messages = [];
  
  late types.User _user;
  late types.User _partner;
  
  bool _isSupabaseConfigured = true;

  @override
  void initState() {
    super.initState();
    _initUsers();
    _checkSupabase();
  }

  void _initUsers() {
    final currentUserId = Supabase.instance.client.auth.currentUser?.id ?? 'user_1_id';
    _user = types.User(id: currentUserId, firstName: 'Me');
    _partner = const types.User(id: 'partner_id', firstName: 'Partner');
  }

  void _checkSupabase() async {
    try {
      final client = Supabase.instance.client;
      final currentUserId = client.auth.currentUser?.id;
      
      if (currentUserId != null) {
        final res = await client.from('profiles').select('partner_id').eq('id', currentUserId).maybeSingle();
        if (res != null && res['partner_id'] != null) {
          _partner = types.User(id: res['partner_id'], firstName: 'Partner');
        }
      }

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
      
      // Filter out messages that don't belong to this pair
      final filteredData = data.where((row) => 
          row['author_id'] == _user.id || row['author_id'] == _partner.id).toList();

      final mappedMessages = filteredData.map((row) {
        return types.TextMessage(
          id: row['id'],
          author: row['author_id'] == _user.id ? _user : _partner,
          createdAt: DateTime.parse(row['created_at']).millisecondsSinceEpoch,
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
        'text': message.text,
        'created_at': DateTime.now().toIso8601String(),
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

  Widget _buildInfoCard(IconData icon, String title, String value, Color iconColor) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Row(
        children: [
          Icon(icon, color: iconColor, size: 20),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
              Text(value, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
            ],
          ),
        ],
      ),
    );
  }

  void _showPartnerDashboard(BuildContext context) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (context) {
        return Container(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Partner Status', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 16),
              
              // Status & Battery Row
              Row(
                children: [
                  Expanded(child: _buildInfoCard(Icons.circle, 'Status', 'Online', Colors.green)),
                  const SizedBox(width: 12),
                  Expanded(child: _buildInfoCard(Icons.battery_charging_full, 'Battery', '85% Charging', Colors.green)),
                ],
              ),
              const SizedBox(height: 16),
              
              // Location Map Placeholder
              Container(
                height: 120,
                decoration: BoxDecoration(
                  color: Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.grey.shade300),
                ),
                child: Stack(
                  children: [
                    const Center(child: Icon(Icons.map, size: 50, color: Colors.black12)),
                    Positioned(
                      bottom: 12,
                      left: 16,
                      child: Row(
                        children: [
                          const Icon(Icons.location_on, color: Colors.redAccent),
                          const SizedBox(width: 8),
                          Text('Downtown Cafe, New York', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey.shade800)),
                        ],
                      ),
                    )
                  ],
                ),
              ),
              const SizedBox(height: 24),
              
              // Send Home Screen Widget Pop-up
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  icon: const Icon(Icons.send_to_mobile, color: Colors.white),
                  label: const Text('Send Home Screen Pop-up', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  onPressed: () {
                    Navigator.pop(context); // close sheet
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Widget sent to partner!')));
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        title: InkWell(
          onTap: () => _showPartnerDashboard(context),
          child: Row(
            children: [
              const CircleAvatar(
                radius: 18,
                backgroundColor: Colors.pinkAccent,
                child: Icon(Icons.favorite, color: Colors.white, size: 18),
              ),
              const SizedBox(width: 10),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('My Love ❤️', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  Text('Online', style: TextStyle(fontSize: 12, color: Colors.green.shade600)),
                ],
              ),
            ],
          ),
        ),
        backgroundColor: Colors.white,
        foregroundColor: Colors.black,
        elevation: 1,
      ),
      body: Chat(
        messages: _messages,
        onSendPressed: _handleSendPressed,
        user: _user,
        theme: DefaultChatTheme(
          primaryColor: isDark ? Colors.white : Colors.black,
          backgroundColor: isDark ? Colors.black : Colors.white,
          inputBackgroundColor: isDark ? Colors.grey.shade900 : const Color(0xFFF5F5F5),
          inputTextColor: isDark ? Colors.white : Colors.black,
          sendButtonIcon: Icon(Icons.send, color: isDark ? Colors.white : Colors.black),
        ),
      ),
    );
  }
}
