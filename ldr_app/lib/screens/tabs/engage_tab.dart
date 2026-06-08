import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../partner_search_screen.dart';

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
          // Stories Row
          if (!_isLoading && _connections.isNotEmpty)
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
                      // My Story
                      _buildStoryItem(Icons.add, 'Your Story', Colors.grey, isDark),
                      const SizedBox(width: 20),
                      // Partner & Friends Stories
                      ..._connections.map((conn) {
                        final category = conn['category'] as String;
                        IconData icon;
                        Color color;
                        if (category == 'partner') {
                          icon = Icons.favorite;
                          color = Colors.pinkAccent;
                        } else if (category == 'family') {
                          icon = Icons.home;
                          color = Colors.orangeAccent;
                        } else {
                          icon = Icons.group;
                          color = Colors.blueAccent;
                        }
                        return Padding(
                          padding: const EdgeInsets.only(right: 20.0),
                          child: _buildStoryItem(icon, conn['profile']['username'] ?? 'User', color, isDark),
                        );
                      }),
                    ],
                  ),
                ),
              ),
            ),

          // Achievements & Mini Games Strip
          SliverToBoxAdapter(
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 16.0),
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: isDark ? Colors.grey.shade900 : Colors.grey.shade200)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _buildQuickAction(_svgAchievements, 'Achievements', Colors.amber, isDark),
                  _buildQuickAction(_svgMinigames, 'Mini Games', Colors.orange, isDark),
                  _buildQuickAction(_svgMemories, 'Memories', Colors.purple, isDark),
                ],
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
                      onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (context) => const PartnerSearchScreen())),
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
                  String svgIcon;
                  Color iconColor;
                  if (category == 'partner') {
                    svgIcon = _svgPartner;
                    iconColor = Colors.pinkAccent;
                  } else if (category == 'family') {
                    svgIcon = _svgFamily;
                    iconColor = Colors.orangeAccent;
                  } else {
                    svgIcon = _svgFriends;
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
                            backgroundColor: iconColor.withOpacity(0.2),
                            child: SvgPicture.string(svgIcon, width: 30, height: 30),
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
  Widget _buildQuickAction(String svgString, String label, Color color, bool isDark) {
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: color.withOpacity(0.1),
            shape: BoxShape.circle,
          ),
          child: SvgPicture.string(svgString, width: 28, height: 28),
        ),
        const SizedBox(height: 8),
        Text(label, style: TextStyle(color: isDark ? Colors.white : Colors.black, fontWeight: FontWeight.w500)),
      ],
    );
  }

  // SVG Constants
  static const String _svgPartner = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="#FF4081"><path d="M12 21.35l-1.45-1.32C5.4 15.36 2 12.28 2 8.5 2 5.42 4.42 3 7.5 3c1.74 0 3.41.81 4.5 2.09C13.09 3.81 14.76 3 16.5 3 19.58 3 22 5.42 22 8.5c0 3.78-3.4 6.86-8.55 11.54L12 21.35z"/></svg>';
  static const String _svgFamily = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="#FFB300"><path d="M10 20v-6h4v6h5v-8h3L12 3 2 12h3v8z"/></svg>';
  static const String _svgFriends = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="#448AFF"><path d="M16 11c1.66 0 2.99-1.34 2.99-3S17.66 5 16 5c-1.66 0-3 1.34-3 3s1.34 3 3 3zm-8 0c1.66 0 2.99-1.34 2.99-3S9.66 5 8 5C6.34 5 5 6.34 5 8s1.34 3 3 3zm0 2c-2.33 0-7 1.17-7 3.5V19h14v-2.5c0-2.33-4.67-3.5-7-3.5zm8 0c-.29 0-.62.02-.97.05 1.16.84 1.97 1.97 1.97 3.45V19h6v-2.5c0-2.33-4.67-3.5-7-3.5z"/></svg>';
  static const String _svgAchievements = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="#FFC107"><path d="M19 5h-2V3H7v2H5c-1.1 0-2 .9-2 2v1c0 2.55 1.92 4.63 4.39 4.94A5.01 5.01 0 0011 15.9V19H7v2h10v-2h-4v-3.1a5.01 5.01 0 003.61-2.96C19.08 12.63 21 10.55 21 8V7c0-1.1-.9-2-2-2zM7 10.82C5.84 10.4 5 9.3 5 8 V7h2v3.82zM19 8c0 1.3-.84 2.4-2 2.82V7h2v1z"/></svg>';
  static const String _svgMinigames = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="#FF5722"><path d="M21 6H3c-1.1 0-2 .9-2 2v8c0 1.1.9 2 2 2h18c1.1 0 2-.9 2-2V8c0-1.1-.9-2-2-2zm-10 7H8v3H6v-3H3v-2h3V8h2v3h3v2zm4.5 2c-.83 0-1.5-.67-1.5-1.5s.67-1.5 1.5-1.5 1.5.67 1.5 1.5-.67 1.5-1.5 1.5zm3-3c-.83 0-1.5-.67-1.5-1.5S17.67 9 18.5 9s1.5.67 1.5 1.5-.67 1.5-1.5 1.5z"/></svg>';
  static const String _svgMemories = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="#9C27B0"><path d="M21 19V5c0-1.1-.9-2-2-2H5c-1.1 0-2 .9-2 2v14c0 1.1.9 2 2 2h14c1.1 0 2-.9 2-2zM8.5 13.5l2.5 3.01L14.5 12l4.5 6H5l3.5-4.5z"/></svg>';

  Widget _buildStoryItem(IconData icon, String label, Color color, bool isDark) {
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: LinearGradient(
              colors: [color.withOpacity(0.5), color, color.withOpacity(0.8)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
          child: Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isDark ? Colors.black : Colors.white,
              border: Border.all(color: isDark ? Colors.black : Colors.white, width: 2),
            ),
            child: Icon(icon, color: color, size: 28),
          ),
        ),
        const SizedBox(height: 6),
        SizedBox(
          width: 70,
          child: Text(
            label, 
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: isDark ? Colors.white : Colors.black),
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}
