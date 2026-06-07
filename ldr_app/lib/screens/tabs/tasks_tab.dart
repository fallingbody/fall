import 'package:flutter/material.dart';

class TasksTab extends StatelessWidget {
  const TasksTab({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Column(
        children: [
          const TabBar(
            labelColor: Colors.black,
            unselectedLabelColor: Colors.grey,
            indicatorColor: Colors.black,
            tabs: [
              Tab(text: 'Memories'),
              Tab(text: 'Calendar'),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                // Memories Grid (Instagram profile style)
                GridView.builder(
                  padding: const EdgeInsets.all(2),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    crossAxisSpacing: 2,
                    mainAxisSpacing: 2,
                  ),
                  itemCount: 15,
                  itemBuilder: (context, index) {
                    return Container(
                      color: Colors.grey.shade300,
                      child: const Center(child: Icon(Icons.photo, color: Colors.white)),
                    );
                  },
                ),
                // Calendar Placeholder
                ListView(
                  padding: const EdgeInsets.all(16),
                  children: const [
                    Text('Shared Calendar', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                    SizedBox(height: 20),
                    Center(child: Text('Calendar widget will be embedded here.')),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
