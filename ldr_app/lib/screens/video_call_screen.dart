import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_background/flutter_background.dart';
import '../services/livekit_service.dart';

class VideoCallScreen extends StatefulWidget {
  final String roomName;
  final String participantName;
  final String participantId;
  final bool isVideoCall;

  const VideoCallScreen({
    super.key, 
    required this.roomName, 
    required this.participantName,
    required this.participantId,
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
  late bool _speakerOn;
  bool _isScreenSharing = false;
  late bool _isVideoMode;

  Participant? _remoteParticipant;

  @override
  void initState() {
    super.initState();
    _isVideoMode = widget.isVideoCall;
    _videoMuted = !_isVideoMode;
    _speakerOn = _isVideoMode;
    _connect();
  }

  Future<void> _connect() async {
    try {
      final token = LiveKitService.generateToken(roomName: widget.roomName, participantName: widget.participantName, participantId: widget.participantId);
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
        } else if (event is DataReceivedEvent) {
          try {
            final payload = utf8.decode(event.data);
            if (payload == 'VIDEO_REQUEST') {
              _showVideoRequestDialog();
            } else if (payload == 'VIDEO_ACCEPT') {
              setState(() {
                _isVideoMode = true;
              });
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Partner accepted video request!')));
              }
            }
          } catch (e) {
            debugPrint('Error parsing data channel: $e');
          }
        }
      });

      await _room.connect(url, token);
      
      await _room.localParticipant?.setCameraEnabled(_isVideoMode);
      await _room.localParticipant?.setMicrophoneEnabled(true);
      await Hardware.instance.setSpeakerphoneOn(_speakerOn);

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

    // If in audio mode and trying to turn on video
    if (!_isVideoMode && _videoMuted) {
      // 1. Turn on local camera
      await _room.localParticipant!.setCameraEnabled(true);

      // 2. Turn on speaker
      await Hardware.instance.setSpeakerphoneOn(true);

      // 3. Send request to partner
      await _room.localParticipant?.publishData(utf8.encode('VIDEO_REQUEST'));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Sent video request to partner...')));
      }

