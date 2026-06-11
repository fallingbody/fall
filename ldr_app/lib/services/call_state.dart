import 'package:flutter/foundation.dart';

class CallData {
  final String roomId;
  final String callerName;
  final bool isVideo;
  final bool isCaller;

  CallData({
    required this.roomId,
    required this.callerName,
    required this.isVideo,
    required this.isCaller,
  });
}

final ValueNotifier<CallData?> globalCallState = ValueNotifier(null);
