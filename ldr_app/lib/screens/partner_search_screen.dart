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
  List<dynamic> _connections = [];
  String _connectionSearchQuery = '';

  @override
  void initState() {
    super.initState();
    _fetchIncomingRequests();
    _fetchConnections();
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
      final requests = await _supabase
          .from('connection_requests')
          .select('id, sender_id, status, category')
          .eq('receiver_id', userId)
          .eq('status', 'pending');

      if (requests.isEmpty) {
        setState(() {
          _incomingRequests = [];
        });
        return;
      }

      final List<String> senderIds = requests.map<String>((req) => req['sender_id'] as String).toList();

      final profiles = await _supabase
          .from('profiles')
          .select('id, username, full_name')
          .inFilter('id', senderIds);

      final combined = requests.map((req) {
        final profile = profiles.firstWhere((p) => p['id'] == req['sender_id'], orElse: () => {'username': 'Unknown', 'full_name': 'Unknown User'});
        return {
          ...req,
          'profiles': profile,
        };
      }).toList();
      
      setState(() {
        _incomingRequests = combined;
      });
    } catch (e) {
      debugPrint('Error fetching requests: $e');
    }
  }

  Future<void> _fetchConnections() async {
    final myId = _supabase.auth.currentUser?.id;
    if (myId == null) return;

    try {
      final reqs = await _supabase
          .from('connection_requests')
          .select('id, sender_id, receiver_id, status, category')
          .eq('status', 'accepted')
          .or('sender_id.eq.$myId,receiver_id.eq.$myId');

      if (reqs.isEmpty) {
        setState(() => _connections = []);
        return;
      }

      final List<String> partnerIds = reqs.map<String>((req) {
        return (req['sender_id'] == myId ? req['receiver_id'] : req['sender_id']) as String;
      }).toList();

      final profiles = await _supabase
          .from('profiles')
          .select('id, username, full_name')
          .inFilter('id', partnerIds);

      final combined = reqs.map((req) {
        final partnerId = req['sender_id'] == myId ? req['receiver_id'] : req['sender_id'];
        final profile = profiles.firstWhere((p) => p['id'] == partnerId, orElse: () => {'username': 'Unknown', 'full_name': 'Unknown User'});
        return {
          ...req,
          'profiles': profile,
        };
      }).toList();

      setState(() => _connections = combined);
    } catch (e) {
      debugPrint('Error fetching connections: $e');
    }
  }

  Future<void> _disconnect(String connectionId) async {
    try {
      await _supabase.from('connection_requests').delete().eq('id', connectionId);
      
      // Remove partner_id from profile if necessary
      final myId = _supabase.auth.currentUser?.id;
      if (myId != null) {
        await _supabase.from('profiles').update({'partner_id': null}).eq('id', myId);
      }
      
      _fetchConnections();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Disconnected successfully.')));
      }
    } catch (e) {
      debugPrint('Error disconnecting: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Failed to disconnect.')));
      }
    }
  }

  Future<void> _searchUser() async {
    final username = _searchController.text.trim();
    if (username.isEmpty) return;
    
    // Can't search yourself
    final myProfile = await _supabase.from('profiles').select('username').eq('id', _supabase.auth.currentUser!.id).maybeSingle();
    if (myProfile != null && myProfile['username'] == username) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("You can't search yourself!")));
      return;
    }

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
      
      if (res != null) {
        // Check if there's already ANY connection (pending or accepted) between these two users
        final myId = _supabase.auth.currentUser!.id;
        final theirId = res['id'];

        final existing = await _supabase
            .from('connection_requests')
            .select('id, status')
            .or('and(sender_id.eq.$myId,receiver_id.eq.$theirId),and(sender_id.eq.$theirId,receiver_id.eq.$myId)')
            .maybeSingle();
            
        res['has_connection'] = existing != null;
        res['connection_status'] = existing?['status'];
      }

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
        setState(() {
          if (_foundUser != null) {
            _foundUser!['has_connection'] = true;
            _foundUser!['connection_status'] = 'pending';
          }
        });
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

    // Show dialog to categorize
    String? selectedCategory = await showDialog<String>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Categorize Connection'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                title: const Text('Partner ❤️'),
                onTap: () => Navigator.pop(context, 'partner'),
              ),
              ListTile(
                title: const Text('Friend 👋'),
                onTap: () => Navigator.pop(context, 'friend'),
              ),
              ListTile(
                title: const Text('Family 🏠'),
                onTap: () => Navigator.pop(context, 'family'),
              ),
            ],
          ),
        );
      }
    );

    if (selectedCategory == null) return; // User cancelled

    try {
      if (selectedCategory == 'partner') {
        // Check if I already have a partner
        final existingPartner = await _supabase
            .from('connection_requests')
            .select('id')
            .eq('category', 'partner')
            .eq('status', 'accepted')
            .or('sender_id.eq.$myId,receiver_id.eq.$myId')
            .maybeSingle();

        if (existingPartner != null && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('You already have a Partner!')));
          return;
        }
      }

      // Update request status and category
      await _supabase
          .from('connection_requests')
          .update({
            'status': 'accepted',
            'category': selectedCategory
          })
          .eq('id', requestId);
      
      // Update partner_id in profiles just for legacy fallback if they chose partner
      if (selectedCategory == 'partner') {
        await _supabase.from('profiles').update({'partner_id': senderId}).eq('id', myId);
        await _supabase.from('profiles').update({'partner_id': myId}).eq('id', senderId);
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Connected!')));
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
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final filteredConnections = _connections.where((conn) {
      if (_connectionSearchQuery.isEmpty) return true;
      final prof = conn['profiles'];
      final name = (prof['full_name'] ?? '').toString().toLowerCase();
      final username = (prof['username'] ?? '').toString().toLowerCase();
      final q = _connectionSearchQuery.toLowerCase();
      return name.contains(q) || username.contains(q);
    }).toList();

    return DefaultTabController(
      length: 3,
      child: Scaffold(
        backgroundColor: isDark ? Colors.black : Colors.white,
        appBar: AppBar(
          title: const Text('Connections', style: TextStyle(fontWeight: FontWeight.bold)),
          backgroundColor: isDark ? Colors.black : Colors.white,
          foregroundColor: isDark ? Colors.white : Colors.black,
          elevation: 0,
          bottom: TabBar(
            labelColor: Colors.pink,
            unselectedLabelColor: isDark ? Colors.grey.shade400 : Colors.grey.shade600,
            indicatorColor: Colors.pink,
            tabs: const [
              Tab(text: 'Search'),
              Tab(text: 'Requests'),
              Tab(text: 'Connections'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            // SEARCH TAB
            Padding(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Find People',
                    style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: isDark ? Colors.white : Colors.black),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Search for usernames to send a connection request.',
                    style: TextStyle(color: Colors.grey.shade500, fontSize: 16),
                  ),
                  const SizedBox(height: 32),
                  
                  TextField(
                    controller: _searchController,
                    style: TextStyle(color: isDark ? Colors.white : Colors.black),
                    decoration: InputDecoration(
                      hintText: 'Username',
                      hintStyle: TextStyle(color: isDark ? Colors.grey.shade400 : Colors.grey.shade600),
                      prefixIcon: Icon(Icons.search, color: isDark ? Colors.grey.shade400 : Colors.grey.shade600),
                      suffixIcon: _isSearching
                          ? const Padding(
                              padding: EdgeInsets.all(12.0),
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : IconButton(
                              icon: Icon(Icons.arrow_forward, color: isDark ? Colors.grey.shade400 : Colors.grey.shade600),
                              onPressed: _searchUser,
                            ),
                      filled: true,
                      fillColor: isDark ? Colors.grey.shade900 : Colors.grey.shade100,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                        borderSide: BorderSide.none,
                      ),
                    ),
                    onSubmitted: (_) => _searchUser(),
                  ),
                  
                  const SizedBox(height: 32),

                  if (_foundUser != null) ...[
                    Text('Search Result', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: isDark ? Colors.white : Colors.black)),
                    const SizedBox(height: 12),
                    Container(
                      decoration: BoxDecoration(
                        border: Border.all(color: isDark ? Colors.grey.shade800 : Colors.grey.shade200),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: ListTile(
                        leading: const CircleAvatar(backgroundColor: Colors.pinkAccent, child: Icon(Icons.person, color: Colors.white)),
                        title: Text(_foundUser!['full_name'] ?? _foundUser!['username'], style: TextStyle(fontWeight: FontWeight.bold, color: isDark ? Colors.white : Colors.black)),
                        subtitle: Text('@${_foundUser!['username']}', style: TextStyle(color: isDark ? Colors.grey.shade400 : Colors.grey.shade600)),
                        trailing: ElevatedButton(
                          onPressed: _foundUser!['has_connection'] == true ? null : () => _sendRequest(_foundUser!['id']),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: _foundUser!['has_connection'] == true ? Colors.grey : (isDark ? Colors.white : Colors.black), 
                            foregroundColor: _foundUser!['has_connection'] == true ? Colors.white : (isDark ? Colors.black : Colors.white)
                          ),
                          child: Text(_foundUser!['has_connection'] == true 
                            ? (_foundUser!['connection_status'] == 'accepted' ? 'Connected' : 'Pending') 
                            : 'Send'),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),

            // REQUESTS TAB
            _incomingRequests.isEmpty 
              ? Center(child: Text("No pending requests.", style: TextStyle(color: Colors.grey.shade500)))
              : Padding(
                  padding: const EdgeInsets.all(24.0),
                  child: ListView.separated(
                    itemCount: _incomingRequests.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 12),
                    itemBuilder: (context, index) {
                      final req = _incomingRequests[index];
                      final profile = req['profiles'];
                      return Container(
                        decoration: BoxDecoration(
                          color: isDark ? Colors.grey.shade900 : Colors.pink.shade50,
                          border: Border.all(color: isDark ? Colors.grey.shade800 : Colors.pink.shade100),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: ListTile(
                          leading: const CircleAvatar(backgroundColor: Colors.pink, child: Icon(Icons.person, color: Colors.white)),
                          title: Text(profile['full_name'] ?? profile['username'], style: TextStyle(fontWeight: FontWeight.bold, color: isDark ? Colors.white : Colors.black)),
                          subtitle: Text('@${profile['username']} wants to connect!', style: TextStyle(color: isDark ? Colors.grey.shade400 : Colors.black87)),
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

            // CONNECTIONS TAB
            Padding(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                children: [
                  TextField(
                    onChanged: (val) => setState(() => _connectionSearchQuery = val),
                    style: TextStyle(color: isDark ? Colors.white : Colors.black),
                    decoration: InputDecoration(
                      hintText: 'Search connections...',
                      hintStyle: TextStyle(color: isDark ? Colors.grey.shade400 : Colors.grey.shade600),
                      prefixIcon: Icon(Icons.search, color: isDark ? Colors.grey.shade400 : Colors.grey.shade600),
                      filled: true,
                      fillColor: isDark ? Colors.grey.shade900 : Colors.grey.shade100,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Expanded(
                    child: _connections.isEmpty 
                      ? Center(child: Text("You don't have any connections yet.", style: TextStyle(color: Colors.grey.shade500)))
                      : ListView.separated(
                          itemCount: filteredConnections.length,
                          separatorBuilder: (_, __) => const SizedBox(height: 12),
                          itemBuilder: (context, index) {
                            final conn = filteredConnections[index];
                            final profile = conn['profiles'];
                            return Container(
                              decoration: BoxDecoration(
                                color: isDark ? Colors.grey.shade900 : Colors.white,
                                border: Border.all(color: isDark ? Colors.grey.shade800 : Colors.grey.shade200),
                                borderRadius: BorderRadius.circular(16),
                              ),
                              child: ListTile(
                                leading: const CircleAvatar(backgroundColor: Colors.pinkAccent, child: Icon(Icons.person, color: Colors.white)),
                                title: Text(profile['full_name'] ?? profile['username'], style: TextStyle(fontWeight: FontWeight.bold, color: isDark ? Colors.white : Colors.black)),
                                subtitle: Text('@${profile['username']} • ${conn['category'] ?? 'Connection'}', style: TextStyle(color: isDark ? Colors.grey.shade400 : Colors.grey.shade600)),
                                trailing: ElevatedButton(
                                  onPressed: () => _disconnect(conn['id']),
                                  style: ElevatedButton.styleFrom(backgroundColor: Colors.red.shade100, foregroundColor: Colors.red.shade900, elevation: 0),
                                  child: const Text('Disconnect'),
                                ),
                              ),
                            );
                          },
                        ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