      // 4. Update local state
      setState(() {
        _videoMuted = false; // Video is now ON
        _speakerOn = true;   // Speaker is now ON
      });
      return;
    }

    // This part handles turning video on/off during an established video call
    final bool newMutedState = !_videoMuted;
    await _room.localParticipant!.setCameraEnabled(!newMutedState);

    setState(() => _videoMuted = newMutedState);
  }

  void _toggleSpeaker() async {
    bool nextState = !_speakerOn;
    await Hardware.instance.setSpeakerphoneOn(nextState);
    setState(() => _speakerOn = nextState);
  }

  Future<bool> _ensureForegroundService() async {
    if (WebRTC.platformIsAndroid) {
      const config = FlutterBackgroundAndroidConfig(
        notificationTitle: 'Screen Sharing',
        notificationText: 'Your screen is currently being shared.',
        notificationImportance: AndroidNotificationImportance.normal,
        notificationIcon: AndroidResource(name: 'ic_launcher', defType: 'mipmap'),
      );
      // Ensure initialization happens before enabling execution. This is safer as it
      // ensures the plugin is initialized in the current app lifecycle.
      await FlutterBackground.initialize(androidConfig: config);

      // The initialize() call handles asking for permissions if not yet granted.
      return await FlutterBackground.enableBackgroundExecution();
    }
    return true;
  }

  void _toggleScreenShare() async {
    if (_room.localParticipant == null) return;
    bool nextState = !_isScreenSharing;
    try {
      if (nextState) {
        final bgSuccess = await _ensureForegroundService();
        if (!bgSuccess) {
          throw Exception('Failed to start foreground service. Please grant permissions.');
        }
      }

      await _room.localParticipant!.setScreenShareEnabled(nextState, captureScreenAudio: true);
      
      // Fix Browser Audio Ducking on Android:
      if (WebRTC.platformIsAndroid) {
        if (nextState) {
          await Helper.setAndroidAudioConfiguration(
            AndroidAudioConfiguration(
              manageAudioFocus: false,
              androidAudioMode: AndroidAudioMode.normal,
              androidAudioAttributesUsageType: AndroidAudioAttributesUsageType.media,
              androidAudioStreamType: AndroidAudioStreamType.music,
            ),
          );
        } else {
          await Helper.setAndroidAudioConfiguration(AndroidAudioConfiguration.communication);
          await FlutterBackground.disableBackgroundExecution();
        }
      }
      
      setState(() => _isScreenSharing = nextState);
    } catch (e) {
      debugPrint('Error toggling screen share: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Could not share screen: $e'),
          backgroundColor: Colors.redAccent,
        ));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isConnecting) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(child: CircularProgressIndicator(color: Colors.white)),
      );
    }

    // Get remote video track (prioritize screen share if available)
    VideoTrack? remoteVideoTrack;
    if (_remoteParticipant != null) {
      // 1. Try to find a screen share track first
      final screenSharePubs = _remoteParticipant!.videoTrackPublications.where((p) => p.source == TrackSource.screenShareVideo && p.track != null).toList();
      
      if (screenSharePubs.isNotEmpty) {
        remoteVideoTrack = screenSharePubs.first.track as VideoTrack;
      } else {
        // 2. Fallback to camera track
        final cameraPubs = _remoteParticipant!.videoTrackPublications.where((p) => p.track != null).toList();
        if (cameraPubs.isNotEmpty) {
          remoteVideoTrack = cameraPubs.first.track as VideoTrack;
        }
      }
    }

    // Get local video track
    VideoTrack? localVideoTrack;
    if (_room.localParticipant != null) {
      for (var pub in _room.localParticipant!.videoTrackPublications) {
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
          if (!_isVideoMode && remoteVideoTrack == null)
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
              child: VideoTrackRenderer(remoteVideoTrack, fit: VideoViewFit.contain),
            )
          else if (!_videoMuted)
            const Center(
              child: Text('Waiting for partner...', style: TextStyle(color: Colors.white, fontSize: 18)),
            ),

          // Local Video (PiP)
          if (localVideoTrack != null && !_videoMuted)
            Positioned(
              right: 20,
              top: 60,
              width: 110,
              height: 160,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  color: Colors.grey.shade900,
                  child: VideoTrackRenderer(localVideoTrack, fit: VideoViewFit.cover),
                ),
              ),
            ),

          // Controls
          Positioned(
            bottom: 40,
            left: 0,
            right: 0,
            child: Wrap(
              alignment: WrapAlignment.center,
              spacing: 15,
              children: [
                _buildControlButton(
                  icon: _speakerOn ? Icons.volume_up : Icons.volume_down,
                  color: _speakerOn ? Colors.blueAccent : Colors.white24,
                  onPressed: _toggleSpeaker,
                  size: 50,
                  iconSize: 22,
                ),
                _buildControlButton(
                  icon: _micMuted ? Icons.mic_off : Icons.mic,
                  color: _micMuted ? Colors.red : Colors.white24,
                  onPressed: _toggleMic,
                  size: 50,
                  iconSize: 22,
                ),
                _buildControlButton(
                  icon: Icons.call_end,
                  color: Colors.red,
                  size: 64,
                  iconSize: 32,
                  onPressed: () => Navigator.pop(context),
                ),
                _buildControlButton(
                  icon: _videoMuted ? Icons.videocam_off : Icons.videocam,
                  color: _videoMuted ? Colors.red : Colors.white24,
                  onPressed: _toggleVideo,
                  size: 50,
                  iconSize: 22,
                ),
                _buildControlButton(
                  icon: _isScreenSharing ? Icons.stop_screen_share : Icons.screen_share,
                  color: _isScreenSharing ? Colors.green : Colors.white24,
                  onPressed: _toggleScreenShare,
                  size: 50,
                  iconSize: 22,
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

  void _showVideoRequestDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Video Request'),
        content: Text('${widget.participantName} wants to turn on their camera.'),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(context);
            },
            child: const Text('Deny', style: TextStyle(color: Colors.red)),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _room.localParticipant?.publishData(utf8.encode('VIDEO_ACCEPT'));
              setState(() {
                _isVideoMode = true;
              });
            },
            child: const Text('Accept', style: TextStyle(color: Colors.green)),
          ),
        ],
      ),
    );
  }
}
