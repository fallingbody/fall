import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'home_screen.dart';

class PartnerSearchScreen extends StatefulWidget {
  const PartnerSearchScreen({super.key});

  @override
  State<PartnerSearchScreen> createState() => _PartnerSearchScreenState();
}

class _PartnerSearchScreenState extends State<PartnerSearchScreen> {
  final _searchController = TextEditingController();
  final _supabase = Supabase.instance.client;

  bool _isSearching = false;
  Map<String, dynamic>? _foundUser;
  List<dynamic> _incomingRequests = [];

  @override
  void initState() {
    super.initState();
    _fetchIncomingRequests();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _fetchIncomingRequests() async {
    final userId = _supabase.auth.currentUser?.id;
    if (userId == null) return;

    try {
      final res = await _supabase
          .from('connection_requests')
          .select('id, sender_id, status, profiles:sender_id ( username, full_name )')
          .eq('receiver_id', userId)
          .eq('status', 'pending');
      
      setState(() {
        _incomingRequests = res;
      });
    } catch (e) {
      debugPrint('Error fetching requests: $e');
    }
  }

  Future<void> _searchUser() async {
    final username = _searchController.text.trim();
    if (username.isEmpty) return;

    setState(() {
      _isSearching = true;
      _foundUser = null;
    });

    try {
      final res = await _supabase
          .from('profiles')
          .select('id, username, full_name')
          .eq('username', username)
          .maybeSingle();
      
      setState(() {
        _foundUser = res;
      });
      
      if (res == null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No user found with that username')),
        );
      }
    } catch (e) {
      debugPrint('Search error: $e');
    } finally {
      setState(() {
        _isSearching = false;
      });
    }
  }

  Future<void> _sendRequest(String receiverId) async {
    final senderId = _supabase.auth.currentUser?.id;
    if (senderId == null) return;

    try {
      await _supabase.from('connection_requests').insert({
        'sender_id': senderId,
        'receiver_id': receiverId,
        'status': 'pending'
      });
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Request sent successfully!')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to send request')),
        );
      }
    }
  }

  Future<void> _acceptRequest(String requestId, String senderId) async {
    final myId = _supabase.auth.currentUser?.id;
    if (myId == null) return;

    try {
      // 1. Update request status
      await _supabase
          .from('connection_requests')
          .update({'status': 'accepted'})
          .eq('id', requestId);
      
      // 2. Update my profile
      await _supabase
          .from('profiles')
          .update({'partner_id': senderId})
          .eq('id', myId);
          
      // 3. Update their profile
      await _supabase
          .from('profiles')
          .update({'partner_id': myId})
          .eq('id', senderId);

      // Successfully linked! Trigger a reload by updating the wrapper state, 
      // or simply replacing the screen with HomeScreen.
      if (mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (context) => const HomeScreen()),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to accept request')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: const Text('Find Partner', style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: Colors.white,
        foregroundColor: Colors.black,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: () => _supabase.auth.signOut(),
          )
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Link Accounts',
              style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              'Search for your partner\'s username to send them a connection request.',
              style: TextStyle(color: Colors.grey.shade600, fontSize: 16),
            ),
            const SizedBox(height: 32),
            
            // Search Bar
            TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: 'Partner\'s username',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _isSearching
                    ? const Padding(
                        padding: EdgeInsets.all(12.0),
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : IconButton(
                        icon: const Icon(Icons.arrow_forward),
                        onPressed: _searchUser,
                      ),
                filled: true,
                fillColor: Colors.grey.shade100,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: BorderSide.none,
                ),
              ),
              onSubmitted: (_) => _searchUser(),
            ),
            
            const SizedBox(height: 32),

            // Search Result
            if (_foundUser != null) ...[
              const Text('Search Result', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              const SizedBox(height: 12),
              Container(
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey.shade200),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: ListTile(
                  leading: const CircleAvatar(backgroundColor: Colors.pinkAccent, child: Icon(Icons.favorite, color: Colors.white)),
                  title: Text(_foundUser!['full_name'] ?? _foundUser!['username'], style: const TextStyle(fontWeight: FontWeight.bold)),
                  subtitle: Text('@${_foundUser!['username']}'),
                  trailing: ElevatedButton(
                    onPressed: () => _sendRequest(_foundUser!['id']),
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.black, foregroundColor: Colors.white),
                    child: const Text('Send'),
                  ),
                ),
              ),
              const SizedBox(height: 32),
            ],

            // Incoming Requests
            if (_incomingRequests.isNotEmpty) ...[
              const Text('Incoming Requests', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              const SizedBox(height: 12),
              Expanded(
                child: ListView.separated(
                  itemCount: _incomingRequests.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 12),
                  itemBuilder: (context, index) {
                    final req = _incomingRequests[index];
                    final profile = req['profiles'];
                    return Container(
                      decoration: BoxDecoration(
                        color: Colors.pink.shade50,
                        border: Border.all(color: Colors.pink.shade100),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: ListTile(
                        leading: const CircleAvatar(backgroundColor: Colors.pink, child: Icon(Icons.person, color: Colors.white)),
                        title: Text(profile['full_name'] ?? profile['username'], style: const TextStyle(fontWeight: FontWeight.bold)),
                        subtitle: Text('@${profile['username']} wants to connect!'),
                        trailing: ElevatedButton(
                          onPressed: () => _acceptRequest(req['id'], req['sender_id']),
                          style: ElevatedButton.styleFrom(backgroundColor: Colors.pink, foregroundColor: Colors.white),
                          child: const Text('Accept'),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
