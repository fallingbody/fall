import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:permission_handler/permission_handler.dart';

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
  MediaStream? _screenStream;
  SignalingService? _signaling;

  bool _isConnecting = true;
  bool _isRequestingVideo = false;
  bool _micMuted = false;
  late bool _videoMuted;
  late bool _speakerOn;
  bool _isScreenSharing = false;
  late bool _isVideoMode;

  bool _hasRemoteTrack = false;
  bool _offerCreated = false;
  bool _isRemoteDescriptionSet = false;
  final List<Map<String, dynamic>> _remoteCandidates = [];

  Timer? _callDurationTimer;
  int _callDuration = 0;
  
  bool _incomingVideoRequest = false;
  bool _wasVideoModeBeforeScreenShare = false;

  @override
  void initState() {
    super.initState();
    _isVideoMode = widget.isVideoCall;
    _videoMuted = !_isVideoMode;
    _speakerOn = _isVideoMode;
    _initWebrtc();
  }

  void _startCallDurationTimer() {
    _callDurationTimer ??= Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted) {
        setState(() {
          _callDuration++;
        });
      }
    });
  }

  String get _formattedDuration {
    final minutes = (_callDuration ~/ 60).toString().padLeft(2, '0');
    final seconds = (_callDuration % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
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
    await _startForegroundService();

    setState(() {
      _isConnecting = false;
    });
  }

  Future<void> _getUserMedia() async {
    final Map<String, dynamic> mediaConstraints = {
      'audio': true,
      'video': _isVideoMode ? {
        'facingMode': 'user',
      } : false,
    };

    try {
      _localStream = await navigator.mediaDevices.getUserMedia(mediaConstraints);
      _localRenderer.srcObject = _localStream;

      // Apply initial mute states
      if (_localStream!.getAudioTracks().isNotEmpty) {
        _localStream!.getAudioTracks()[0].enabled = !_micMuted;
      }
      if (_isVideoMode && _localStream!.getVideoTracks().isNotEmpty) {
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
      _remoteRenderer.srcObject = stream;
      _remoteStream = stream;
      if (mounted) {
        setState(() {
          _hasRemoteTrack = true;
        });
        _startCallDurationTimer();
      }
    };

    _peerConnection!.onTrack = (event) {
      if (event.track.kind == 'video') {
        if (mounted) {
          setState(() {
            _remoteRenderer.srcObject = null;
          });
          Future.delayed(const Duration(milliseconds: 50), () {
            if (mounted) {
              setState(() {
                if (event.streams.isNotEmpty) {
                  _remoteRenderer.srcObject = event.streams[0];
                  _remoteStream = event.streams[0];
                } else if (_remoteStream != null) {
                  _remoteStream!.addTrack(event.track);
                  _remoteRenderer.srcObject = _remoteStream;
                }
                _hasRemoteTrack = true;
                _isVideoMode = true;
              });
            }
          });
        }
      } else {
        if (event.streams.isNotEmpty) {
          _remoteRenderer.srcObject = event.streams[0];
          _remoteStream = event.streams[0];
          if (mounted) {
            setState(() {
              _hasRemoteTrack = true;
            });
            _startCallDurationTimer();
          }
        } else if (_remoteStream != null) {
          _remoteStream!.addTrack(event.track);
          _remoteRenderer.srcObject = _remoteStream;
        }
      }
    };

    if (_localStream != null) {
      _localStream!.getTracks().forEach((track) {
        _peerConnection!.addTrack(track, _localStream!);
      });
    }

    return _peerConnection!;
  }



  Future<void> _createOffer() async {
    _isRemoteDescriptionSet = false;
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
        _isRemoteDescriptionSet = false;
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
        break;
      case 'answer':
        if (_peerConnection != null) {
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
        if (mounted) {
          setState(() {
            _incomingVideoRequest = true;
          });
        }
        break;
      case 'VIDEO_ACCEPT':
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Partner accepted video request!')));
        }
        _upgradeToVideoCall(isInitiator: true);
        break;
      case 'SCREEN_SHARE_START':
        if (mounted) {
          setState(() {
            _isVideoMode = true;
          });
        }
        break;
      case 'SCREEN_SHARE_STOP':
        if (mounted) {
          setState(() {
            if (_localStream?.getVideoTracks().isEmpty == true || _videoMuted) {
              _isVideoMode = false;
            }
          });
        }
        break;
      case 'call_ended':
      case 'peer_left':
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
    _callDurationTimer?.cancel();
    _screenStream?.getTracks().forEach((track) => track.stop());
    _screenStream?.dispose();
    _localStream?.dispose();
    _remoteStream?.dispose();
    _peerConnection?.close();
    _peerConnection?.dispose();
    _localRenderer.dispose();
    _remoteRenderer.dispose();
    _signaling?.disconnect();
    
    if (WebRTC.platformIsAndroid) {
      try {
        FlutterForegroundTask.stopService();
      } catch (e) {
        debugPrint('Error stopping call foreground service: $e');
      }
    }
    super.dispose();
  }

  Future<void> _startForegroundService() async {
    if (WebRTC.platformIsAndroid) {
      try {
        final status = await Permission.notification.request();
        if (status.isDenied) {
          debugPrint('Notification permission denied');
        }

        FlutterForegroundTask.init(
          androidNotificationOptions: AndroidNotificationOptions(
            channelId: 'active_call',
            channelName: 'Active Call',
            channelDescription: 'VoIP Call is active.',
            channelImportance: NotificationChannelImportance.LOW,
            priority: NotificationPriority.LOW,
          ),
          iosNotificationOptions: const IOSNotificationOptions(),
          foregroundTaskOptions: ForegroundTaskOptions(
            eventAction: ForegroundTaskEventAction.nothing(),
            autoRunOnBoot: false,
            allowWakeLock: true,
            allowWifiLock: true,
          ),
        );

        await FlutterForegroundTask.startService(
          notificationTitle: 'Active Call',
          notificationText: 'Tap to return to call',
        );
      } catch (e) {
        debugPrint('Error starting call foreground service: $e');
      }
    }
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
      if (_isRequestingVideo) return;
      _isRequestingVideo = true;
      _signaling?.sendMessage('VIDEO_REQUEST', {});
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Sent video request to partner...')));
      }
      
      // Reset the throttle after some time in case partner ignores
      Future.delayed(const Duration(seconds: 5), () {
        if (mounted) setState(() => _isRequestingVideo = false);
      });
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
        final Map<String, dynamic> mediaConstraints = {
          'audio': false,
          'video': true,
        };
        
        _screenStream = await navigator.mediaDevices.getDisplayMedia(mediaConstraints);
        
        _wasVideoModeBeforeScreenShare = _isVideoMode && !_videoMuted;
        
        // Get the new screen share track
        final newVideoTrack = _screenStream!.getVideoTracks().first;
        
        bool replaced = false;
        final senders = await _peerConnection!.getSenders();
        for (var sender in senders) {
          if (sender.track?.kind == 'video') {
            await sender.replaceTrack(newVideoTrack);
            replaced = true;
            break;
          }
        }
        
        if (!replaced) {
          await _peerConnection!.addTransceiver(
            track: newVideoTrack,
            init: RTCRtpTransceiverInit(
              direction: TransceiverDirection.SendOnly,
              streams: [_localStream!],
            ),
          );
          if (mounted) {
            setState(() {
              _isVideoMode = true;
            });
          }
          _createOffer();
        }

        // Stop and release camera video track to release camera and LED AFTER replacing
        final cameraTrack = _localStream?.getVideoTracks().isNotEmpty == true 
            ? _localStream!.getVideoTracks().first 
            : null;
        if (cameraTrack != null) {
          _localStream!.removeTrack(cameraTrack);
          cameraTrack.stop();
        }
        
        // Add screen share track to local stream
        _localStream?.addTrack(newVideoTrack);
        
        _localRenderer.srcObject = null;
        
        // Notify partner that screen share has started
        _signaling?.sendMessage('SCREEN_SHARE_START', {});
        
        newVideoTrack.onEnded = () {
           _stopScreenShare();
        };
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
     
     if (_wasVideoModeBeforeScreenShare) {
       // Re-acquire camera
       final Map<String, dynamic> mediaConstraints = {
         'audio': false,
         'video': {'facingMode': 'user'},
       };
       try {
         final videoStream = await navigator.mediaDevices.getUserMedia(mediaConstraints);
         final cameraVideoTrack = videoStream.getVideoTracks().first;
         
         for (var sender in senders) {
           if (sender.track?.kind == 'video') {
             await sender.replaceTrack(cameraVideoTrack);
             break;
           }
         }
         
         final screenTrack = _screenStream?.getVideoTracks().isNotEmpty == true ? _screenStream!.getVideoTracks().first : null;
         if (screenTrack != null && _localStream != null) {
           _localStream!.removeTrack(screenTrack);
         }
         
         _localStream?.addTrack(cameraVideoTrack);
         _localRenderer.srcObject = _localStream;
       } catch (e) {
         debugPrint('Failed to restart camera after screen share: $e');
       }
     } else {
       // We were in audio call. Remove video sender and renegotiate.
       for (var sender in senders) {
         if (sender.track?.kind == 'video') {
           await _peerConnection!.removeTrack(sender);
           _createOffer();
           break;
         }
       }
       
       final screenTrack = _screenStream?.getVideoTracks().isNotEmpty == true ? _screenStream!.getVideoTracks().first : null;
       if (screenTrack != null && _localStream != null) {
         _localStream!.removeTrack(screenTrack);
       }
       
       _localRenderer.srcObject = _localStream;
     }
     
     // Stop screen sharing tracks after replacing
     _screenStream?.getTracks().forEach((track) => track.stop());
     _screenStream = null;
     
     _signaling?.sendMessage('SCREEN_SHARE_STOP', {});
     
     if (mounted) {
       setState(() {
         _isScreenSharing = false;
         _isVideoMode = _wasVideoModeBeforeScreenShare;
       });
     }
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
                      _hasRemoteTrack ? _formattedDuration : 'Ringing...', 
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
                  child: _isScreenSharing
                      ? const Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.screen_share, color: Colors.greenAccent, size: 24),
                              SizedBox(height: 8),
                              Text(
                                'Sharing...',
                                style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
                              ),
                            ],
                          ),
                        )
                      : RTCVideoView(_localRenderer, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover, mirror: !_isScreenSharing),
                ),
              ),
            ),

          // Screen Sharing Status Banner
          if (_isScreenSharing)
            Positioned(
              top: 10,
              left: 20,
              right: 20,
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
                decoration: BoxDecoration(
                  color: Colors.black87,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: Colors.greenAccent, width: 1.5),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.greenAccent.withValues(alpha: 0.3),
                      blurRadius: 8,
                      spreadRadius: 1,
                    ),
                  ],
                ),
                child: const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.screen_share, color: Colors.greenAccent, size: 20),
                    SizedBox(width: 8),
                    Text(
                      'You are sharing your screen',
                      style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold),
                    ),
                  ],
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
          if (_incomingVideoRequest)
            _buildVideoRequestDialogOverlay(),
        ],
      ),
    );
  }

  Widget _buildVideoRequestDialogOverlay() {
    return Positioned.fill(
      child: Container(
        color: Colors.black54,
        child: Center(
          child: Container(
            margin: const EdgeInsets.all(32),
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: Colors.grey.shade900,
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: Colors.white24, width: 1),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.videocam, color: Colors.pinkAccent, size: 48),
                const SizedBox(height: 16),
                const Text(
                  'Video Request',
                  style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                Text(
                  '${widget.participantName} wants to turn on their camera.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70, fontSize: 16),
                ),
                const SizedBox(height: 24),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.redAccent,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      onPressed: () {
                        setState(() {
                          _incomingVideoRequest = false;
                        });
                      },
                      child: const Text('Deny'),
                    ),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.green,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      onPressed: () async {
                        setState(() {
                          _incomingVideoRequest = false;
                        });
                        await _upgradeToVideoCall(isInitiator: false);
                        _signaling?.sendMessage('VIDEO_ACCEPT', {});
                      },
                      child: const Text('Accept'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
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

  Future<void> _upgradeToVideoCall({required bool isInitiator}) async {
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
          await _peerConnection!.addTrack(videoTrack, _localStream!);
        }
      }

      if (mounted) {
        setState(() {
          _isVideoMode = true;
          _videoMuted = false;
          _isRequestingVideo = false;
        });
      }

      // Only the initiator generates the offer after both parties have enabled their cameras
      if (isInitiator) {
        _createOffer();
      }
    } catch (e) {
      debugPrint('Failed to upgrade to video: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to access camera: $e')));
        setState(() => _isRequestingVideo = false);
      }
    }
  }


}
