import 'package:hive_flutter/hive_flutter.dart';
import 'package:flutter/foundation.dart';

class LocalDbService {
  static final LocalDbService _instance = LocalDbService._internal();
  factory LocalDbService() => _instance;
  LocalDbService._internal();

  late Box _messagesBox;

  Future<void> init() async {
    await Hive.initFlutter();
    // Use a single box for all messages
    _messagesBox = await Hive.openBox('messages');
  }

  /// Save a single message to local storage
  Future<void> saveMessage(Map<String, dynamic> message) async {
    try {
      await _messagesBox.put(message['id'], message);
    } catch (e) {
      debugPrint('Error saving message locally: $e');
    }
  }

  /// Update the status of an existing message
  Future<void> updateMessageStatus(String id, String newStatus) async {
    try {
      final message = _messagesBox.get(id);
      if (message != null) {
        // Create a new map to avoid type issues with Hive maps
        final updatedMessage = Map<String, dynamic>.from(message.map((key, value) => MapEntry(key.toString(), value)));
        updatedMessage['status'] = newStatus;
        await _messagesBox.put(id, updatedMessage);
      }
    } catch (e) {
      debugPrint('Error updating message status locally: $e');
    }
  }

  /// Update the text of an existing message
  Future<void> editMessageText(String id, String newText) async {
    try {
      final message = _messagesBox.get(id);
      if (message != null) {
        final updatedMessage = Map<String, dynamic>.from(message.map((key, value) => MapEntry(key.toString(), value)));
        updatedMessage['text'] = newText;
        await _messagesBox.put(id, updatedMessage);
      }
    } catch (e) {
      debugPrint('Error editing message text locally: $e');
    }
  }

  /// Listen to changes in the local database
  Stream<BoxEvent> watchMessages() {
    return _messagesBox.watch();
  }

  /// Load messages for a specific connection (me and partner)
  List<Map<String, dynamic>> getMessagesForConnection(String myId, String partnerId) {
    try {
      final allMessages = _messagesBox.values.toList().cast<Map<dynamic, dynamic>>();
      final List<Map<String, dynamic>> filtered = [];

      for (var rawMsg in allMessages) {
        // Convert dynamic map from Hive back to strictly typed String map
        final msg = rawMsg.map((key, value) => MapEntry(key.toString(), value));

        final author = msg['author_id'];
        final receiver = msg['receiver_id'];

        if ((author == myId && receiver == partnerId) || 
            (author == partnerId && receiver == myId)) {
          filtered.add(msg);
        }
      }

      // Sort newest first (descending by created_at)
      filtered.sort((a, b) {
        final dateA = DateTime.parse(a['created_at'].toString().endsWith('Z') || a['created_at'].toString().contains('+') ? a['created_at'] : '${a['created_at']}Z');
        final dateB = DateTime.parse(b['created_at'].toString().endsWith('Z') || b['created_at'].toString().contains('+') ? b['created_at'] : '${b['created_at']}Z');
        return dateB.compareTo(dateA); // Newest first
      });

      return filtered;
    } catch (e) {
      debugPrint('Error getting local messages: $e');
      return [];
    }
  }

  /// Optional: Delete a specific message locally
  Future<void> deleteMessage(String id) async {
    await _messagesBox.delete(id);
  }

  /// Optional: Clear entire chat history
  Future<void> clearAll() async {
    await _messagesBox.clear();
  }
}
