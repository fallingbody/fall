import 'package:flutter/material.dart';

class AchievementsScreen extends StatelessWidget {
  const AchievementsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Achievements'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: const [
          ListTile(
            leading: Icon(Icons.emoji_events, color: Colors.amber, size: 40),
            title: Text('Chatterbox'),
            subtitle: Text('Sent 1,000 messages'),
            trailing: Icon(Icons.check_circle, color: Colors.green),
          ),
          ListTile(
            leading: Icon(Icons.nights_stay, color: Colors.blueGrey, size: 40),
            title: Text('Sleepyheads'),
            subtitle: Text('Slept in the virtual room together 5 times'),
            trailing: Icon(Icons.lock_outline),
          ),
        ],
      ),
    );
  }
}
