import 'dart:async';
import 'package:supabase_flutter/supabase_flutter.dart';

typedef SignalingMessageCallback = void Function(String type, Map<String, dynamic> data, String senderId);

class SignalingService {
  final SupabaseClient _supabase = Supabase.instance.client;
  RealtimeChannel? _channel;
  
  final String roomName;
  final String localParticipantId;

  SignalingMessageCallback? onMessage;

  SignalingService({required this.roomName, required this.localParticipantId});

  Future<void> connect() async {
    _channel = _supabase.channel('call:$roomName');
    
    _channel!.onBroadcast(
      event: 'signaling',
      callback: (payload) {
        final senderId = payload['senderId'] as String;
        if (senderId == localParticipantId) return; // Ignore our own messages

        final type = payload['type'] as String;
        final data = payload['data'] as Map<String, dynamic>? ?? {};

        onMessage?.call(type, data, senderId);
      },
    );

    await _channel!.subscribe((status, [error]) {
      if (status == 'SUBSCRIBED') {
        // Announce our presence so the other peer knows to send an offer if they are already here
        sendMessage('peer_joined', {});
      }
    });
  }

  void sendMessage(String type, Map<String, dynamic> data) {
    if (_channel == null) return;
    
    _channel!.sendBroadcastMessage(
      event: 'signaling',
      payload: {
        'senderId': localParticipantId,
        'type': type,
        'data': data,
      },
    );
  }

  void disconnect() {
    _channel?.unsubscribe();
    _channel = null;
  }
}
