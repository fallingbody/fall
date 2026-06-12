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
        final Map<String, dynamic> actualPayload = payload.containsKey('payload') 
            ? payload['payload'] as Map<String, dynamic> 
            : payload;

        final senderId = actualPayload['senderId'] as String?;
        if (senderId == null || senderId == localParticipantId) return; // Ignore our own messages

        final type = actualPayload['type'] as String?;
        if (type == null) return;
        
        final data = actualPayload['data'] as Map<String, dynamic>? ?? {};

        onMessage?.call(type, data, senderId);
      },
    );

    await _channel!.subscribe((status, [error]) {
      if (status == RealtimeSubscribeStatus.subscribed) {
        onStatusChange?.call('Subscribed OK');
        sendMessage('peer_joined', {});
        
        // Aggressively ping until the other side responds
        pingTimer = Timer.periodic(const Duration(seconds: 2), (timer) {
          sendMessage('peer_joined', {});
        });
      } else {
        onStatusChange?.call('Sub Failed: $status ${error ?? ""}');
      }
    });
  }

  void sendMessage(String type, Map<String, dynamic> data) {
    if (_channel == null) return;
    
    try {
      _channel!.sendBroadcastMessage(
        event: 'signaling',
        payload: {
          'senderId': localParticipantId,
          'type': type,
          'data': data,
        },
      );
    } catch (e) {
      print('Signaling broadcast failed: $e');
    }
  }

  void disconnect() {
    pingTimer?.cancel();
    _channel?.unsubscribe();
    _channel = null;
  }
}
