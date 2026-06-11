import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../services/call_state.dart';
import 'video_call_screen.dart';

class GlobalCallOverlay extends StatefulWidget {
  const GlobalCallOverlay({super.key});

  @override
  State<GlobalCallOverlay> createState() => _GlobalCallOverlayState();
}

class _GlobalCallOverlayState extends State<GlobalCallOverlay> {
  bool _isCallMinimized = false;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<CallData?>(
      valueListenable: globalCallState,
      builder: (context, callData, child) {
        if (callData == null) {
          _isCallMinimized = false;
          return const SizedBox.shrink();
        }

        return AnimatedPositioned(
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
          right: _isCallMinimized ? 20 : 0,
          bottom: _isCallMinimized ? 100 : 0,
          width: _isCallMinimized ? 120 : MediaQuery.of(context).size.width,
          height: _isCallMinimized ? 160 : MediaQuery.of(context).size.height,
          child: GestureDetector(
            onTap: _isCallMinimized ? () => setState(() => _isCallMinimized = false) : null,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(_isCallMinimized ? 16 : 0),
              child: Material(
                elevation: _isCallMinimized ? 8 : 0,
                color: Colors.black,
                child: VideoCallScreen(
                  roomName: callData.roomId,
                  participantName: callData.callerName,
                  participantId: Supabase.instance.client.auth.currentUser?.id ?? '',
                  isVideoCall: callData.isVideo,
                  isCaller: callData.isCaller,
                  isMinimized: _isCallMinimized,
                  onToggleMinimize: () => setState(() => _isCallMinimized = !_isCallMinimized),
                  onEndCall: () {
                    globalCallState.value = null;
                  },
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
