import 'dart:async';
import 'package:supabase_flutter/supabase_flutter.dart';

typedef SignalingMessageCallback = void Function(String type, Map<String, dynamic> data, String senderId);

class SignalingService {
  final SupabaseClient _supabase = Supabase.instance.client;
  RealtimeChannel? _channel;
  
  final String roomName;
  final String localParticipantId;

  SignalingMessageCallback? onMessage;
  Timer? pingTimer;

  SignalingService({required this.roomName, required this.localParticipantId});

  Future<void> connect({void Function(String)? onStatusChange}) async {
    _channel = _supabase.channel('call:$roomName');
    
    _channel!.onBroadcast(
      event: 'signaling',
      callback: (payload) {
        onStatusChange?.call('Raw: ${payload.toString()}');
        
        final Map<String, dynamic> actualPayload = payload.containsKey('payload') 
            ? payload['payload'] as Map<String, dynamic> 
            : payload;

        final senderId = actualPayload['senderId'] as String?;
        if (senderId == null) {
          onStatusChange?.call('Missing senderId');
          return;
        }
        if (senderId == localParticipantId) {
          onStatusChange?.call('Ignored own message');
          return;
        }

        final type = actualPayload['msg_type'] as String?; // Changed from 'type' because Supabase overwrites it
        if (type == null) {
          onStatusChange?.call('Missing msg_type');
          return;
        }
        
        final data = actualPayload['data'] as Map<String, dynamic>? ?? {};
        onStatusChange?.call('Parsed: $type');

        onMessage?.call(type, data, senderId);
      },
    );

    _channel!.onPresenceLeave((payload) {
      onStatusChange?.call('Presence leave: ${payload.toString()}');
      final leftPresences = payload.leftPresences;
      for (var presence in leftPresences) {
        final id = presence.payload['participantId'];
        if (id != null && id != localParticipantId) {
          onMessage?.call('peer_left', {}, id as String);
        }
      }
    });

    await _channel!.subscribe((status, [error]) async {
      if (status == RealtimeSubscribeStatus.subscribed) {
        onStatusChange?.call('Subscribed OK');
        
        await _channel!.track({
          'participantId': localParticipantId,
          'status': 'online',
        });
        
        _sendMessageInternal('peer_joined', {}, onStatusChange);
        
        // Aggressively ping until the other side responds
        pingTimer = Timer.periodic(const Duration(seconds: 2), (timer) {
          _sendMessageInternal('peer_joined', {}, onStatusChange);
        });
      } else {
        onStatusChange?.call('Sub Failed: $status ${error ?? ""}');
      }
    });
  }

  void sendMessage(String type, Map<String, dynamic> data) {
    _sendMessageInternal(type, data, null);
  }

  void _sendMessageInternal(String type, Map<String, dynamic> data, void Function(String)? onStatusChange) {
    if (_channel == null) {
      onStatusChange?.call('Send fail: Channel null');
      return;
    }
    
    try {
      _channel!.sendBroadcastMessage(
        event: 'signaling',
        payload: {
          'senderId': localParticipantId,
          'msg_type': type, // Changed from 'type' because Supabase overwrites it
          'data': data,
        },
      );
      onStatusChange?.call('Sent $type');
    } catch (e) {
      onStatusChange?.call('Send Exception: $e');
      print('Signaling broadcast failed: $e');
    }
  }

  void disconnect() {
    pingTimer?.cancel();
    _channel?.unsubscribe();
    _channel = null;
  }
}
