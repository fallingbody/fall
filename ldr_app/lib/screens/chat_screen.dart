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
import 'package:intl/intl.dart';
import 'package:flutter/services.dart';

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
  final TextEditingController _textController = TextEditingController();

  // Reply & Edit state
  types.Message? _replyToMessage;
  types.Message? _editingMessage;
  bool _isEditing = false;

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
    _textController.dispose();
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

      if (row['author_id'] == _partner.id && row['status'] != 'seen') {
        _sendSeenReceipt(row['id']);
        LocalDbService().updateMessageStatus(row['id'], 'seen');
        msgStatus = types.Status.seen;
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
          metadata: {'type': 'call_invite', 'text': row['text'].toString()},
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

  void _sendSeenReceipt(String targetMsgId) async {
    try {
      await Supabase.instance.client.from('messages').insert({
        'id': const Uuid().v4(),
        'author_id': _user.id,
        'receiver_id': _partner.id,
        'text': 'RECEIPT_SEEN:$targetMsgId',
        'status': 'sent',
        'created_at': DateTime.now().toUtc().toIso8601String(),
      });
    } catch (e) {
      debugPrint('Error sending seen receipt: $e');
    }
  }

  void _handleSendPressed(types.PartialText message) async {
    // --- EDIT MODE ---
    if (_isEditing && _editingMessage != null) {
      final editedId = _editingMessage!.id;
      final newText = message.text;

      await LocalDbService().saveMessage({
        'id': editedId,
        'author_id': _user.id,
        'receiver_id': _partner.id,
        'text': newText,
        'status': 'sent',
        'created_at': DateTime.fromMillisecondsSinceEpoch(_editingMessage!.createdAt ?? 0).toUtc().toIso8601String(),
      });

      // Send sync to partner
      await Supabase.instance.client.from('messages').insert({
        'id': const Uuid().v4(),
        'author_id': _user.id,
        'receiver_id': _partner.id,
        'text': 'EDIT_MESSAGE:$editedId|:$newText',
        'status': 'sent',
        'created_at': DateTime.now().toUtc().toIso8601String(),
      });
      setState(() {
        _isEditing = false;
        _editingMessage = null;
      });
      _loadLocalMessages();
      return;
    }

    // --- REPLY MODE ---
    String text = message.text;
    if (_replyToMessage != null) {
      String replyPreview = '';
      if (_replyToMessage is types.TextMessage) {
        replyPreview = (_replyToMessage as types.TextMessage).text;
      } else {
        replyPreview = 'media';
      }
      // Truncate to 50 chars
      if (replyPreview.length > 50) replyPreview = '${replyPreview.substring(0, 50)}...';
      text = '[REPLY:$replyPreview]\n$text';
      setState(() => _replyToMessage = null);
    }

    try {
      final msgData = {
        'id': const Uuid().v4(),
        'author_id': _user.id,
        'receiver_id': _partner.id,
        'text': text,
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

  // ─── Long-press context menu ───
  void _handleMessageLongPress(BuildContext ctx, types.Message message) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isMe = message.author.id == _user.id;

    showModalBottomSheet(
      context: context,
      backgroundColor: isDark ? Colors.grey.shade900 : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetCtx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Copy
                ListTile(
                  leading: Icon(Icons.copy, color: isDark ? Colors.white70 : Colors.black87),
                  title: Text('Copy', style: TextStyle(color: isDark ? Colors.white : Colors.black)),
                  onTap: () {
                    Navigator.pop(sheetCtx);
                    _copyMessage(message);
                  },
                ),
                // Reply
                ListTile(
                  leading: Icon(Icons.reply, color: isDark ? Colors.white70 : Colors.black87),
                  title: Text('Reply', style: TextStyle(color: isDark ? Colors.white : Colors.black)),
                  onTap: () {
                    Navigator.pop(sheetCtx);
                    _replyToMsg(message);
                  },
                ),
                // Edit (only my messages + only text)
                if (isMe && message is types.TextMessage)
                  ListTile(
                    leading: Icon(Icons.edit, color: isDark ? Colors.white70 : Colors.black87),
                    title: Text('Edit', style: TextStyle(color: isDark ? Colors.white : Colors.black)),
                    onTap: () {
                      Navigator.pop(sheetCtx);
                      _editMessage(message);
                    },
                  ),
                // Delete (only my messages)
                if (isMe)
                  ListTile(
                    leading: const Icon(Icons.delete, color: Colors.redAccent),
                    title: const Text('Delete', style: TextStyle(color: Colors.redAccent)),
                    onTap: () {
                      Navigator.pop(sheetCtx);
                      _deleteMessage(message);
                    },
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _copyMessage(types.Message message) {
    String text = '';
    if (message is types.TextMessage) {
      text = message.text;
    } else if (message is types.ImageMessage) {
      text = message.uri;
    }
    Clipboard.setData(ClipboardData(text: text));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Copied to clipboard'), duration: Duration(seconds: 1)),
      );
    }
  }

  void _replyToMsg(types.Message message) {
    setState(() {
      _replyToMessage = message;
      _isEditing = false;
      _editingMessage = null;
    });
  }

  void _editMessage(types.Message message) {
    if (message is types.TextMessage) {
      setState(() {
        _isEditing = true;
        _editingMessage = message;
        _replyToMessage = null;
        _textController.text = message.text;
      });
    }
  }

  void _deleteMessage(types.Message message) async {
    await LocalDbService().deleteMessage(message.id);

    // Send sync to partner
    await Supabase.instance.client.from('messages').insert({
      'id': const Uuid().v4(),
      'author_id': _user.id,
      'receiver_id': _partner.id,
      'text': 'DELETE_MESSAGE:${message.id}',
      'status': 'sent',
      'created_at': DateTime.now().toUtc().toIso8601String(),
    });
    _loadLocalMessages();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Message deleted'), duration: Duration(seconds: 1)),
      );
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

  void _handleKeyboardImage(KeyboardInsertedContent content) async {
    final bytes = content.data;
    if (bytes == null) return;
    
    final fileExt = content.mimeType.split('/').last;
    final msgId = const Uuid().v4();
    final fileName = '$msgId.$fileExt';

    try {
      // 1. Upload to Supabase drop-box
      await Supabase.instance.client.storage
          .from('chat_media')
          .uploadBinary(fileName, bytes);
      
      final publicUrl = Supabase.instance.client.storage
          .from('chat_media')
          .getPublicUrl(fileName);

      // 2. Prepare message
      final msgData = {
        'id': msgId,
        'author_id': _user.id,
        'receiver_id': _partner.id,
        'text': '[IMAGE]:$publicUrl',
        'status': 'sent',
        'created_at': DateTime.now().toUtc().toIso8601String(),
      };

      // 3. Save locally
      await LocalDbService().saveMessage(msgData);

      // 4. Send to Supabase queue
      await Supabase.instance.client.from('messages').insert(msgData);

      _loadLocalMessages();
    } catch (e) {
      debugPrint('Error sending keyboard image: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to send image')),
        );
      }
    }
  }

  Widget _buildCustomInput() {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // Reply / Edit preview banner
    Widget? banner;
    if (_replyToMessage != null) {
      String preview = '';
      if (_replyToMessage is types.TextMessage) {
        preview = (_replyToMessage as types.TextMessage).text;
      } else if (_replyToMessage is types.ImageMessage) {
        preview = '📷 Photo';
      } else {
        preview = 'Message';
      }
      if (preview.length > 60) preview = '${preview.substring(0, 60)}...';
      final isPartner = _replyToMessage!.author.id == _partner.id;
      banner = Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: isDark ? Colors.grey.shade800 : Colors.grey.shade200,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
        ),
        child: Row(
          children: [
            Container(width: 3, height: 36, color: Colors.pinkAccent),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(isPartner ? (_partner.firstName ?? 'Partner') : 'You',
                    style: const TextStyle(color: Colors.pinkAccent, fontWeight: FontWeight.bold, fontSize: 12)),
                  Text(preview, style: TextStyle(color: isDark ? Colors.grey.shade400 : Colors.grey.shade600, fontSize: 13), maxLines: 1, overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
            IconButton(
              icon: const Icon(Icons.close, size: 18),
              onPressed: () => setState(() => _replyToMessage = null),
            ),
          ],
        ),
      );
    } else if (_isEditing && _editingMessage != null) {
      banner = Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: isDark ? Colors.grey.shade800 : Colors.grey.shade200,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
        ),
        child: Row(
          children: [
            Container(width: 3, height: 36, color: Colors.blueAccent),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Editing', style: TextStyle(color: Colors.blueAccent, fontWeight: FontWeight.bold, fontSize: 12)),
                  if (_editingMessage is types.TextMessage)
                    Text((_editingMessage as types.TextMessage).text,
                      style: TextStyle(color: isDark ? Colors.grey.shade400 : Colors.grey.shade600, fontSize: 13), maxLines: 1, overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
            IconButton(
              icon: const Icon(Icons.close, size: 18),
              onPressed: () => setState(() { _isEditing = false; _editingMessage = null; _textController.clear(); }),
            ),
          ],
        ),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (banner != null) banner,
        Container(
          color: isDark ? Colors.grey.shade900 : const Color(0xFFF5F5F5),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: SafeArea(
            child: Row(
              children: [
                IconButton(
                  icon: Icon(Icons.attach_file, color: isDark ? Colors.white : Colors.black),
                  onPressed: _handleAttachmentPressed,
                ),
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      color: isDark ? Colors.black : Colors.white,
                      borderRadius: BorderRadius.circular(24),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: TextField(
                      controller: _textController,
                      textCapitalization: TextCapitalization.sentences,
                      minLines: 1,
                      maxLines: 5,
                      style: TextStyle(color: isDark ? Colors.white : Colors.black),
                      contentInsertionConfiguration: ContentInsertionConfiguration(
                        onContentInserted: (KeyboardInsertedContent content) {
                          _handleKeyboardImage(content);
                        },
                      ),
                      decoration: InputDecoration(
                        hintText: _isEditing ? 'Edit message...' : 'Type a message...',
                        hintStyle: TextStyle(color: isDark ? Colors.grey.shade500 : Colors.grey.shade400),
                        border: InputBorder.none,
                      ),
                      onSubmitted: (text) {
                        if (text.trim().isNotEmpty) {
                          _handleSendPressed(types.PartialText(text: text.trim()));
                          _textController.clear();
                        }
                      },
                    ),
                  ),
                ),
                IconButton(
                  icon: Icon(_isEditing ? Icons.check : Icons.send, color: _isEditing ? Colors.blueAccent : Colors.pinkAccent),
                  onPressed: () {
                     if (_textController.text.trim().isNotEmpty) {
                        _handleSendPressed(types.PartialText(text: _textController.text.trim()));
                        _textController.clear();
                     }
                  },
                ),
              ],
            ),
          ),
        ),
      ],
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
                              participantId: _user.id,
                              isVideoCall: true,
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
                              participantId: _user.id,
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
        onMessageLongPress: _handleMessageLongPress,
        user: _user,
        showUserAvatars: true,
        showUserNames: true,
        customBottomWidget: _buildCustomInput(),
        customMessageBuilder: (types.CustomMessage msg, {required int messageWidth}) {
          if (msg.metadata?['type'] == 'call_invite') {
            final String text = msg.metadata?['text'] ?? '';
            final isVideo = text.startsWith('CALL_INVITE_VIDEO');
            final timeStr = DateFormat('hh:mm a').format(DateTime.fromMillisecondsSinceEpoch(msg.createdAt ?? 0));
            return Container(
              margin: const EdgeInsets.symmetric(vertical: 8),
              alignment: Alignment.center,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color: Theme.of(context).brightness == Brightness.dark ? Colors.grey.shade800 : Colors.grey.shade200,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Text(
                  '${isVideo ? "📹 Video Call" : "📞 Audio Call"} - $timeStr',
                  style: TextStyle(
                    color: Theme.of(context).brightness == Brightness.dark ? Colors.white70 : Colors.black87,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            );
          }
          return const SizedBox();
        },
        textMessageBuilder: (types.TextMessage msg, {required int messageWidth, required bool showName}) {
          final isMe = msg.author.id == _user.id;

          // Parse reply prefix: [REPLY:preview]\nactualText
          String? replyPreview;
          String displayText = msg.text;
          if (msg.text.startsWith('[REPLY:')) {
            final closingBracket = msg.text.indexOf(']');
            if (closingBracket != -1) {
              replyPreview = msg.text.substring(7, closingBracket);
              displayText = msg.text.substring(closingBracket + 1).trim();
            }
          }

          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Reply quote block
                if (replyPreview != null)
                  Container(
                    margin: const EdgeInsets.only(bottom: 6),
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: isMe ? Colors.pink.shade700 : (isDark ? Colors.grey.shade800 : Colors.grey.shade300),
                      borderRadius: BorderRadius.circular(8),
                      border: Border(left: BorderSide(color: Colors.pinkAccent, width: 3)),
                    ),
                    child: Text(
                      replyPreview,
                      style: TextStyle(color: isMe ? Colors.white70 : Colors.grey.shade600, fontSize: 13, fontStyle: FontStyle.italic),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                // Actual message text
                Text(displayText, style: TextStyle(color: isMe ? Colors.white : (isDark ? Colors.white : Colors.black), fontSize: 16)),
                const SizedBox(height: 4),
                // Timestamp + ticks row
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      DateFormat('hh:mm a').format(DateTime.fromMillisecondsSinceEpoch(msg.createdAt ?? 0)),
                      style: TextStyle(color: isMe ? Colors.white70 : Colors.grey.shade500, fontSize: 10),
                    ),
                    if (isMe) ...[
                      const SizedBox(width: 4),
                      if (msg.status == types.Status.seen)
                        const Text('\u2713\u2713', style: TextStyle(color: Colors.blue, fontSize: 10))
                      else if (msg.status == types.Status.delivered)
                        const Text('\u2713\u2713', style: TextStyle(color: Colors.grey, fontSize: 10))
                      else
                        const Text('\u2713', style: TextStyle(color: Colors.grey, fontSize: 10)),
                    ]
                  ],
                ),
              ],
            ),
          );
        },
        theme: DefaultChatTheme(
          primaryColor: Colors.pink, // Fixes white on white blending! Solid vibrant color!
          secondaryColor: isDark ? Colors.grey.shade800 : const Color(0xFFF5F5F5),
          backgroundColor: isDark ? Colors.black : Colors.white,
          inputBackgroundColor: isDark ? Colors.grey.shade900 : const Color(0xFFF5F5F5),
          inputTextColor: isDark ? Colors.white : Colors.black,
          sendButtonIcon: Icon(Icons.send, color: isDark ? Colors.white : Colors.black),
          seenIcon: const SizedBox.shrink(),
          deliveredIcon: const SizedBox.shrink(),
        ),
      ),
    );
  }
}
