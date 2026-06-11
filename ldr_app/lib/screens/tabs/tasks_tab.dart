import 'package:flutter/material.dart';
import 'package:table_calendar/table_calendar.dart';

class TasksTab extends StatefulWidget {
  const TasksTab({super.key});

  @override
  State<TasksTab> createState() => _TasksTabState();
}

class _TasksTabState extends State<TasksTab> {
  DateTime _focusedDay = DateTime.now();
  DateTime? _selectedDay;

  @override
  void initState() {
    super.initState();
    _selectedDay = _focusedDay;
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    
    return DefaultTabController(
      length: 2,
      child: Column(
        children: [
          TabBar(
            labelColor: isDark ? Colors.white : Colors.black,
            unselectedLabelColor: Colors.grey,
            indicatorColor: isDark ? Colors.white : Colors.black,
            tabs: const [
              Tab(text: 'Memories'),
              Tab(text: 'Achievements'),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                // Memories Tab
                _buildMemoriesTab(isDark),
                
                // Achievements Tab
                _buildAchievementsTab(isDark),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMemoriesTab(bool isDark) {
    return Column(
      children: [
        TableCalendar(
          firstDay: DateTime.utc(2020, 10, 16),
          lastDay: DateTime.utc(2030, 3, 14),
          focusedDay: _focusedDay,
          selectedDayPredicate: (day) => isSameDay(_selectedDay, day),
          onDaySelected: (selectedDay, focusedDay) {
            setState(() {
              _selectedDay = selectedDay;
              _focusedDay = focusedDay;
            });
          },
          calendarStyle: CalendarStyle(
            selectedDecoration: const BoxDecoration(
              color: Colors.pinkAccent,
              shape: BoxShape.circle,
            ),
            todayDecoration: BoxDecoration(
              color: Colors.pinkAccent.withOpacity(0.5),
              shape: BoxShape.circle,
            ),
            defaultTextStyle: TextStyle(color: isDark ? Colors.white : Colors.black),
            weekendTextStyle: TextStyle(color: isDark ? Colors.grey.shade400 : Colors.grey.shade600),
          ),
          headerStyle: HeaderStyle(
            formatButtonVisible: false,
            titleCentered: true,
            titleTextStyle: TextStyle(color: isDark ? Colors.white : Colors.black, fontSize: 16, fontWeight: FontWeight.bold),
            leftChevronIcon: Icon(Icons.chevron_left, color: isDark ? Colors.white : Colors.black),
            rightChevronIcon: Icon(Icons.chevron_right, color: isDark ? Colors.white : Colors.black),
          ),
        ),
        const Divider(),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    _selectedDay != null 
                        ? '${_selectedDay!.day}/${_selectedDay!.month}/${_selectedDay!.year} Notes' 
                        : 'Daily Notes',
                    style: TextStyle(
                      fontSize: 18, 
                      fontWeight: FontWeight.bold,
                      color: isDark ? Colors.white : Colors.black,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.edit, color: Colors.pinkAccent),
                    onPressed: () {
                      // Show add note dialog
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Note editing coming soon!')));
                    },
                  )
                ],
              ),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: isDark ? Colors.grey.shade900 : Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  'No notes written for this day yet. Tap the edit icon to write something memorable!',
                  style: TextStyle(color: isDark ? Colors.grey.shade500 : Colors.grey.shade600, fontStyle: FontStyle.italic),
                ),
              ),
              const SizedBox(height: 24),
              Text(
                'Photos',
                style: TextStyle(
                  fontSize: 18, 
                  fontWeight: FontWeight.bold,
                  color: isDark ? Colors.white : Colors.black,
                ),
              ),
              const SizedBox(height: 8),
              GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                padding: const EdgeInsets.all(2),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  crossAxisSpacing: 2,
                  mainAxisSpacing: 2,
                ),
                itemCount: 6,
                itemBuilder: (context, index) {
                  return Container(
                    color: isDark ? Colors.grey.shade800 : Colors.grey.shade300,
                    child: Center(child: Icon(Icons.photo, color: isDark ? Colors.grey.shade600 : Colors.white)),
                  );
                },
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildAchievementsTab(bool isDark) {
    final achievements = [
      {'title': 'First Call', 'desc': 'Completed your first 1-hour call.', 'icon': Icons.call, 'unlocked': true},
      {'title': 'Movie Night', 'desc': 'Watched a movie together.', 'icon': Icons.movie, 'unlocked': true},
      {'title': '100 Messages', 'desc': 'Sent over 100 messages.', 'icon': Icons.message, 'unlocked': false},
      {'title': '1 Year Anniversary', 'desc': 'Celebrating 365 days!', 'icon': Icons.cake, 'unlocked': false},
    ];

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: achievements.length,
      itemBuilder: (context, index) {
        final a = achievements[index];
        final unlocked = a['unlocked'] as bool;
        return Card(
          color: isDark ? Colors.grey.shade900 : Colors.white,
          margin: const EdgeInsets.only(bottom: 12),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          child: ListTile(
            leading: CircleAvatar(
              backgroundColor: unlocked ? Colors.amber.withOpacity(0.2) : Colors.grey.withOpacity(0.2),
              child: Icon(a['icon'] as IconData, color: unlocked ? Colors.amber : Colors.grey),
            ),
            title: Text(
              a['title'] as String,
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: unlocked ? (isDark ? Colors.white : Colors.black) : Colors.grey,
              ),
            ),
            subtitle: Text(
              a['desc'] as String,
              style: TextStyle(
                color: unlocked ? (isDark ? Colors.grey.shade400 : Colors.grey.shade700) : Colors.grey,
              ),
            ),
            trailing: unlocked ? const Icon(Icons.check_circle, color: Colors.green) : const Icon(Icons.lock, color: Colors.grey),
          ),
        );
      },
    );
  }
}
