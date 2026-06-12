import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../services/signaling_service.dart';

class VideoCallScreen extends StatefulWidget {
  final String roomName;
  final String participantName;
  final String participantId;
  final bool isVideoCall;
  final bool isMinimized;
  final bool isCaller;
  final VoidCallback? onToggleMinimize;
  final VoidCallback? onEndCall;

  const VideoCallScreen({
    super.key,
    required this.roomName,
    required this.participantName,
    required this.participantId,
    required this.isVideoCall,
    this.isMinimized = false,
    required this.isCaller,
    this.onToggleMinimize,
    this.onEndCall,
  });

  @override
  State<VideoCallScreen> createState() => _VideoCallScreenState();
}

class _VideoCallScreenState extends State<VideoCallScreen> {
  final RTCVideoRenderer _localRenderer = RTCVideoRenderer();
  final RTCVideoRenderer _remoteRenderer = RTCVideoRenderer();
  
  RTCPeerConnection? _peerConnection;
  MediaStream? _localStream;
  MediaStream? _remoteStream;
  SignalingService? _signaling;

  bool _isConnecting = true;
  bool _micMuted = false;
  late bool _videoMuted;
  late bool _speakerOn;
  bool _isScreenSharing = false;
  late bool _isVideoMode;

  bool _hasRemoteTrack = false;
  bool _offerCreated = false;
  bool _isRemoteDescriptionSet = false;
  final List<Map<String, dynamic>> _remoteCandidates = [];

  @override
  void initState() {
    super.initState();
    _isVideoMode = widget.isVideoCall;
    _videoMuted = !_isVideoMode;
    _speakerOn = _isVideoMode;
    _initWebrtc();
  }

  Future<void> _initWebrtc() async {
    await _localRenderer.initialize();
    await _remoteRenderer.initialize();

    _signaling = SignalingService(
      roomName: widget.roomName,
      localParticipantId: widget.participantId,
    );
    _signaling!.onMessage = _handleSignalingMessage;

    await _getUserMedia();
    await _signaling!.connect();

    setState(() {
      _isConnecting = false;
    });
  }

