import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class EngageTab extends StatefulWidget {
  const EngageTab({super.key});

  @override
  State<EngageTab> createState() => _EngageTabState();
}

class _EngageTabState extends State<EngageTab> {
  final _supabase = Supabase.instance.client;
  bool _isLoading = true;
  List<Map<String, dynamic>> _connections = [];

  @override
  void initState() {
    super.initState();
    _fetchConnections();
  }

  Future<void> _fetchConnections() async {
    final myId = _supabase.auth.currentUser?.id;
    if (myId == null) return;

    try {
      // 1. Fetch all accepted connections where I am sender OR receiver
      final requests = await _supabase
          .from('connection_requests')
          .select('id, sender_id, receiver_id, category')
          .eq('status', 'accepted')
          .or('sender_id.eq.$myId,receiver_id.eq.$myId');

      if (requests.isEmpty) {
        setState(() {
          _connections = [];
          _isLoading = false;
        });
        return;
      }

      // 2. Extract the IDs of the OTHER person
      final Set<String> otherUserIds = {};
      for (var req in requests) {
        if (req['sender_id'] == myId) {
          otherUserIds.add(req['receiver_id'] as String);
        } else {
          otherUserIds.add(req['sender_id'] as String);
        }
      }

      // 3. Fetch their profiles
      final profiles = await _supabase
          .from('profiles')
          .select('id, username, full_name')
          .inFilter('id', otherUserIds.toList());

      // 4. Combine into _connections list
      final List<Map<String, dynamic>> combined = [];
      for (var req in requests) {
        final otherId = req['sender_id'] == myId ? req['receiver_id'] : req['sender_id'];
        final profile = profiles.firstWhere((p) => p['id'] == otherId, orElse: () => {'username': 'Unknown', 'full_name': 'Unknown User'});
        
        // Also fetch the last message to show in preview? (Optional, skipping for now to keep it fast)

        combined.add({
          'connection_id': req['id'],
          'other_user_id': otherId,
          'category': req['category'] ?? 'friend',
          'profile': profile,
        });
      }

      // Sort by category: Partner first, then family, then friend
      combined.sort((a, b) {
        int getRank(String cat) {
          if (cat == 'partner') return 1;
          if (cat == 'family') return 2;
          return 3;
        }
        return getRank(a['category']).compareTo(getRank(b['category']));
      });

      setState(() {
        _connections = combined;
        _isLoading = false;
      });
    } catch (e) {
      debugPrint('Error fetching connections: $e');
      setState(() {
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return RefreshIndicator(
      onRefresh: _fetchConnections,
      child: CustomScrollView(
        slivers: [
          // Top Row (Quick Actions)
          SliverToBoxAdapter(
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 16.0),
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: isDark ? Colors.grey.shade900 : Colors.grey.shade200)),
              ),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16.0),
                child: Row(
                  children: [
                    _buildQuickAction(Icons.videocam, 'Video Call', Colors.blue, isDark),
                    const SizedBox(width: 20),
                    _buildQuickAction(Icons.call, 'Voice Call', Colors.green, isDark),
                    const SizedBox(width: 20),
                    _buildQuickAction(Icons.extension, 'Mini Games', Colors.orange, isDark),
                  ],
                ),
              ),
            ),
          ),

          // The Chat List
          if (_isLoading)
            const SliverFillRemaining(child: Center(child: CircularProgressIndicator()))
          else if (_connections.isEmpty)
            SliverFillRemaining(
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.people_outline, size: 64, color: Colors.grey.shade400),
                    const SizedBox(height: 16),
                    Text('No connections yet.', style: TextStyle(color: Colors.grey.shade500, fontSize: 16)),
                    const SizedBox(height: 8),
                    ElevatedButton(
                      onPressed: () => context.push('/'), // Will just pop if already on Home, wait, Home has a heart icon
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.pink, foregroundColor: Colors.white),
                      child: const Text('Tap the ❤️ to find people!'),
                    )
                  ],
                ),
              ),
            )
          else
            SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, index) {
                  final conn = _connections[index];
                  final profile = conn['profile'];
                  final category = conn['category'] as String;
                  
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

                  return InkWell(
                    onTap: () {
                      context.push('/chat', extra: conn);
                    },
                    child: Container(
                      padding: const EdgeInsets.all(16.0),
                      decoration: BoxDecoration(
                        border: Border(bottom: BorderSide(color: isDark ? Colors.grey.shade900 : Colors.grey.shade200)),
                      ),
                      child: Row(
                        children: [
                          CircleAvatar(
                            radius: 30,
                            backgroundColor: iconColor,
                            child: Icon(icon, color: Colors.white, size: 30),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Text(profile['full_name'] ?? profile['username'], style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: isDark ? Colors.white : Colors.black)),
                                    const SizedBox(width: 8),
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                      decoration: BoxDecoration(color: iconColor.withOpacity(0.2), borderRadius: BorderRadius.circular(4)),
                                      child: Text(category.toUpperCase(), style: TextStyle(color: iconColor, fontSize: 10, fontWeight: FontWeight.bold)),
                                    )
                                  ],
                                ),
                                const SizedBox(height: 4),
                                Text('@${profile['username']}', style: TextStyle(color: isDark ? Colors.grey.shade500 : Colors.grey.shade600, fontSize: 15)),
                              ],
                            ),
                          ),
                          Icon(Icons.chevron_right, color: isDark ? Colors.grey.shade700 : Colors.grey.shade400),
                        ],
                      ),
                    ),
                  );
                },
                childCount: _connections.length,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildQuickAction(IconData icon, String label, Color color, bool isDark) {
    return Column(
      children: [
        Container(
          width: 65,
          height: 65,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: isDark ? Colors.grey.shade800 : Colors.grey.shade300, width: 1),
            color: isDark ? Colors.black : Colors.white,
          ),
          child: Icon(icon, color: color, size: 28),
        ),
        const SizedBox(height: 6),
        Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: isDark ? Colors.white : Colors.black)),
      ],
    );
  }
}
