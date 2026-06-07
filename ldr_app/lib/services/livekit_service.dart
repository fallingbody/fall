import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

class LiveKitService {
  static String generateToken({required String roomName, required String participantName}) {
    final apiKey = dotenv.env['LIVEKIT_API_KEY'];
    final apiSecret = dotenv.env['LIVEKIT_API_SECRET'];

    if (apiKey == null || apiSecret == null) {
      throw Exception('Missing LiveKit credentials in .env');
    }

    final jwt = JWT(
      {
        'name': participantName,
        'video': {
          'room': roomName,
          'roomJoin': true,
        }
      },
      issuer: apiKey,
      subject: participantName, // Need a unique ID here ideally, but name is fine for test
    );

    // LiveKit tokens must have a valid exp (e.g. 2 hours) and nbf
    final token = jwt.sign(
      SecretKey(apiSecret),
      algorithm: JWTAlgorithm.HS256,
      expiresIn: const Duration(hours: 2),
    );

    return token;
  }
}