  Future<void> _getUserMedia() async {
    final Map<String, dynamic> mediaConstraints = {
      'audio': true,
      'video': {
        'facingMode': 'user',
      }
    };

    try {
      _localStream = await navigator.mediaDevices.getUserMedia(mediaConstraints);
      _localRenderer.srcObject = _localStream;

      // Apply initial mute states
      if (_localStream!.getAudioTracks().isNotEmpty) {
        _localStream!.getAudioTracks()[0].enabled = !_micMuted;
      }
      if (_localStream!.getVideoTracks().isNotEmpty) {
        _localStream!.getVideoTracks()[0].enabled = !_videoMuted;
      }

      await Helper.setSpeakerphoneOn(_speakerOn);
    } catch (e) {
      debugPrint('Failed to get user media: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Could not access camera/mic: $e'),
          backgroundColor: Colors.redAccent,
        ));
      }
    }
  }

  Future<RTCPeerConnection> _createPeerConnection() async {
    if (_peerConnection != null) return _peerConnection!;

    final configuration = {
      'iceServers': [
        {'url': 'stun:stun.l.google.com:19302'},
        {'url': 'stun:stun1.l.google.com:19302'},
        {
          'url': 'turn:openrelay.metered.ca:80',
          'username': 'openrelayproject',
          'credential': 'openrelayproject'
        },
        {
          'url': 'turn:openrelay.metered.ca:443',
          'username': 'openrelayproject',
          'credential': 'openrelayproject'
        },
      ]
    };

    _peerConnection = await createPeerConnection(configuration);

    _peerConnection!.onIceCandidate = (candidate) {
      if (candidate.candidate == null) return;
      _signaling!.sendMessage('ice_candidate', {
        'candidate': candidate.candidate,
        'sdpMid': candidate.sdpMid,
        'sdpMLineIndex': candidate.sdpMLineIndex,
      });
    };

    _peerConnection!.onAddStream = (stream) {
      _remoteStream = stream;
      if (stream.getVideoTracks().isNotEmpty) {
        _remoteRenderer.srcObject = _remoteStream;
      }
      setState(() {
        _hasRemoteTrack = true;
      });
    };

    _peerConnection!.onTrack = (event) {
      if (event.streams.isNotEmpty) {
        _remoteStream = event.streams[0];
        if (event.track.kind == 'video') {
          _remoteRenderer.srcObject = _remoteStream;
        }
      }
      setState(() {
        _hasRemoteTrack = true;
      });
    };

    if (_localStream != null) {
      _localStream!.getTracks().forEach((track) {
        _peerConnection!.addTrack(track, _localStream!);
      });
    }

    return _peerConnection!;
  }



  Future<void> _createOffer() async {
    final pc = await _createPeerConnection();
    final offer = await pc.createOffer({
      'offerToReceiveAudio': 1,
      'offerToReceiveVideo': 1,
    });
    await pc.setLocalDescription(offer);
    
    _signaling!.sendMessage('offer', {
      'sdp': offer.sdp,
      'type': offer.type,
    });
  }

  void _handleSignalingMessage(String type, Map<String, dynamic> data, String senderId) async {
    // If we receive ANY signaling message from the peer, they are present! We can stop pinging.
    _signaling?.pingTimer?.cancel();

    switch (type) {
      case 'peer_joined':
        // Only the caller initiates the offer to prevent glare
        if (widget.isCaller && !_offerCreated) {
          _offerCreated = true;
          _createOffer();
        }
        break;
      case 'offer':
        if (!widget.isCaller) {
          final pc = await _createPeerConnection();
          await pc.setRemoteDescription(RTCSessionDescription(data['sdp'], data['type']));
          _isRemoteDescriptionSet = true;
          _processQueuedCandidates();
          
          final answer = await pc.createAnswer();
          await pc.setLocalDescription(answer);
          _signaling!.sendMessage('answer', {
            'sdp': answer.sdp,
            'type': answer.type,
          });
        }
        break;
      case 'answer':
        if (widget.isCaller && _peerConnection != null) {
          await _peerConnection!.setRemoteDescription(RTCSessionDescription(data['sdp'], data['type']));
          _isRemoteDescriptionSet = true;
          _processQueuedCandidates();
        }
        break;
      case 'ice_candidate':
        if (_isRemoteDescriptionSet && _peerConnection != null) {
          await _peerConnection!.addCandidate(RTCIceCandidate(
            data['candidate'],
            data['sdpMid'],
            data['sdpMLineIndex'],
          ));
        } else {
          _remoteCandidates.add(data);
        }
        break;
      case 'VIDEO_REQUEST':
        _showVideoRequestDialog();
        break;
      case 'VIDEO_ACCEPT':
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Partner accepted video request!')));
        }
        _upgradeToVideoCall();
        break;
      case 'call_ended':
        _terminateCallLocally();
        break;
    }
  }

  Future<void> _processQueuedCandidates() async {
    if (_peerConnection == null) return;
    for (var data in _remoteCandidates) {
      await _peerConnection!.addCandidate(RTCIceCandidate(
        data['candidate'],
        data['sdpMid'],
        data['sdpMLineIndex'],
      ));
    }
    _remoteCandidates.clear();
  }

  @override
  void dispose() {
    _localStream?.dispose();
    _remoteStream?.dispose();
    _peerConnection?.close();
    _peerConnection?.dispose();
    _localRenderer.dispose();
    _remoteRenderer.dispose();
    _signaling?.disconnect();
    super.dispose();
  }

  void _toggleMic() {
    if (_localStream != null && _localStream!.getAudioTracks().isNotEmpty) {
      final track = _localStream!.getAudioTracks()[0];
      track.enabled = _micMuted;
      setState(() => _micMuted = !_micMuted);
    }
  }

  void _toggleVideo() async {
    // If in audio mode and trying to turn on video
    if (!_isVideoMode) {
      _signaling?.sendMessage('VIDEO_REQUEST', {});
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Sent video request to partner...')));
      }
      return;
    }

    final bool newMutedState = !_videoMuted;
    if (_localStream != null && _localStream!.getVideoTracks().isNotEmpty) {
      _localStream!.getVideoTracks()[0].enabled = !newMutedState;
    }

    setState(() => _videoMuted = newMutedState);
  }

  void _toggleSpeaker() async {
    bool nextState = !_speakerOn;
    await Helper.setSpeakerphoneOn(nextState);
    setState(() => _speakerOn = nextState);
  }

  void _toggleScreenShare() async {
    if (_peerConnection == null) return;
    bool nextState = !_isScreenSharing;
    try {
      if (nextState) {
        if (WebRTC.platformIsAndroid) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Screen sharing is not supported on Android 14+ without a foreground service plugin.')));
          return;
        }

        final Map<String, dynamic> mediaConstraints = {
          'audio': false,
          'video': true,
        };
        
        final screenStream = await navigator.mediaDevices.getDisplayMedia(mediaConstraints);
        
        // Replace video track
        final oldVideoTrack = _localStream?.getVideoTracks().first;
        final newVideoTrack = screenStream.getVideoTracks().first;
        
        if (oldVideoTrack != null) {
          final senders = await _peerConnection!.getSenders();
          for (var sender in senders) {
            if (sender.track?.kind == 'video') {
              await sender.replaceTrack(newVideoTrack);
              break;
            }
          }
        }
        
        _localRenderer.srcObject = screenStream;
        
        newVideoTrack.onEnded = () {
           _stopScreenShare();
        };

        if (WebRTC.platformIsAndroid) {
          await Helper.setAndroidAudioConfiguration(
            AndroidAudioConfiguration(
              manageAudioFocus: false,
              androidAudioMode: AndroidAudioMode.normal,
              androidAudioAttributesUsageType: AndroidAudioAttributesUsageType.media,
              androidAudioStreamType: AndroidAudioStreamType.music,
            ),
          );
        }
      } else {
        _stopScreenShare();
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

  void _stopScreenShare() async {
     final senders = await _peerConnection!.getSenders();
     final cameraVideoTrack = _localStream?.getVideoTracks().first;
     
     if (cameraVideoTrack != null) {
        for (var sender in senders) {
          if (sender.track?.kind == 'video') {
            await sender.replaceTrack(cameraVideoTrack);
            break;
          }
        }
     }
     
     _localRenderer.srcObject = _localStream;
     
     if (WebRTC.platformIsAndroid) {
        await Helper.setAndroidAudioConfiguration(AndroidAudioConfiguration.communication);
     }
     setState(() => _isScreenSharing = false);
  }

  void _endCall() {
    _signaling?.sendMessage('call_ended', {});
    _terminateCallLocally();
  }

  void _terminateCallLocally() {
    if (widget.onEndCall != null) {
      widget.onEndCall!();
    } else {
      if (mounted) Navigator.of(context).pop();
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

    if (widget.isMinimized) {
      // Return PiP mode view
      return Stack(
        fit: StackFit.expand,
        children: [
          Container(color: Colors.black),
          if (!_videoMuted && _hasRemoteTrack)
            RTCVideoView(_remoteRenderer, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover)
          else
            const Center(child: Icon(Icons.call, color: Colors.white, size: 40)),
          if (!_micMuted)
             Positioned(top: 8, right: 8, child: Icon(Icons.mic, color: Colors.white, size: 16)),
        ],
      );
    }

    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.white),
        elevation: 0,
        actions: [
          if (widget.onToggleMinimize != null)
            IconButton(
              icon: const Icon(Icons.close_fullscreen, color: Colors.white),
              onPressed: widget.onToggleMinimize,
            ),
        ],
      ),
      body: Stack(
        children: [
          // Background for Audio Call
          if (!_isVideoMode)
            Positioned.fill(
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                  colors: [Colors.pink.shade800, Colors.pink.shade300],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
              ),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircleAvatar(
                      radius: 60,
                      backgroundColor: Colors.white,
                      child: Text(
                        widget.participantName.isNotEmpty ? widget.participantName[0].toUpperCase() : 'P', 
                        style: TextStyle(fontSize: 50, color: Colors.pink.shade800, fontWeight: FontWeight.bold)
                      ),
                    ),
                    const SizedBox(height: 24),
                    Text(
                      widget.participantName, 
                      style: const TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.bold)
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _hasRemoteTrack ? '00:00' : 'Ringing...', 
                      style: TextStyle(color: Colors.white.withOpacity(0.9), fontSize: 18)
                    ),
                  ],
                ),
              ),
            ),
            ),

          // Remote Video (Full Screen)
          if (_isVideoMode && _hasRemoteTrack)
            Positioned.fill(
              child: RTCVideoView(_remoteRenderer, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain),
            )
          else if (_isVideoMode && !_videoMuted)
            const Center(
              child: Text('Waiting for partner...', style: TextStyle(color: Colors.white, fontSize: 18)),
            ),

          // Local Video (PiP)
          if (_isVideoMode && _localStream != null && !_videoMuted)
            Positioned(
              right: 20,
              top: 60,
              width: 110,
              height: 160,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  color: Colors.grey.shade900,
                  child: RTCVideoView(_localRenderer, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover, mirror: !_isScreenSharing),
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
                  onPressed: _endCall,
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

  Future<void> _upgradeToVideoCall() async {
    final Map<String, dynamic> mediaConstraints = {
      'audio': false, // Audio is already running
      'video': {'facingMode': 'user'},
    };
    try {
      final videoStream = await navigator.mediaDevices.getUserMedia(mediaConstraints);
      final videoTrack = videoStream.getVideoTracks().first;

      _localStream?.addTrack(videoTrack);
      _localRenderer.srcObject = _localStream;

      if (_peerConnection != null) {
        final senders = await _peerConnection!.getSenders();
        bool replaced = false;
        for (var sender in senders) {
          if (sender.track?.kind == 'video') {
            await sender.replaceTrack(videoTrack);
            replaced = true;
            break;
          }
        }
        if (!replaced) {
          await _peerConnection!.addTransceiver(
            track: videoTrack,
            init: RTCRtpTransceiverInit(
              direction: TransceiverDirection.SendRecv,
              streams: [_localStream!],
            ),
          );
        }
      }

      setState(() {
        _isVideoMode = true;
        _videoMuted = false;
      });

      if (widget.isCaller) {
        _createOffer();
      }
    } catch (e) {
      debugPrint('Failed to upgrade to video: $e');
    }
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
              _signaling?.sendMessage('VIDEO_ACCEPT', {});
              _upgradeToVideoCall();
            },
            child: const Text('Accept', style: TextStyle(color: Colors.green)),
          ),
        ],
      ),
    );
  }
}
