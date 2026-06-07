import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import '../services/livekit_service.dart';

class VideoCallScreen extends StatefulWidget {
  final String roomName;
  final String participantName;
  final bool isVideoCall;

  const VideoCallScreen({
    super.key, 
    required this.roomName, 
    required this.participantName,
    this.isVideoCall = true,
  });

  @override
  State<VideoCallScreen> createState() => _VideoCallScreenState();
}

class _VideoCallScreenState extends State<VideoCallScreen> {
  late final Room _room;
  EventsListener<RoomEvent>? _listener;
  
  bool _isConnecting = true;
  bool _micMuted = false;
  late bool _videoMuted;

  Participant? _remoteParticipant;

  @override
  void initState() {
    super.initState();
    _videoMuted = !widget.isVideoCall;
    _connect();
  }

  Future<void> _connect() async {
    try {
      final token = LiveKitService.generateToken(roomName: widget.roomName, participantName: widget.participantName);
      final url = dotenv.env['LIVEKIT_URL'] ?? '';

      if (url.isEmpty) throw Exception('LIVEKIT_URL is not set in .env');

      _room = Room();
      _listener = _room.createListener();
      
      _listener!.on<RoomEvent>((event) {
        if (event is ParticipantConnectedEvent) {
          setState(() {
            _remoteParticipant = event.participant;
          });
        } else if (event is ParticipantDisconnectedEvent) {
          setState(() {
            if (_remoteParticipant?.sid == event.participant.sid) {
              _remoteParticipant = null;
            }
          });
        } else if (event is TrackSubscribedEvent) {
          setState(() {});
        } else if (event is TrackUnsubscribedEvent) {
          setState(() {});
        } else if (event is LocalTrackPublishedEvent) {
          setState(() {});
        } else if (event is LocalTrackUnpublishedEvent) {
          setState(() {});
        }
      });

      await _room.connect(url, token);
      
      await _room.localParticipant?.setCameraEnabled(widget.isVideoCall);
      await _room.localParticipant?.setMicrophoneEnabled(true);

      // Check if someone is already in the room
      if (_room.remoteParticipants.isNotEmpty) {
        _remoteParticipant = _room.remoteParticipants.values.first;
      }

      setState(() {
        _isConnecting = false;
      });
    } catch (e) {
      debugPrint('Failed to connect to LiveKit: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to connect: $e')));
        Navigator.pop(context);
      }
    }
  }

  @override
  void dispose() {
    _listener?.dispose();
    _room.disconnect();
    _room.dispose();
    super.dispose();
  }

  void _toggleMic() async {
    if (_room.localParticipant == null) return;
    await _room.localParticipant!.setMicrophoneEnabled(_micMuted);
    setState(() => _micMuted = !_micMuted);
  }

  void _toggleVideo() async {
    if (_room.localParticipant == null) return;
    await _room.localParticipant!.setCameraEnabled(_videoMuted);
    setState(() => _videoMuted = !_videoMuted);
  }

  @override
  Widget build(BuildContext context) {
    if (_isConnecting) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(child: CircularProgressIndicator(color: Colors.white)),
      );
    }

    // Get remote video track
    VideoTrack? remoteVideoTrack;
    if (_remoteParticipant != null) {
      final pub = _remoteParticipant!.videoTrackPublications.values.firstWhere(
        (p) => p.track != null,
        orElse: () => _remoteParticipant!.videoTrackPublications.values.first, // fallback, though track might be null
      );
      if (pub.track is VideoTrack) remoteVideoTrack = pub.track as VideoTrack;
    }

    // Get local video track
    VideoTrack? localVideoTrack;
    if (_room.localParticipant != null) {
      for (var pub in _room.localParticipant!.videoTrackPublications.values) {
        if (pub.track is VideoTrack) {
          localVideoTrack = pub.track as VideoTrack;
          break;
        }
      }
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // Background for Audio Call
          if (!widget.isVideoCall && remoteVideoTrack == null)
            Positioned.fill(
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [Colors.pink.shade900, Colors.black],
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                  ),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    CircleAvatar(
                      radius: 60,
                      backgroundColor: Colors.pinkAccent.withOpacity(0.3),
                      child: CircleAvatar(
                        radius: 50,
                        backgroundColor: Colors.pink,
                        child: Text(
                          widget.participantName[0].toUpperCase(),
                          style: const TextStyle(fontSize: 40, color: Colors.white, fontWeight: FontWeight.bold),
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),
                    Text('Audio Call with ${widget.participantName}', style: const TextStyle(color: Colors.white, fontSize: 20)),
                    const SizedBox(height: 8),
                    Text(_isConnecting ? 'Connecting...' : 'Connected', style: TextStyle(color: Colors.white.withOpacity(0.6), fontSize: 16)),
                  ],
                ),
              ),
            ),

          // Remote Video (Full Screen)
          if (remoteVideoTrack != null)
            Positioned.fill(
              child: VideoTrackRenderer(remoteVideoTrack, fit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover),
            )
          else if (widget.isVideoCall)
            const Center(
              child: Text('Waiting for partner...', style: TextStyle(color: Colors.white, fontSize: 18)),
            ),

          // Local Video (PiP)
          if (localVideoTrack != null && !_videoMuted && widget.isVideoCall)
            Positioned(
              right: 20,
              top: 60,
              width: 110,
              height: 160,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  color: Colors.grey.shade900,
                  child: VideoTrackRenderer(localVideoTrack, fit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover),
                ),
              ),
            ),

          // Controls
          Positioned(
            bottom: 40,
            left: 0,
            right: 0,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _buildControlButton(
                  icon: _micMuted ? Icons.mic_off : Icons.mic,
                  color: _micMuted ? Colors.red : Colors.white24,
                  onPressed: _toggleMic,
                ),
                const SizedBox(width: 20),
                _buildControlButton(
                  icon: Icons.call_end,
                  color: Colors.red,
                  size: 64,
                  iconSize: 32,
                  onPressed: () => Navigator.pop(context),
                ),
                const SizedBox(width: 20),
                _buildControlButton(
                  icon: _videoMuted ? Icons.videocam_off : Icons.videocam,
                  color: _videoMuted ? Colors.red : Colors.white24,
                  onPressed: _toggleVideo,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildControlButton({required IconData icon, required Color color, double size = 56, double iconSize = 24, required VoidCallback onPressed}) {
    return InkWell(
      onTap: onPressed,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(shape: BoxShape.circle, color: color),
        child: Icon(icon, color: Colors.white, size: iconSize),
      ),
    );
  }
}
