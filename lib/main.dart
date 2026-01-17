// main.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:csv/csv.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

// =============================================================
// CONFIG
// =============================================================
const String CHAR_UUID_TX = "6E400003-B5A3-F393-E0A9-E50E24DCCA9E";
const int SAMPLE_RATE_HZ = 100;

// =============================================================
// GLOBAL DEVICE STORAGE (for connection check)
// =============================================================
final GlobalKey<_AppShellState> appShellKey = GlobalKey<_AppShellState>();

class DeviceManager {
  static BluetoothDevice? leftDevice;
  static BluetoothDevice? rightDevice;

  static bool get isReady => leftDevice != null && rightDevice != null;

  static void setLeft(BluetoothDevice device) {
    leftDevice = device;
  }

  static void setRight(BluetoothDevice device) {
    rightDevice = device;
  }

  static void clear() {
    leftDevice = null;
    rightDevice = null;
  }
}

// =============================================================
// TEST HISTORY MANAGER
// =============================================================
class TestHistoryManager {
  static final List<Map<String, dynamic>> _testHistory = [];

  static List<Map<String, dynamic>> get history =>
      List.unmodifiable(_testHistory);

  static void addTest(Map<String, dynamic> result) {
    _testHistory.insert(0, {
      'date': DateTime.now().toIso8601String(),
      'duration': result['duration_s'] ?? 0,
      'totalSteps': result['total_steps'] ?? 0,
      'symmetry': result['symmetry_percent'],
      'cadence': result['cadence_spm'] ?? 0,
    });
  }

  static int get todayTestCount {
    final today = DateTime.now();
    return _testHistory.where((t) {
      final date = DateTime.parse(t['date']);
      return date.year == today.year &&
          date.month == today.month &&
          date.day == today.day;
    }).length;
  }

  static int get todayTotalSteps {
    final today = DateTime.now();
    return _testHistory
        .where((t) {
          final date = DateTime.parse(t['date']);
          return date.year == today.year &&
              date.month == today.month &&
              date.day == today.day;
        })
        .fold(0, (sum, t) => sum + (t['totalSteps'] as int? ?? 0));
  }
}

// =============================================================
// APP ENTRY
// =============================================================
void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'SafeStep',
      theme: ThemeData(
        primarySwatch: Colors.teal,
        primaryColor: Colors.teal,
        scaffoldBackgroundColor: const Color(
          0xFFE0F2F1,
        ), // Light cyan background
        appBarTheme: AppBarTheme(
          backgroundColor: Colors.teal.shade600,
          foregroundColor: Colors.white,
          elevation: 0,
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.teal.shade600,
            foregroundColor: Colors.white,
          ),
        ),
        cardTheme: const CardThemeData(color: Colors.white, elevation: 2),
      ),
      home: const SplashScreen(),
    );
  }
}

// =============================================================
// SPLASH SCREEN
// =============================================================
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _fade;
  bool _showSplash = true;

  @override
  void initState() {
    super.initState();

    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    );

    _fade = Tween<double>(
      begin: 1.0,
      end: 0.0,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));

    Future.delayed(const Duration(milliseconds: 1500), () {
      if (!mounted) return;
      _controller.forward();
    });

    _controller.addStatusListener((status) {
      if (status == AnimationStatus.completed && mounted) {
        setState(() {
          _showSplash = false;
        });
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          AppShell(key: appShellKey),
          if (_showSplash)
            Container(
              color: Colors.white,
              child: Center(
                child: FadeTransition(
                  opacity: _fade,
                  child: Image.asset(
                    'assets/Safe.png',
                    height: 180,
                    fit: BoxFit.contain,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// =============================================================
// APP SHELL (HEADER + FOOTER + NAVIGATION)
// =============================================================
class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  final GlobalKey<_AccountPageState> accountPageKey =
      GlobalKey<_AccountPageState>();
  int _currentIndex = 0;

  // expose a helper so Assignment page can jump to Account → Setup Device
  void goToAccountSetup() {
    setState(() {
      _currentIndex = 3;
    });
    accountPageKey.currentState?.openSetupDevice();
  }

  Future<void> _showReminderPopup(BuildContext context) async {
    final prefs = await SharedPreferences.getInstance();
    final remindersJson = prefs.getString('test_reminders');
    List<Map<String, dynamic>> reminders = [];

    if (remindersJson != null) {
      reminders = List<Map<String, dynamic>>.from(
        jsonDecode(remindersJson).map((x) => Map<String, dynamic>.from(x)),
      );
    }

    // Find the nearest upcoming reminder
    Map<String, dynamic>? nearestReminder;
    String nearestReminderText = '';

    if (reminders.isNotEmpty) {
      final now = TimeOfDay.now();
      final currentMinutes = now.hour * 60 + now.minute;
      final dayNames = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
      final todayIndex = DateTime.now().weekday - 1; // 0-6 for Mon-Sun

      int smallestDiff = 999999;

      for (final reminder in reminders) {
        // Parse time from stored string format "hour:minute"
        final timeStr = reminder['time'] as String? ?? '0:0';
        final timeParts = timeStr.split(':');
        final hour = int.tryParse(timeParts[0]) ?? 0;
        final minute = timeParts.length > 1
            ? (int.tryParse(timeParts[1]) ?? 0)
            : 0;
        final days = List<bool>.from(reminder['days'] ?? List.filled(7, false));

        final reminderMinutes = hour * 60 + minute;

        // Check today first
        if (days[todayIndex] && reminderMinutes > currentMinutes) {
          final diff = reminderMinutes - currentMinutes;
          if (diff < smallestDiff) {
            smallestDiff = diff;
            nearestReminder = reminder;
            final time = TimeOfDay(hour: hour, minute: minute);
            nearestReminderText = 'Today at ${time.format(context)}';
          }
        }

        // Check other days
        for (int i = 1; i <= 7; i++) {
          final checkDay = (todayIndex + i) % 7;
          if (days[checkDay]) {
            final diff = i * 24 * 60 + (reminderMinutes - currentMinutes);
            if (diff < smallestDiff) {
              smallestDiff = diff;
              nearestReminder = reminder;
              final time = TimeOfDay(hour: hour, minute: minute);
              if (i == 1) {
                nearestReminderText = 'Tomorrow at ${time.format(context)}';
              } else {
                nearestReminderText =
                    '${dayNames[checkDay]} at ${time.format(context)}';
              }
            }
            break; // Found nearest for this reminder
          }
        }
      }
    }

    if (!context.mounted) return;

    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Reminder Popup',
      barrierColor: Colors.black54,
      transitionDuration: const Duration(milliseconds: 300),
      pageBuilder: (context, anim1, anim2) {
        return Center(
          child: Material(
            color: Colors.transparent,
            child: Container(
              width: MediaQuery.of(context).size.width * 0.85,
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [Colors.white, Colors.teal.shade50],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(24),
                boxShadow: [
                  BoxShadow(
                    color: Colors.teal.withOpacity(0.3),
                    blurRadius: 20,
                    spreadRadius: 5,
                  ),
                ],
              ),
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  // Close button - larger tap area
                  Positioned(
                    top: -16,
                    right: -16,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => Navigator.pop(context),
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        child: Container(
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            color: Colors.grey.shade200,
                            shape: BoxShape.circle,
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.1),
                                blurRadius: 4,
                              ),
                            ],
                          ),
                          child: Icon(
                            Icons.close,
                            size: 18,
                            color: Colors.grey.shade600,
                          ),
                        ),
                      ),
                    ),
                  ),
                  // Content
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: nearestReminder != null
                              ? Colors.teal.shade100
                              : Colors.grey.shade200,
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          nearestReminder != null
                              ? Icons.notifications_active
                              : Icons.notifications_off_outlined,
                          size: 40,
                          color: nearestReminder != null
                              ? Colors.teal.shade700
                              : Colors.grey.shade500,
                        ),
                      ),
                      const SizedBox(height: 20),
                      Text(
                        nearestReminder != null
                            ? 'Upcoming Reminder'
                            : 'No Reminders Set',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          color: Colors.teal.shade800,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        nearestReminder != null
                            ? nearestReminderText
                            : 'Set a reminder to stay on track with your gait tests',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 16,
                          color: Colors.grey.shade600,
                        ),
                      ),
                      const SizedBox(height: 24),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          onPressed: () {
                            Navigator.pop(context);
                            if (nearestReminder == null) {
                              // Navigate to test page to set reminder
                              setState(() {
                                _currentIndex = 2;
                              });
                            }
                          },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.teal,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          child: Text(
                            nearestReminder != null ? 'Got it' : 'Set Reminder',
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
      transitionBuilder: (context, anim1, anim2, child) {
        return FadeTransition(
          opacity: anim1,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.8, end: 1.0).animate(
              CurvedAnimation(parent: anim1, curve: Curves.easeOutBack),
            ),
            child: child,
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 1,
        title: Row(
          children: [
            Image.asset('assets/Safe.png', height: 36, fit: BoxFit.contain),
            const SizedBox(width: 12),
            Text(
              'SafeStep',
              style: TextStyle(
                color: Colors.teal.shade700,
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
            const Spacer(),
            IconButton(
              icon: Icon(
                Icons.notifications_outlined,
                color: Colors.teal.shade600,
              ),
              onPressed: () => _showReminderPopup(context),
            ),
          ],
        ),
      ),
      body: SafeArea(
        child: IndexedStack(
          index: _currentIndex,
          children: [
            const HomePage(),
            const ReportsPage(),
            const AssignmentHomePage(),
            AccountPage(key: accountPageKey),
          ],
        ),
      ),
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          boxShadow: [
            BoxShadow(
              color: Colors.grey.withOpacity(0.2),
              blurRadius: 10,
              offset: const Offset(0, -5),
            ),
          ],
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _buildNavItem(Icons.home_rounded, 'Home', 0),
                _buildNavItem(Icons.description_rounded, 'Reports', 1),
                _buildNavItem(Icons.play_circle_filled, 'Test', 2),
                _buildNavItem(Icons.person_rounded, 'Account', 3),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildNavItem(IconData icon, String label, int index) {
    final isSelected = _currentIndex == index;
    return GestureDetector(
      onTap: () {
        setState(() {
          _currentIndex = index;
          if (index == 3) {
            accountPageKey.currentState?.resetToHome();
          }
        });
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected ? Colors.teal.shade50 : Colors.transparent,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              color: isSelected ? Colors.teal.shade600 : Colors.grey.shade500,
              size: isSelected ? 20 : 28,
            ),
            if (isSelected) ...[
              const SizedBox(height: 2),
              Text(
                label,
                style: TextStyle(
                  color: Colors.teal.shade700,
                  fontWeight: FontWeight.bold,
                  fontSize: 10,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// =============================================================
// DATA MODEL
// =============================================================
class ImuSample {
  final int phoneTsMs;
  final int espTsMs;
  final double ax, ay, az;
  final double gx, gy, gz;
  final double pitch, roll;
  final double load1, load2, loadTotal;

  ImuSample({
    required this.phoneTsMs,
    required this.espTsMs,
    required this.ax,
    required this.ay,
    required this.az,
    required this.gx,
    required this.gy,
    required this.gz,
    required this.pitch,
    required this.roll,
    required this.load1,
    required this.load2,
    required this.loadTotal,
  });
}

// =============================================================
// HOME PAGE (IMPROVED WITH GREETING & DYNAMIC DATA)
// =============================================================
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  String _getGreeting() {
    final hour = DateTime.now().hour;
    if (hour < 12) return 'Good Morning';
    if (hour < 17) return 'Good Afternoon';
    return 'Good Evening';
  }

  @override
  Widget build(BuildContext context) {
    final bool leftConnected = DeviceManager.leftDevice != null;
    final bool rightConnected = DeviceManager.rightDevice != null;
    final bool bothConnected = DeviceManager.isReady;
    final todayTests = TestHistoryManager.todayTestCount;
    final todaySteps = TestHistoryManager.todayTotalSteps;

    return Container(
      color: const Color(0xFFE0F2F1), // Light cyan background
      child: RefreshIndicator(
        color: Colors.teal,
        onRefresh: () async {
          setState(() {});
        },
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Recovery Progress Section - Clickable
                    GestureDetector(
                      onTap: () {
                        // Navigate to Reports tab
                        appShellKey.currentState?.setState(() {
                          appShellKey.currentState?._currentIndex = 1;
                        });
                      },
                      child: _recoveryProgressCard(),
                    ),

                    const SizedBox(height: 28),

                    // Weight Balance Section - Clickable
                    const Text(
                      'Weight Distribution',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: GestureDetector(
                            onTap: () {
                              appShellKey.currentState?.setState(() {
                                appShellKey.currentState?._currentIndex = 1;
                              });
                            },
                            child: _weightBalanceCard(
                              'Left Foot',
                              48.5,
                              Colors.blue,
                              Icons.chevron_left,
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: GestureDetector(
                            onTap: () {
                              appShellKey.currentState?.setState(() {
                                appShellKey.currentState?._currentIndex = 1;
                              });
                            },
                            child: _weightBalanceCard(
                              'Right Foot',
                              51.5,
                              Colors.orange,
                              Icons.chevron_right,
                            ),
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 28),

                    // Device Status Section - at bottom
                    const Text(
                      'Device Status',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 16),
                    _combinedDeviceStatusCard(leftConnected, rightConnected),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _statCard({
    required IconData icon,
    required String value,
    required String label,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: color.withOpacity(0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, color: color, size: 24),
          ),
          const SizedBox(height: 12),
          Text(
            value,
            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
          ),
          Text(
            label,
            style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
          ),
        ],
      ),
    );
  }

  Widget _actionCard({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.05),
                blurRadius: 10,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: color.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, color: color, size: 24),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  label,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                  ),
                ),
              ),
              Icon(
                Icons.arrow_forward_ios,
                size: 14,
                color: Colors.grey.shade400,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _deviceStatusCard(String name, bool connected, IconData icon) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: connected ? Colors.green : Colors.red,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: (connected ? Colors.green : Colors.red).withOpacity(
                    0.4,
                  ),
                  blurRadius: 6,
                  spreadRadius: 1,
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          Icon(icon, color: Colors.grey.shade400, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name, style: const TextStyle(fontWeight: FontWeight.w600)),
                Text(
                  connected ? 'Connected' : 'Not connected',
                  style: TextStyle(
                    fontSize: 12,
                    color: connected
                        ? Colors.green.shade600
                        : Colors.red.shade600,
                  ),
                ),
              ],
            ),
          ),
          if (connected)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.green.shade50,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.check, size: 14, color: Colors.green.shade600),
                  const SizedBox(width: 4),
                  Text(
                    'Ready',
                    style: TextStyle(
                      fontSize: 11,
                      color: Colors.green.shade700,
                    ),
                  ),
                ],
              ),
            )
          else
            Icon(Icons.link_off, color: Colors.red.shade400, size: 20),
        ],
      ),
    );
  }

  Widget _combinedDeviceStatusCard(bool leftConnected, bool rightConnected) {
    final bothConnected = leftConnected && rightConnected;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        children: [
          Row(
            children: [
              // Left device indicator
              Expanded(
                child: Row(
                  children: [
                    Container(
                      width: 12,
                      height: 12,
                      decoration: BoxDecoration(
                        color: leftConnected ? Colors.green : Colors.red,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: (leftConnected ? Colors.green : Colors.red)
                                .withOpacity(0.4),
                            blurRadius: 6,
                            spreadRadius: 1,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    const Text(
                      'Left',
                      style: TextStyle(fontWeight: FontWeight.w500),
                    ),
                  ],
                ),
              ),
              // Status badge
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: bothConnected
                      ? Colors.green.shade50
                      : Colors.orange.shade50,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  bothConnected ? 'Ready' : 'Setup Required',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: bothConnected
                        ? Colors.green.shade700
                        : Colors.orange.shade700,
                  ),
                ),
              ),
              // Right device indicator
              Expanded(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    const Text(
                      'Right',
                      style: TextStyle(fontWeight: FontWeight.w500),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      width: 12,
                      height: 12,
                      decoration: BoxDecoration(
                        color: rightConnected ? Colors.green : Colors.red,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: (rightConnected ? Colors.green : Colors.red)
                                .withOpacity(0.4),
                            blurRadius: 6,
                            spreadRadius: 1,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          // Setup Device Button
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () {
                appShellKey.currentState?.goToAccountSetup();
              },
              icon: Icon(
                Icons.bluetooth_connected,
                color: Colors.teal.shade600,
                size: 18,
              ),
              label: Text(
                bothConnected ? 'Manage Devices' : 'Setup Device',
                style: TextStyle(
                  color: Colors.teal.shade600,
                  fontWeight: FontWeight.w600,
                ),
              ),
              style: OutlinedButton.styleFrom(
                side: BorderSide(color: Colors.teal.shade300),
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _recoveryProgressCard() {
    // Placeholder values - will be calculated from actual data
    final gaitScore = 85;
    final recoveryProgress = 0.72; // 72% recovery

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [Colors.teal.shade400, Colors.teal.shade600],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.teal.withOpacity(0.3),
            blurRadius: 15,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Progress',
                    style: TextStyle(color: Colors.white70, fontSize: 14),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        '$gaitScore',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 42,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const Padding(
                        padding: EdgeInsets.only(bottom: 8, left: 4),
                        child: Text(
                          '/100',
                          style: TextStyle(color: Colors.white70, fontSize: 16),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  Icons.trending_up,
                  color: Colors.white,
                  size: 28,
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          const Text(
            'Recovery Progress',
            style: TextStyle(color: Colors.white70, fontSize: 14),
          ),
          const SizedBox(height: 8),
          // Interactive Progress Bar
          Stack(
            children: [
              Container(
                height: 12,
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(6),
                ),
              ),
              FractionallySizedBox(
                widthFactor: recoveryProgress,
                child: Container(
                  height: 12,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [Colors.white, Colors.white.withOpacity(0.8)],
                    ),
                    borderRadius: BorderRadius.circular(6),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.white.withOpacity(0.4),
                        blurRadius: 6,
                        spreadRadius: 1,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '${(recoveryProgress * 100).toInt()}% Complete',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Text(
                'Target: 100%',
                style: TextStyle(color: Colors.white70, fontSize: 12),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _weightBalanceCard(
    String label,
    double percentage,
    Color color,
    IconData icon,
  ) {
    final isBalanced = (percentage - 50).abs() < 5;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: color, size: 20),
              const SizedBox(width: 4),
              Text(
                label,
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          // Circular progress indicator
          Stack(
            alignment: Alignment.center,
            children: [
              SizedBox(
                width: 80,
                height: 80,
                child: CircularProgressIndicator(
                  value: percentage / 100,
                  strokeWidth: 8,
                  backgroundColor: Colors.grey.shade200,
                  valueColor: AlwaysStoppedAnimation<Color>(color),
                ),
              ),
              Column(
                children: [
                  Text(
                    '${percentage.toStringAsFixed(1)}%',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: color,
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: isBalanced ? Colors.green.shade50 : Colors.orange.shade50,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              isBalanced ? 'Balanced' : 'Adjust',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: isBalanced
                    ? Colors.green.shade700
                    : Colors.orange.shade700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================
// REPORTS PAGE (WITH TEST HISTORY)
// =============================================================
class ReportsPage extends StatefulWidget {
  const ReportsPage({super.key});

  @override
  State<ReportsPage> createState() => _ReportsPageState();
}

class _ReportsPageState extends State<ReportsPage> {
  // Fake report data for demonstration
  final List<Map<String, dynamic>> _fakeReports = [
    {
      'date': DateTime.now()
          .subtract(const Duration(days: 0))
          .toIso8601String(),
      'totalSteps': 245,
      'duration': 32.5,
      'symmetry': 87.5,
      'leftSteps': 122,
      'rightSteps': 123,
    },
    {
      'date': DateTime.now()
          .subtract(const Duration(days: 1))
          .toIso8601String(),
      'totalSteps': 198,
      'duration': 28.0,
      'symmetry': 82.3,
      'leftSteps': 95,
      'rightSteps': 103,
    },
    {
      'date': DateTime.now()
          .subtract(const Duration(days: 2))
          .toIso8601String(),
      'totalSteps': 312,
      'duration': 45.2,
      'symmetry': 91.2,
      'leftSteps': 154,
      'rightSteps': 158,
    },
    {
      'date': DateTime.now()
          .subtract(const Duration(days: 4))
          .toIso8601String(),
      'totalSteps': 156,
      'duration': 22.8,
      'symmetry': 74.5,
      'leftSteps': 68,
      'rightSteps': 88,
    },
    {
      'date': DateTime.now()
          .subtract(const Duration(days: 5))
          .toIso8601String(),
      'totalSteps': 278,
      'duration': 38.1,
      'symmetry': 88.9,
      'leftSteps': 136,
      'rightSteps': 142,
    },
    {
      'date': DateTime.now()
          .subtract(const Duration(days: 7))
          .toIso8601String(),
      'totalSteps': 189,
      'duration': 26.4,
      'symmetry': 79.8,
      'leftSteps': 85,
      'rightSteps': 104,
    },
    {
      'date': DateTime.now()
          .subtract(const Duration(days: 10))
          .toIso8601String(),
      'totalSteps': 234,
      'duration': 33.7,
      'symmetry': 85.6,
      'leftSteps': 112,
      'rightSteps': 122,
    },
  ];

  @override
  Widget build(BuildContext context) {
    // Combine real history with fake reports for demo
    final history = TestHistoryManager.history.isEmpty
        ? _fakeReports
        : TestHistoryManager.history;

    return Scaffold(
      backgroundColor: const Color(0xFFE0F2F1), // Light cyan background
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              // Header Stats with Cyan gradient and curvy edges
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [Colors.teal.shade400, Colors.teal.shade600],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.teal.withOpacity(0.3),
                      blurRadius: 15,
                      offset: const Offset(0, 5),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Test History',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 16),
                    // Summary Stats
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        _reportStat('${history.length}', 'Tests'),
                        Container(
                          height: 30,
                          width: 1,
                          color: Colors.white.withOpacity(0.3),
                        ),
                        _reportStat('85%', 'Avg Score'),
                        Container(
                          height: 30,
                          width: 1,
                          color: Colors.white.withOpacity(0.3),
                        ),
                        _reportStat('14', 'Days'),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),

              // Test List
              Expanded(
                child: history.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.history,
                              size: 80,
                              color: Colors.grey.shade300,
                            ),
                            const SizedBox(height: 16),
                            Text(
                              'No tests yet',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w600,
                                color: Colors.grey.shade600,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'Complete your first test to see results here',
                              style: TextStyle(
                                fontSize: 14,
                                color: Colors.grey.shade500,
                              ),
                            ),
                            const SizedBox(height: 24),
                            ElevatedButton.icon(
                              onPressed: () {
                                appShellKey.currentState?.setState(() {
                                  appShellKey.currentState?._currentIndex = 2;
                                });
                              },
                              icon: const Icon(Icons.play_arrow),
                              label: const Text('Take First Test'),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.teal,
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 24,
                                  vertical: 12,
                                ),
                              ),
                            ),
                          ],
                        ),
                      )
                    : RefreshIndicator(
                        onRefresh: () async {
                          setState(() {});
                        },
                        child: ListView.builder(
                          padding: const EdgeInsets.all(16),
                          itemCount: history.length,
                          itemBuilder: (context, index) {
                            final test = history[index];
                            final date = DateTime.parse(test['date']);
                            final symmetry = test['symmetry'];
                            final isGood = symmetry != null && symmetry > 80;

                            return Card(
                              margin: const EdgeInsets.only(bottom: 12),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: InkWell(
                                onTap: () {
                                  _showReportDetail(context, test);
                                },
                                borderRadius: BorderRadius.circular(12),
                                child: Padding(
                                  padding: const EdgeInsets.all(16),
                                  child: Row(
                                    children: [
                                      // Date indicator
                                      Container(
                                        width: 50,
                                        height: 50,
                                        decoration: BoxDecoration(
                                          color: Colors.teal.shade50,
                                          borderRadius: BorderRadius.circular(
                                            10,
                                          ),
                                        ),
                                        child: Column(
                                          mainAxisAlignment:
                                              MainAxisAlignment.center,
                                          children: [
                                            Text(
                                              '${date.day}',
                                              style: TextStyle(
                                                fontSize: 18,
                                                fontWeight: FontWeight.bold,
                                                color: Colors.teal.shade700,
                                              ),
                                            ),
                                            Text(
                                              _getMonthAbbr(date.month),
                                              style: TextStyle(
                                                fontSize: 11,
                                                color: Colors.teal.shade600,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      const SizedBox(width: 16),
                                      // Test info
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              'Gait Analysis Test',
                                              style: const TextStyle(
                                                fontWeight: FontWeight.w600,
                                                fontSize: 15,
                                              ),
                                            ),
                                            const SizedBox(height: 4),
                                            Text(
                                              '${test['totalSteps']} steps • ${(test['duration'] as num).toStringAsFixed(1)}s',
                                              style: TextStyle(
                                                fontSize: 13,
                                                color: Colors.grey.shade600,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      // Symmetry score
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 12,
                                          vertical: 6,
                                        ),
                                        decoration: BoxDecoration(
                                          color: isGood
                                              ? Colors.green.shade50
                                              : Colors.orange.shade50,
                                          borderRadius: BorderRadius.circular(
                                            20,
                                          ),
                                        ),
                                        child: Text(
                                          symmetry != null
                                              ? '${symmetry.toStringAsFixed(0)}%'
                                              : 'N/A',
                                          style: TextStyle(
                                            fontWeight: FontWeight.bold,
                                            color: isGood
                                                ? Colors.green.shade700
                                                : Colors.orange.shade700,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showReportDetail(BuildContext context, Map<String, dynamic> test) {
    final date = DateTime.parse(test['date']);
    final symmetry = test['symmetry'] as double?;
    final totalSteps = test['totalSteps'] as int;
    final duration = test['duration'] as num;
    final leftSteps = test['leftSteps'] as int? ?? (totalSteps ~/ 2);
    final rightSteps = test['rightSteps'] as int? ?? (totalSteps - leftSteps);
    final isGood = symmetry != null && symmetry > 80;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        height: MediaQuery.of(context).size.height * 0.85,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.white.withOpacity(0.98), Colors.white],
          ),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          children: [
            // Handle bar
            Container(
              margin: const EdgeInsets.only(top: 12),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey.shade300,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            // Header
            Container(
              padding: const EdgeInsets.all(20),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.teal.shade50,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(
                      Icons.assessment,
                      color: Colors.teal.shade600,
                      size: 28,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Gait Analysis Report',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          '${_getMonthAbbr(date.month)} ${date.day}, ${date.year} at ${date.hour}:${date.minute.toString().padLeft(2, '0')}',
                          style: TextStyle(
                            fontSize: 14,
                            color: Colors.grey.shade600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: Colors.grey.shade200),
            // Content
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Overall Score Card
                    Container(
                      padding: const EdgeInsets.all(24),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: isGood
                              ? [Colors.green.shade400, Colors.green.shade600]
                              : [
                                  Colors.orange.shade400,
                                  Colors.orange.shade600,
                                ],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Overall Symmetry',
                                  style: TextStyle(
                                    fontSize: 14,
                                    color: Colors.white.withOpacity(0.9),
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  '${symmetry?.toStringAsFixed(1) ?? 'N/A'}%',
                                  style: const TextStyle(
                                    fontSize: 42,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.white,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 6,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.white.withOpacity(0.2),
                                    borderRadius: BorderRadius.circular(20),
                                  ),
                                  child: Text(
                                    isGood
                                        ? '✓ Good Balance'
                                        : '⚠ Needs Attention',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.2),
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              isGood ? Icons.thumb_up : Icons.warning,
                              color: Colors.white,
                              size: 32,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),

                    // Test Metrics
                    const Text(
                      'Test Metrics',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: _reportMetricCard(
                            'Total Steps',
                            '$totalSteps',
                            Icons.directions_walk,
                            Colors.blue,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _reportMetricCard(
                            'Duration',
                            '${duration.toStringAsFixed(1)}s',
                            Icons.timer,
                            Colors.purple,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: _reportMetricCard(
                            'Left Steps',
                            '$leftSteps',
                            Icons.chevron_left,
                            Colors.teal,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _reportMetricCard(
                            'Right Steps',
                            '$rightSteps',
                            Icons.chevron_right,
                            Colors.teal,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),

                    // Step Distribution
                    const Text(
                      'Step Distribution',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: Colors.grey.shade200),
                      ),
                      child: Column(
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Column(
                                  children: [
                                    Text(
                                      'Left',
                                      style: TextStyle(
                                        color: Colors.grey.shade600,
                                        fontSize: 14,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      '${(leftSteps / totalSteps * 100).toStringAsFixed(1)}%',
                                      style: TextStyle(
                                        fontSize: 24,
                                        fontWeight: FontWeight.bold,
                                        color: Colors.teal.shade700,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              Container(
                                width: 1,
                                height: 50,
                                color: Colors.grey.shade300,
                              ),
                              Expanded(
                                child: Column(
                                  children: [
                                    Text(
                                      'Right',
                                      style: TextStyle(
                                        color: Colors.grey.shade600,
                                        fontSize: 14,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      '${(rightSteps / totalSteps * 100).toStringAsFixed(1)}%',
                                      style: TextStyle(
                                        fontSize: 24,
                                        fontWeight: FontWeight.bold,
                                        color: Colors.teal.shade700,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          // Progress bar
                          ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: Row(
                              children: [
                                Expanded(
                                  flex: leftSteps,
                                  child: Container(
                                    height: 12,
                                    color: Colors.teal.shade400,
                                  ),
                                ),
                                Expanded(
                                  flex: rightSteps,
                                  child: Container(
                                    height: 12,
                                    color: Colors.teal.shade700,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),

                    // Recommendations
                    const Text(
                      'Recommendations',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.blue.shade50,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.blue.shade100),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.lightbulb_outline,
                            color: Colors.blue.shade600,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              isGood
                                  ? 'Great job! Your gait symmetry is within the healthy range. Continue with regular walking exercises.'
                                  : 'Your gait shows some asymmetry. Consider consulting with your doctor and practicing balance exercises.',
                              style: TextStyle(
                                color: Colors.blue.shade800,
                                height: 1.4,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),

                    // Action Buttons
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('Report shared!'),
                                  backgroundColor: Colors.teal,
                                ),
                              );
                            },
                            icon: const Icon(Icons.share),
                            label: const Text('Share'),
                            style: OutlinedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              side: BorderSide(color: Colors.teal.shade300),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: () {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('PDF downloaded!'),
                                  backgroundColor: Colors.teal,
                                ),
                              );
                            },
                            icon: const Icon(Icons.download),
                            label: const Text('Download PDF'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.teal,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 14),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _reportMetricCard(
    String label,
    String value,
    IconData icon,
    Color color,
  ) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: color.withOpacity(0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, color: color, size: 20),
          ),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
              ),
              Text(
                value,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _summaryChip(IconData icon, String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.2),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withOpacity(0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  Widget _reportStat(String value, String label) {
    return Column(
      children: [
        Text(
          value,
          style: const TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: TextStyle(fontSize: 12, color: Colors.white.withOpacity(0.8)),
        ),
      ],
    );
  }

  String _formatDate(DateTime date) {
    return '${date.day}/${date.month}/${date.year}';
  }

  String _getMonthAbbr(int month) {
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return months[month - 1];
  }
}

// =============================================================
// CUSTOM SNACKBAR WIDGET - SUPPORTS ALL SWIPE DIRECTIONS
// =============================================================
class _CustomSnackBarWidget extends StatefulWidget {
  final String message;
  final IconData icon;
  final Color color;
  final VoidCallback onDismiss;

  const _CustomSnackBarWidget({
    required this.message,
    required this.icon,
    required this.color,
    required this.onDismiss,
  });

  @override
  State<_CustomSnackBarWidget> createState() => _CustomSnackBarWidgetState();
}

class _CustomSnackBarWidgetState extends State<_CustomSnackBarWidget>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<Offset> _slideAnimation;
  late Animation<double> _fadeAnimation;
  Offset _dragOffset = Offset.zero;
  bool _isDragging = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
    );
    _slideAnimation = Tween<Offset>(
      begin: const Offset(0, 1),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOut));
    _fadeAnimation = Tween<double>(begin: 0, end: 1).animate(_controller);
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _dismiss() {
    _controller.reverse().then((_) => widget.onDismiss());
  }

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: 16,
      right: 16,
      bottom: 16,
      child: FadeTransition(
        opacity: _fadeAnimation,
        child: SlideTransition(
          position: _slideAnimation,
          child: GestureDetector(
            onPanStart: (_) => setState(() => _isDragging = true),
            onPanUpdate: (details) {
              setState(() {
                _dragOffset += details.delta;
              });
            },
            onPanEnd: (details) {
              // Dismiss if dragged far enough in any direction
              if (_dragOffset.dx.abs() > 80 || _dragOffset.dy.abs() > 40) {
                _dismiss();
              } else {
                setState(() {
                  _dragOffset = Offset.zero;
                  _isDragging = false;
                });
              }
            },
            child: Transform.translate(
              offset: _dragOffset,
              child: Opacity(
                opacity: _isDragging
                    ? (1 - (_dragOffset.distance / 200).clamp(0, 0.5))
                    : 1,
                child: Material(
                  color: Colors.transparent,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    decoration: BoxDecoration(
                      color: widget.color,
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [
                        BoxShadow(
                          color: widget.color.withOpacity(0.4),
                          blurRadius: 12,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.2),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Icon(
                            widget.icon,
                            color: Colors.white,
                            size: 20,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            widget.message,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                        GestureDetector(
                          onTap: _dismiss,
                          child: Icon(
                            Icons.close,
                            color: Colors.white.withOpacity(0.7),
                            size: 20,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// =============================================================
// ASSIGNMENT HOME PAGE - INTERACTIVE TEST PAGE
// =============================================================
class AssignmentHomePage extends StatefulWidget {
  const AssignmentHomePage({super.key});

  @override
  State<AssignmentHomePage> createState() => _AssignmentHomePageState();
}

class _AssignmentHomePageState extends State<AssignmentHomePage>
    with SingleTickerProviderStateMixin {
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;
  List<Map<String, dynamic>> _reminders = [];

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);
    _pulseAnimation = Tween<double>(begin: 1.0, end: 1.08).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
    _loadReminders();
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  OverlayEntry? _snackBarOverlay;

  void _showCustomSnackBar(
    String message, {
    IconData icon = Icons.check_circle,
    Color color = Colors.teal,
  }) {
    // Remove existing snackbar if any
    _snackBarOverlay?.remove();
    _snackBarOverlay = null;

    late OverlayEntry overlayEntry;

    overlayEntry = OverlayEntry(
      builder: (context) => _CustomSnackBarWidget(
        message: message,
        icon: icon,
        color: color,
        onDismiss: () {
          overlayEntry.remove();
          _snackBarOverlay = null;
        },
      ),
    );

    _snackBarOverlay = overlayEntry;
    Overlay.of(context).insert(overlayEntry);

    // Auto dismiss after 2.5 seconds
    Future.delayed(const Duration(milliseconds: 2500), () {
      if (_snackBarOverlay == overlayEntry) {
        overlayEntry.remove();
        _snackBarOverlay = null;
      }
    });
  }

  Future<void> _loadReminders() async {
    final prefs = await SharedPreferences.getInstance();
    final remindersJson = prefs.getString('test_reminders');
    if (remindersJson != null) {
      setState(() {
        _reminders = List<Map<String, dynamic>>.from(
          jsonDecode(remindersJson).map((x) => Map<String, dynamic>.from(x)),
        );
      });
    }
  }

  Future<void> _saveReminders() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('test_reminders', jsonEncode(_reminders));
  }

  void _addReminder() {
    TimeOfDay selectedTime = TimeOfDay.now();
    List<bool> selectedDays = List.filled(7, false);
    final dayNames = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => StatefulBuilder(
        builder: (context, setModalState) => Container(
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom + 20,
            top: 20,
            left: 20,
            right: 20,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.grey.shade300,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              const Text(
                'Set Test Reminder',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 20),
              // Time Picker
              InkWell(
                onTap: () async {
                  final time = await showTimePicker(
                    context: context,
                    initialTime: selectedTime,
                  );
                  if (time != null) {
                    setModalState(() => selectedTime = time);
                  }
                },
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.grey.shade300),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.access_time, color: Colors.teal),
                      const SizedBox(width: 12),
                      Text(
                        selectedTime.format(context),
                        style: const TextStyle(fontSize: 18),
                      ),
                      const Spacer(),
                      Icon(Icons.edit, color: Colors.grey.shade400),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),
              const Text(
                'Repeat on',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
              ),
              const SizedBox(height: 12),
              // Day selector
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: List.generate(7, (index) {
                  return GestureDetector(
                    onTap: () {
                      setModalState(() {
                        selectedDays[index] = !selectedDays[index];
                      });
                    },
                    child: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: selectedDays[index]
                            ? Colors.teal
                            : Colors.grey.shade200,
                        shape: BoxShape.circle,
                      ),
                      child: Center(
                        child: Text(
                          dayNames[index][0],
                          style: TextStyle(
                            color: selectedDays[index]
                                ? Colors.white
                                : Colors.grey.shade600,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                  );
                }),
              ),
              const SizedBox(height: 24),
              // Save button
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () {
                    if (!selectedDays.contains(true)) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Please select at least one day'),
                        ),
                      );
                      return;
                    }
                    final reminder = {
                      'time': '${selectedTime.hour}:${selectedTime.minute}',
                      'days': selectedDays,
                      'enabled': true,
                    };
                    setState(() {
                      _reminders.add(reminder);
                    });
                    _saveReminders();
                    Navigator.pop(context);
                    _showCustomSnackBar(
                      'Reminder added!',
                      icon: Icons.alarm_add,
                    );
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.teal,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: const Text('Save Reminder'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _deleteReminder(int index) {
    setState(() {
      _reminders.removeAt(index);
    });
    _saveReminders();
    _showCustomSnackBar(
      'Reminder deleted',
      icon: Icons.delete_outline,
      color: Colors.red.shade400,
    );
  }

  void _editReminder(int index) {
    final reminder = _reminders[index];
    final timeStr = reminder['time'] as String? ?? '0:0';
    final timeParts = timeStr.split(':');
    TimeOfDay selectedTime = TimeOfDay(
      hour: int.tryParse(timeParts[0]) ?? 0,
      minute: timeParts.length > 1 ? (int.tryParse(timeParts[1]) ?? 0) : 0,
    );
    List<bool> selectedDays = List<bool>.from(
      reminder['days'] ?? List.filled(7, false),
    );
    final dayNames = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Edit Reminder',
      barrierColor: Colors.black87,
      transitionDuration: const Duration(milliseconds: 300),
      pageBuilder: (context, anim1, anim2) {
        return StatefulBuilder(
          builder: (context, setModalState) => Center(
            child: Material(
              color: Colors.transparent,
              child: Container(
                width: MediaQuery.of(context).size.width * 0.9,
                margin: const EdgeInsets.symmetric(horizontal: 20),
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [Colors.white, Colors.teal.shade50],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(28),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.teal.withOpacity(0.3),
                      blurRadius: 25,
                      spreadRadius: 5,
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: Colors.teal.shade100,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Icon(
                                Icons.edit_notifications,
                                color: Colors.teal.shade700,
                                size: 24,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Text(
                              'Edit Reminder',
                              style: TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.bold,
                                color: Colors.teal.shade800,
                              ),
                            ),
                          ],
                        ),
                        GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => Navigator.pop(context),
                          child: Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: Colors.grey.shade200,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Icon(
                              Icons.close,
                              size: 20,
                              color: Colors.grey.shade600,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    Text(
                      'Time',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: Colors.grey.shade700,
                      ),
                    ),
                    const SizedBox(height: 8),
                    InkWell(
                      onTap: () async {
                        final time = await showTimePicker(
                          context: context,
                          initialTime: selectedTime,
                        );
                        if (time != null) {
                          setModalState(() {
                            selectedTime = time;
                          });
                        }
                      },
                      borderRadius: BorderRadius.circular(16),
                      child: Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: Colors.teal.shade200),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.teal.withOpacity(0.1),
                              blurRadius: 8,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Icons.access_time,
                              color: Colors.teal.shade600,
                            ),
                            const SizedBox(width: 12),
                            Text(
                              selectedTime.format(context),
                              style: TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.bold,
                                color: Colors.teal.shade700,
                              ),
                            ),
                            const Spacer(),
                            Icon(
                              Icons.arrow_drop_down,
                              color: Colors.teal.shade400,
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      'Repeat on',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: Colors.grey.shade700,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: List.generate(7, (i) {
                        return GestureDetector(
                          onTap: () {
                            setModalState(() {
                              selectedDays[i] = !selectedDays[i];
                            });
                          },
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 200),
                            width: 38,
                            height: 38,
                            decoration: BoxDecoration(
                              color: selectedDays[i]
                                  ? Colors.teal
                                  : Colors.white,
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: selectedDays[i]
                                    ? Colors.teal
                                    : Colors.grey.shade300,
                                width: 2,
                              ),
                              boxShadow: selectedDays[i]
                                  ? [
                                      BoxShadow(
                                        color: Colors.teal.withOpacity(0.3),
                                        blurRadius: 6,
                                        spreadRadius: 1,
                                      ),
                                    ]
                                  : null,
                            ),
                            child: Center(
                              child: Text(
                                dayNames[i][0],
                                style: TextStyle(
                                  color: selectedDays[i]
                                      ? Colors.white
                                      : Colors.grey.shade600,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 13,
                                ),
                              ),
                            ),
                          ),
                        );
                      }),
                    ),
                    const SizedBox(height: 28),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: () {
                          if (!selectedDays.contains(true)) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Please select at least one day'),
                              ),
                            );
                            return;
                          }
                          setState(() {
                            _reminders[index] = {
                              'time':
                                  '${selectedTime.hour}:${selectedTime.minute}',
                              'days': selectedDays,
                              'enabled': true,
                            };
                          });
                          _saveReminders();
                          Navigator.pop(context);
                          _showCustomSnackBar(
                            'Reminder updated!',
                            icon: Icons.edit_notifications,
                          );
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.teal,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                          elevation: 4,
                          shadowColor: Colors.teal.withOpacity(0.4),
                        ),
                        child: const Text(
                          'Update Reminder',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
      transitionBuilder: (context, anim1, anim2, child) {
        return FadeTransition(
          opacity: anim1,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.8, end: 1.0).animate(
              CurvedAnimation(parent: anim1, curve: Curves.easeOutBack),
            ),
            child: child,
          ),
        );
      },
    );
  }

  void _handleTakeTest() {
    if (!DeviceManager.isReady) {
      showGeneralDialog(
        context: context,
        barrierDismissible: true,
        barrierLabel: 'Connect Devices',
        barrierColor: Colors.black.withOpacity(0.5),
        transitionDuration: const Duration(milliseconds: 300),
        pageBuilder: (context, anim1, anim2) {
          return Center(
            child: Material(
              color: Colors.transparent,
              child: Container(
                margin: const EdgeInsets.all(24),
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      Colors.white.withOpacity(0.95),
                      Colors.white.withOpacity(0.85),
                    ],
                  ),
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(
                    color: Colors.white.withOpacity(0.5),
                    width: 1.5,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.tealAccent.withOpacity(0.2),
                      blurRadius: 30,
                      spreadRadius: 5,
                    ),
                  ],
                ),
                child: Stack(
                  children: [
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const SizedBox(height: 8),
                        Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: Colors.orange.withOpacity(0.1),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            Icons.bluetooth_disabled,
                            size: 48,
                            color: Colors.orange.shade600,
                          ),
                        ),
                        const SizedBox(height: 20),
                        const Text(
                          'Connect Devices',
                          style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Please connect both footwear devices to start the test',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 14,
                            color: Colors.grey.shade600,
                          ),
                        ),
                        const SizedBox(height: 24),
                        // Device status indicators
                        Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: Colors.grey.shade50,
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                            children: [
                              _buildPopupDeviceStatus(
                                'Left',
                                Icons.chevron_left,
                                DeviceManager.leftDevice != null,
                              ),
                              Container(
                                width: 1,
                                height: 50,
                                color: Colors.grey.shade300,
                              ),
                              _buildPopupDeviceStatus(
                                'Right',
                                Icons.chevron_right,
                                DeviceManager.rightDevice != null,
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 24),
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton.icon(
                            onPressed: () {
                              Navigator.pop(context);
                              appShellKey.currentState?.goToAccountSetup();
                            },
                            icon: const Icon(
                              Icons.bluetooth_searching,
                              size: 20,
                            ),
                            label: const Text('Setup Devices'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.teal,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    // X close button
                    Positioned(
                      top: -8,
                      right: -8,
                      child: GestureDetector(
                        onTap: () => Navigator.pop(context),
                        child: Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: Colors.grey.shade100,
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            Icons.close,
                            size: 20,
                            color: Colors.grey.shade600,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
        transitionBuilder: (context, anim1, anim2, child) {
          return FadeTransition(
            opacity: anim1,
            child: ScaleTransition(
              scale: Tween<double>(begin: 0.8, end: 1.0).animate(
                CurvedAnimation(parent: anim1, curve: Curves.easeOutBack),
              ),
              child: child,
            ),
          );
        },
      );
    } else {
      // Devices connected - show instruction popup with glossy background
      showGeneralDialog(
        context: context,
        barrierDismissible: true,
        barrierLabel: 'Instructions',
        barrierColor: Colors.black.withOpacity(0.5),
        transitionDuration: const Duration(milliseconds: 300),
        pageBuilder: (context, anim1, anim2) {
          return Center(
            child: Material(
              color: Colors.transparent,
              child: Container(
                margin: const EdgeInsets.all(24),
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      Colors.white.withOpacity(0.95),
                      Colors.white.withOpacity(0.85),
                    ],
                  ),
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(
                    color: Colors.white.withOpacity(0.5),
                    width: 1.5,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.teal.withOpacity(0.2),
                      blurRadius: 30,
                      spreadRadius: 5,
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.teal.withOpacity(0.1),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.directions_walk,
                        size: 48,
                        color: Colors.teal.shade600,
                      ),
                    ),
                    const SizedBox(height: 20),
                    const Text(
                      'Test Instructions',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Follow these steps for accurate results',
                      style: TextStyle(
                        fontSize: 14,
                        color: Colors.grey.shade600,
                      ),
                    ),
                    const SizedBox(height: 24),
                    _buildGlossyInstructionItem(
                      '1',
                      'Wear both footwear devices',
                      Icons.checkroom,
                    ),
                    _buildGlossyInstructionItem(
                      '2',
                      'Walk naturally for 30 seconds',
                      Icons.directions_walk,
                    ),
                    _buildGlossyInstructionItem(
                      '3',
                      'Keep a steady pace',
                      Icons.speed,
                    ),
                    _buildGlossyInstructionItem(
                      '4',
                      'Walk in a straight line',
                      Icons.straighten,
                    ),
                    const SizedBox(height: 24),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () => Navigator.pop(context),
                            style: OutlinedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              side: BorderSide(color: Colors.grey.shade300),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            child: const Text('Cancel'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          flex: 2,
                          child: ElevatedButton(
                            onPressed: () {
                              Navigator.pop(context);
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => DataCollectionPage(
                                    leftDevice: DeviceManager.leftDevice!,
                                    rightDevice: DeviceManager.rightDevice!,
                                  ),
                                ),
                              );
                            },
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.teal,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            child: const Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(Icons.play_arrow, size: 20),
                                SizedBox(width: 8),
                                Text(
                                  'Start Test',
                                  style: TextStyle(fontWeight: FontWeight.bold),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          );
        },
        transitionBuilder: (context, anim1, anim2, child) {
          return FadeTransition(
            opacity: anim1,
            child: ScaleTransition(
              scale: Tween<double>(begin: 0.8, end: 1.0).animate(
                CurvedAnimation(parent: anim1, curve: Curves.easeOutBack),
              ),
              child: child,
            ),
          );
        },
      );
    }
  }

  Widget _buildGlossyInstructionItem(
    String number,
    String text,
    IconData icon,
  ) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.teal.withOpacity(0.05),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.teal.withOpacity(0.1)),
      ),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: Colors.teal.withOpacity(0.15),
              shape: BoxShape.circle,
            ),
            child: Center(
              child: Text(
                number,
                style: TextStyle(
                  color: Colors.teal.shade700,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(child: Text(text)),
          Icon(icon, color: Colors.teal.shade400, size: 20),
        ],
      ),
    );
  }

  Widget _buildDeviceIndicator(String label, bool connected) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(
          connected ? Icons.check_circle : Icons.cancel,
          color: connected ? Colors.green : Colors.red,
          size: 20,
        ),
        const SizedBox(width: 8),
        Text('$label Footwear'),
      ],
    );
  }

  Widget _buildPopupDeviceStatus(String label, IconData icon, bool connected) {
    return Column(
      children: [
        Container(
          width: 50,
          height: 50,
          decoration: BoxDecoration(
            color: connected ? Colors.green.shade50 : Colors.red.shade50,
            shape: BoxShape.circle,
            border: Border.all(
              color: connected ? Colors.green : Colors.red,
              width: 2,
            ),
          ),
          child: Icon(
            connected ? Icons.check : icon,
            color: connected ? Colors.green : Colors.red,
            size: 24,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          label,
          style: TextStyle(
            fontWeight: FontWeight.w600,
            color: connected ? Colors.green.shade700 : Colors.red.shade700,
          ),
        ),
        Text(
          connected ? 'Connected' : 'Not connected',
          style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFE0F2F1), // Light cyan background
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 40), // Top padding to move button down
              // Main Take Test Button - Interactive Circular Design
              Center(
                child: GestureDetector(
                  onTap: _handleTakeTest,
                  child: Column(
                    children: [
                      // Outer ripple ring
                      AnimatedBuilder(
                        animation: _pulseController,
                        builder: (context, child) {
                          return Container(
                            width: 180 + (_pulseAnimation.value - 1) * 50,
                            height: 180 + (_pulseAnimation.value - 1) * 50,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: Colors.teal.withOpacity(
                                  0.5 - (_pulseAnimation.value - 1) * 2,
                                ),
                                width: 4,
                              ),
                            ),
                            child: Center(
                              child: Container(
                                width: 160,
                                height: 160,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  gradient: LinearGradient(
                                    colors: DeviceManager.isReady
                                        ? [
                                            Colors.teal.shade400,
                                            Colors.teal.shade700,
                                          ]
                                        : [
                                            Colors.grey.shade400,
                                            Colors.grey.shade600,
                                          ],
                                    begin: Alignment.topLeft,
                                    end: Alignment.bottomRight,
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      color: DeviceManager.isReady
                                          ? Colors.teal.withOpacity(0.4)
                                          : Colors.grey.withOpacity(0.3),
                                      blurRadius: 25,
                                      spreadRadius: 5,
                                    ),
                                  ],
                                ),
                                child: const Icon(
                                  Icons.play_arrow_rounded,
                                  size: 80,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                      const SizedBox(height: 20),
                      Text(
                        'Start Test',
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                          color: DeviceManager.isReady
                              ? Colors.teal.shade700
                              : Colors.grey.shade600,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        DeviceManager.isReady
                            ? 'Tap to begin your gait analysis'
                            : 'Connect devices to start',
                        style: TextStyle(
                          fontSize: 14,
                          color: Colors.grey.shade600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // Device Status Row - Clickable to setup devices
              GestureDetector(
                onTap: () {
                  appShellKey.currentState?.goToAccountSetup();
                },
                child: Row(
                  children: [
                    Expanded(
                      child: _buildDeviceCard(
                        'Left Footwear',
                        DeviceManager.leftDevice != null,
                        Icons.chevron_left,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _buildDeviceCard(
                        'Right Footwear',
                        DeviceManager.rightDevice != null,
                        Icons.chevron_right,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),

              // Reminders Section
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Reminders',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  TextButton.icon(
                    onPressed: _addReminder,
                    icon: const Icon(Icons.add, size: 20),
                    label: const Text('Add'),
                    style: TextButton.styleFrom(foregroundColor: Colors.teal),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (_reminders.isEmpty)
                Container(
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade100,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.grey.shade200),
                  ),
                  child: Center(
                    child: Column(
                      children: [
                        Icon(
                          Icons.notifications_none,
                          size: 40,
                          color: Colors.grey.shade400,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'No reminders set',
                          style: TextStyle(color: Colors.grey.shade600),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Add a reminder to stay on track',
                          style: TextStyle(
                            color: Colors.grey.shade500,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                )
              else
                ...List.generate(_reminders.length, (index) {
                  final reminder = _reminders[index];
                  final timeParts = reminder['time'].split(':');
                  final time = TimeOfDay(
                    hour: int.parse(timeParts[0]),
                    minute: int.parse(timeParts[1]),
                  );
                  final days = List<bool>.from(reminder['days']);
                  final dayNames = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];
                  final activeDays = <String>[];
                  for (int i = 0; i < days.length; i++) {
                    if (days[i]) activeDays.add(dayNames[i]);
                  }

                  return Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.grey.shade200),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.alarm, color: Colors.teal),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                time.format(context),
                                style: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              Text(
                                activeDays.join(', '),
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.grey.shade600,
                                ),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          icon: Icon(
                            Icons.edit_outlined,
                            color: Colors.teal.shade400,
                          ),
                          onPressed: () => _editReminder(index),
                        ),
                        IconButton(
                          icon: Icon(
                            Icons.delete_outline,
                            color: Colors.red.shade300,
                          ),
                          onPressed: () => _deleteReminder(index),
                        ),
                      ],
                    ),
                  );
                }),
              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDeviceCard(String label, bool connected, IconData icon) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: connected ? Colors.green.shade50 : Colors.red.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: connected ? Colors.green.shade200 : Colors.red.shade200,
        ),
      ),
      child: Row(
        children: [
          Icon(icon, color: connected ? Colors.green : Colors.red),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                ),
                Text(
                  connected ? 'Connected' : 'Disconnected',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: connected
                        ? Colors.green.shade700
                        : Colors.red.shade700,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInstructionItem(String number, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              color: Colors.teal.shade100,
              shape: BoxShape.circle,
            ),
            child: Center(
              child: Text(
                number,
                style: TextStyle(
                  color: Colors.teal.shade700,
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Text(text),
        ],
      ),
    );
  }
}

// =============================================================
// REAL BLE DATA COLLECTION PAGE
// =============================================================
class DataCollectionPage extends StatefulWidget {
  final BluetoothDevice leftDevice;
  final BluetoothDevice rightDevice;

  const DataCollectionPage({
    super.key,
    required this.leftDevice,
    required this.rightDevice,
  });

  @override
  State<DataCollectionPage> createState() => _DataCollectionPageState();
}

class _DataCollectionPageState extends State<DataCollectionPage> {
  BluetoothCharacteristic? _leftChar;
  BluetoothCharacteristic? _rightChar;
  StreamSubscription<String>? _leftSub;
  StreamSubscription<String>? _rightSub;
  StreamSubscription<BluetoothConnectionState>? _leftConnSub;
  StreamSubscription<BluetoothConnectionState>? _rightConnSub;
  Timer? _timer;
  int _elapsedSeconds = 0;

  bool collecting = false;
  final List<ImuSample> leftSamples = [];
  final List<ImuSample> rightSamples = [];
  ImuSample? _latestLeft;
  ImuSample? _latestRight;

  @override
  void initState() {
    super.initState();
    _discoverChars();

    _leftConnSub = widget.leftDevice.connectionState.listen((state) {
      if (state == BluetoothConnectionState.disconnected && mounted) {
        _handleDisconnect('Left device disconnected');
      }
    });

    _rightConnSub = widget.rightDevice.connectionState.listen((state) {
      if (state == BluetoothConnectionState.disconnected && mounted) {
        _handleDisconnect('Right device disconnected');
      }
    });
  }

  void _handleDisconnect(String msg) {
    if (collecting) {
      _stopCollecting();
    }
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(msg), backgroundColor: Colors.red));
    Navigator.pop(context);
  }

  Future<void> _discoverChars() async {
    _leftChar = await _findNotifyChar(widget.leftDevice);
    _rightChar = await _findNotifyChar(widget.rightDevice);
    if (mounted) setState(() {});
  }

  Future<BluetoothCharacteristic?> _findNotifyChar(
    BluetoothDevice device,
  ) async {
    final services = await device.discoverServices();
    for (final s in services) {
      for (final c in s.characteristics) {
        if (c.uuid.toString().toUpperCase() == CHAR_UUID_TX &&
            c.properties.notify) {
          return c;
        }
      }
    }
    return null;
  }

  void _startCollecting() async {
    if (_leftChar == null || _rightChar == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Characteristics not ready. Please wait...'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    leftSamples.clear();
    rightSamples.clear();
    _latestLeft = null;
    _latestRight = null;
    collecting = true;

    if (mounted) setState(() {});

    // Request HIGH PRIORITY connection for both devices
    try {
      await widget.leftDevice.requestConnectionPriority(
        connectionPriorityRequest: ConnectionPriority.high,
      );
      await widget.rightDevice.requestConnectionPriority(
        connectionPriorityRequest: ConnectionPriority.high,
      );
    } catch (e) {
      // Priority request failed (non-fatal)
    }

    // Request larger MTU for better throughput
    try {
      await widget.leftDevice.requestMtu(512);
      await widget.rightDevice.requestMtu(512);
    } catch (e) {
      // MTU request failed (non-fatal)
    }

    // Small delay to let Android BLE stack adjust
    await Future.delayed(const Duration(milliseconds: 500));

    try {
      await _leftChar!.setNotifyValue(true);
      await _rightChar!.setNotifyValue(true);
    } catch (e) {
      // setNotify error - will be handled by empty data check
    }

    await _leftSub?.cancel();
    await _rightSub?.cancel();

    final leftLines = _leftChar!.onValueReceived
        .map((b) => utf8.decode(b, allowMalformed: true))
        .transform(const LineSplitter());

    final rightLines = _rightChar!.onValueReceived
        .map((b) => utf8.decode(b, allowMalformed: true))
        .transform(const LineSplitter());

    _leftSub = leftLines.listen(
      (l) => _parseCsvLine(l, isLeft: true),
      onError: (e) {},
    );

    _rightSub = rightLines.listen(
      (l) => _parseCsvLine(l, isLeft: false),
      onError: (e) {},
    );

    // Start timer
    _elapsedSeconds = 0;
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted && collecting) {
        setState(() {
          _elapsedSeconds++;
        });
      }
    });

    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Collecting started')));
    }
  }

  void _parseCsvLine(String line, {required bool isLeft}) {
    if (!collecting) return;

    final trimmed = line.trim();
    if (trimmed.isEmpty) return;

    final p = trimmed.split(',');
    if (p.length < 12) {
      return;
    }

    final s = ImuSample(
      phoneTsMs: DateTime.now().millisecondsSinceEpoch,
      espTsMs: int.tryParse(p[0]) ?? 0,
      ax: double.tryParse(p[1]) ?? 0,
      ay: double.tryParse(p[2]) ?? 0,
      az: double.tryParse(p[3]) ?? 0,
      gx: double.tryParse(p[4]) ?? 0,
      gy: double.tryParse(p[5]) ?? 0,
      gz: double.tryParse(p[6]) ?? 0,
      pitch: double.tryParse(p[7]) ?? 0,
      roll: double.tryParse(p[8]) ?? 0,
      load1: double.tryParse(p[9]) ?? 0,
      load2: double.tryParse(p[10]) ?? 0,
      loadTotal:
          double.tryParse(p[11]) ??
          ((double.tryParse(p[9]) ?? 0) + (double.tryParse(p[10]) ?? 0)),
    );

    if (isLeft) {
      leftSamples.add(s);
      _latestLeft = s;
    } else {
      rightSamples.add(s);
      _latestRight = s;
    }

    // Update UI every 50 samples
    if (mounted &&
        (leftSamples.length % 50 == 0 || rightSamples.length % 50 == 0)) {
      setState(() {});
    }
  }

  void _stopCollecting() async {
    // Show "Generating Report" dialog IMMEDIATELY
    if (mounted) {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => PopScope(
          canPop: false,
          child: Dialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(color: Colors.teal),
                  const SizedBox(height: 20),
                  const Text(
                    'Generating Report...',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Processing sensor data',
                    style: TextStyle(fontSize: 14, color: Colors.grey.shade600),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    await Future.delayed(const Duration(milliseconds: 100));

    collecting = false;
    _timer?.cancel();

    await _leftSub?.cancel();
    await _rightSub?.cancel();

    try {
      await _leftChar
          ?.setNotifyValue(false)
          .timeout(const Duration(seconds: 1));
    } catch (e) {
      // Timeout is acceptable
    }

    try {
      await _rightChar
          ?.setNotifyValue(false)
          .timeout(const Duration(seconds: 1));
    } catch (e) {
      // Timeout is acceptable
    }

    // Check if we have data
    if (leftSamples.isEmpty || rightSamples.isEmpty) {
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No data collected. Please try again.'),
            backgroundColor: Colors.orange,
          ),
        );
      }
      return;
    }

    // Limit samples to prevent analyzer slowdown
    const maxSamples = 500;

    final limitedLeft = leftSamples.length > maxSamples
        ? leftSamples.sublist(leftSamples.length - maxSamples)
        : leftSamples;

    final limitedRight = rightSamples.length > maxSamples
        ? rightSamples.sublist(rightSamples.length - maxSamples)
        : rightSamples;

    try {
      final analyzer = GaitAnalyzer();
      final result = analyzer.analyze(
        limitedLeft,
        limitedRight,
        envelopeWindow: 50,
      );

      if (result.containsKey('error')) {
        if (mounted) {
          Navigator.pop(context);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Analysis error: ${result['error']}'),
              backgroundColor: Colors.orange,
            ),
          );
        }
        return;
      }

      // Save test to history
      TestHistoryManager.addTest(result);

      if (!mounted) return;

      Navigator.pop(context);

      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => ResultsScreen(
            result: result,
            leftSamples: limitedLeft,
            rightSamples: limitedRight,
          ),
        ),
      );
    } catch (e) {
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: ${e.toString()}'),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 5),
          ),
        );
      }
    }
  }

  Future<void> _exportCsv() async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File(
      '${dir.path}/gait_${DateTime.now().millisecondsSinceEpoch}.csv',
    );

    final rows = <List<dynamic>>[
      [
        'phonets',
        'espts',
        'ax',
        'ay',
        'az',
        'gx',
        'gy',
        'gz',
        'pitch',
        'roll',
        'load1',
        'load2',
        'loadtotal',
        'side',
      ],
    ];

    for (final s in leftSamples) {
      rows.add([
        s.phoneTsMs,
        s.espTsMs,
        s.ax,
        s.ay,
        s.az,
        s.gx,
        s.gy,
        s.gz,
        s.pitch,
        s.roll,
        s.load1,
        s.load2,
        s.loadTotal,
        'LEFT',
      ]);
    }

    for (final s in rightSamples) {
      rows.add([
        s.phoneTsMs,
        s.espTsMs,
        s.ax,
        s.ay,
        s.az,
        s.gx,
        s.gy,
        s.gz,
        s.pitch,
        s.roll,
        s.load1,
        s.load2,
        s.loadTotal,
        'RIGHT',
      ]);
    }

    final csv = const ListToCsvConverter().convert(rows);
    await file.writeAsString(csv);

    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('CSV saved: ${file.path}')));
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _leftSub?.cancel();
    _rightSub?.cancel();
    _leftConnSub?.cancel();
    _rightConnSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !collecting,
      onPopInvoked: (didPop) async {
        if (!didPop && collecting) {
          final shouldStop = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('Stop Collection?'),
              content: const Text(
                'Data collection is in progress. Do you want to stop and go back?',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Continue'),
                ),
                ElevatedButton(
                  onPressed: () => Navigator.pop(context, true),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red,
                    foregroundColor: Colors.white,
                  ),
                  child: const Text('Stop & Exit'),
                ),
              ],
            ),
          );

          if (shouldStop == true && mounted) {
            _stopCollecting();
            Navigator.pop(context);
          }
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Data Collection'),
          backgroundColor: Colors.teal,
          actions: [
            IconButton(
              icon: const Icon(Icons.save),
              onPressed: (leftSamples.isNotEmpty || rightSamples.isNotEmpty)
                  ? _exportCsv
                  : null,
            ),
          ],
        ),
        body: Container(
          color: Colors.white,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
                // START/STOP BUTTON
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: collecting ? _stopCollecting : _startCollecting,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: collecting ? Colors.red : Colors.green,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                    child: Text(
                      collecting ? 'STOP' : 'START',
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),

                const SizedBox(height: 12),

                // Timer and sample count display
                if (collecting) ...[
                  // Timer display
                  Container(
                    padding: const EdgeInsets.symmetric(
                      vertical: 16,
                      horizontal: 24,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.teal.shade50,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.teal.shade200),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.timer, color: Colors.teal.shade600),
                        const SizedBox(width: 12),
                        Text(
                          '${(_elapsedSeconds ~/ 60).toString().padLeft(2, '0')}:${(_elapsedSeconds % 60).toString().padLeft(2, '0')}',
                          style: TextStyle(
                            fontSize: 32,
                            fontWeight: FontWeight.bold,
                            color: Colors.teal.shade700,
                            fontFamily: 'monospace',
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  // Sample counts
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.blue.shade50,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        _sampleCountChip(
                          'LEFT',
                          leftSamples.length,
                          Colors.blue,
                        ),
                        _sampleCountChip(
                          'RIGHT',
                          rightSamples.length,
                          Colors.orange,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                ],

                // LEFT and RIGHT data cards
                Expanded(
                  child: Row(
                    children: [
                      Expanded(child: _liveCard('LEFT', _latestLeft)),
                      const SizedBox(width: 8),
                      Expanded(child: _liveCard('RIGHT', _latestRight)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _liveCard(String title, ImuSample? s) {
    Widget row(String l, double v) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(child: Text(l, style: const TextStyle(fontSize: 12))),
          Text(
            v.toStringAsFixed(2),
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
          ),
        ],
      ),
    );

    return Card(
      elevation: 3,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: Colors.teal,
              ),
            ),
            const Divider(),
            if (s == null)
              const Expanded(
                child: Center(
                  child: Text(
                    'Waiting for data...\nPress Start',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey),
                  ),
                ),
              )
            else
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    children: [
                      row('ax', s.ax),
                      row('ay', s.ay),
                      row('az', s.az),
                      row('gx', s.gx),
                      row('gy', s.gy),
                      row('gz', s.gz),
                      row('pitch', s.pitch),
                      row('roll', s.roll),
                      const Divider(),
                      row('toe', s.load1),
                      row('heel', s.load2),
                      row('total', s.loadTotal),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _sampleCountChip(String label, int count, Color color) {
    return Column(
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: color,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          '$count',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.bold,
            color: color,
          ),
        ),
        Text(
          'samples',
          style: TextStyle(fontSize: 10, color: Colors.grey.shade600),
        ),
      ],
    );
  }
}

// =============================================================
// GAIT ANALYZER (UNCHANGED)
// =============================================================
class GaitAnalyzer {
  Map<String, dynamic> analyze(
    List<ImuSample> left,
    List<ImuSample> right, {
    int envelopeWindow = 80,
  }) {
    if (left.isEmpty && right.isEmpty) {
      return {'error': 'no data'};
    }

    List<double> tLeft = left.map((s) => s.espTsMs.toDouble()).toList();
    List<double> tRight = right.map((s) => s.espTsMs.toDouble()).toList();

    if (tLeft.isEmpty && tRight.isEmpty) {
      tLeft = left.map((s) => s.phoneTsMs.toDouble()).toList();
      tRight = right.map((s) => s.phoneTsMs.toDouble()).toList();
    }

    void normalizeTime(List<double> t) {
      if (t.isEmpty) return;
      final base = t.first;
      for (int i = 0; i < t.length; i++) {
        t[i] = (t[i] - base) / 1000.0;
      }
    }

    normalizeTime(tLeft);
    normalizeTime(tRight);

    final gxLeft = left.map((s) => s.gx).toList();
    final gxRight = right.map((s) => s.gx).toList();
    final azLeft = left.map((s) => s.az).toList();
    final azRight = right.map((s) => s.az).toList();
    final rollLeft = left.map((s) => s.roll).toList();
    final rollRight = right.map((s) => s.roll).toList();

    double tMin = 0, tMax = 0;
    if (tLeft.isNotEmpty && tRight.isNotEmpty) {
      tMin = math.min(tLeft.first, tRight.first);
      tMax = math.max(tLeft.last, tRight.last);
    } else if (tLeft.isNotEmpty) {
      tMin = tLeft.first;
      tMax = tLeft.last;
    } else {
      tMin = tRight.first;
      tMax = tRight.last;
    }

    final dt = 1.0 / SAMPLE_RATE_HZ;
    final n = ((tMax - tMin) / dt).floor();
    if (n <= 0) return {'error': 'not enough data'};

    final tCommon = List<double>.generate(n, (i) => tMin + i * dt);

    final gxL = _interp(tLeft, gxLeft, tCommon);
    final gxR = _interp(tRight, gxRight, tCommon);
    final azL = _interp(tLeft, azLeft, tCommon);
    final azR = _interp(tRight, azRight, tCommon);
    final rollL = _interp(tLeft, rollLeft, tCommon);
    final rollR = _interp(tRight, rollRight, tCommon);

    final envL = _normalize(_envelope(gxL, envelopeWindow));
    final envR = _normalize(_envelope(gxR, envelopeWindow));

    final peaksL = _findPeaks(envL, minDist: (0.25 * SAMPLE_RATE_HZ).toInt());
    final peaksR = _findPeaks(envR, minDist: (0.25 * SAMPLE_RATE_HZ).toInt());

    final stepsLeft = peaksL.length;
    final stepsRight = peaksR.length;
    final totalSteps = stepsLeft + stepsRight;

    final duration = tCommon.isNotEmpty ? tCommon.last - tCommon.first : 0.0;
    final cadence = duration > 0 ? (totalSteps / duration) * 60.0 : 0.0;

    double? meanL = _meanDiff(peaksL.map((i) => tCommon[i]).toList());
    double? meanR = _meanDiff(peaksR.map((i) => tCommon[i]).toList());

    double? symmetry;
    if (meanL != null && meanR != null && (meanL + meanR) > 0) {
      symmetry = 100 * (1 - (meanL - meanR).abs() / ((meanL + meanR) / 2));
    }

    final rmsL = _rms(azL);
    final rmsR = _rms(azR);

    double? impactSym;
    if ((rmsL + rmsR) > 0) {
      impactSym = 100 * (1 - (rmsL - rmsR).abs() / ((rmsL + rmsR) / 2));
    }

    final stdL = _std(rollL);
    final stdR = _std(rollR);

    double rollStability = 100;
    if ((stdL + stdR) > 0) {
      rollStability = 100 * (1 - (stdL - stdR).abs() / ((stdL + stdR) / 2));
    }

    double meanToeL = _mean(left.map((e) => e.load1).toList());
    double meanHeelL = _mean(left.map((e) => e.load2).toList());
    double meanToeR = _mean(right.map((e) => e.load1).toList());
    double meanHeelR = _mean(right.map((e) => e.load2).toList());

    String regionL = meanToeL > meanHeelL ? 'Toe' : 'Heel';
    String regionR = meanToeR > meanHeelR ? 'Toe' : 'Heel';

    double loadSym = 0;
    final totalL = meanToeL + meanHeelL;
    final totalR = meanToeR + meanHeelR;
    if ((totalL + totalR) > 0) {
      loadSym = 100 * (1 - (totalL - totalR).abs() / ((totalL + totalR) / 2));
    }

    return {
      'duration_s': duration,
      'left_steps': stepsLeft,
      'right_steps': stepsRight,
      'total_steps': totalSteps,
      'cadence_spm': cadence,
      'symmetry_percent': symmetry,
      'impact_symmetry_percent': impactSym,
      'roll_stability_percent': rollStability,
      'mean_toe_left': meanToeL,
      'mean_heel_left': meanHeelL,
      'mean_toe_right': meanToeR,
      'mean_heel_right': meanHeelR,
      'pressure_region_left': regionL,
      'pressure_region_right': regionR,
      'load_symmetry_percent': loadSym,
      't_common': tCommon,
      'env_left_n': envL,
      'env_right_n': envR,
      'peaks_left': peaksL,
      'peaks_right': peaksR,
    };
  }

  static List<double> _interp(List<double> t, List<double> v, List<double> tq) {
    if (t.isEmpty || t.length < 2) return List.filled(tq.length, 0.0);
    final out = List<double>.filled(tq.length, 0.0);
    int j = 0;
    for (int i = 0; i < tq.length; i++) {
      while (j < t.length - 2 && t[j + 1] < tq[i]) j++;
      final t0 = t[j], t1 = t[j + 1];
      final v0 = v[j], v1 = v[j + 1];
      final denom = t1 - t0;
      if (denom == 0) {
        out[i] = v0;
      } else {
        final frac = (tq[i] - t0) / denom;
        out[i] = v0 + frac * (v1 - v0);
      }
    }
    return out;
  }

  static List<double> _envelope(List<double> x, int w) {
    final out = List<double>.filled(x.length, 0);
    final h = (w / 2).floor();
    for (int i = 0; i < x.length; i++) {
      int a = math.max(0, i - h);
      int b = math.min(x.length - 1, i + h);
      double s = 0;
      for (int k = a; k <= b; k++) s += x[k].abs();
      out[i] = s / (b - a + 1);
    }
    return out;
  }

  static List<double> _normalize(List<double> x) {
    final m = _mean(x);
    final sd = _std(x);
    if (sd == 0) return x.map((_) => 0.0).toList();
    return x.map((v) => (v - m) / sd).toList();
  }

  static List<int> _findPeaks(
    List<double> x, {
    required int minDist,
    double h = 0.6,
  }) {
    final p = <int>[];
    for (int i = 1; i < x.length - 1; i++) {
      if (x[i] > h && x[i] > x[i - 1] && x[i] > x[i + 1]) {
        if (p.isEmpty || i - p.last >= minDist) p.add(i);
      }
    }
    return p;
  }

  static double? _meanDiff(List<double> t) {
    if (t.length < 2) return null;
    double s = 0;
    for (int i = 1; i < t.length; i++) s += t[i] - t[i - 1];
    return s / (t.length - 1);
  }

  static double _mean(List<double> x) =>
      x.isEmpty ? 0 : x.reduce((a, b) => a + b) / x.length;

  static double _rms(List<double> x) =>
      math.sqrt(_mean(x.map((v) => v * v).toList()));

  static double _std(List<double> x) {
    if (x.isEmpty) return 0;
    final m = _mean(x);
    return math.sqrt(
      x.map((v) => (v - m) * (v - m)).reduce((a, b) => a + b) / x.length,
    );
  }
}

// =============================================================
// RESULTS SCREEN
// =============================================================
class ResultsScreen extends StatelessWidget {
  final Map<String, dynamic> result;
  final List<ImuSample> leftSamples;
  final List<ImuSample> rightSamples;

  const ResultsScreen({
    super.key,
    required this.result,
    required this.leftSamples,
    required this.rightSamples,
  });

  Widget _metric(String title, String value) {
    return Card(
      child: SizedBox(
        width: 160,
        child: ListTile(
          title: Text(title),
          trailing: Text(
            value,
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
        ),
      ),
    );
  }

  Widget _lineChart(
    String title,
    List<double> t,
    List<double> sig,
    List<int> peaks,
    Color color,
  ) {
    final spots = <FlSpot>[];
    for (int i = 0; i < sig.length; i++) {
      spots.add(FlSpot(t[i], sig[i]));
    }

    final peakXs = peaks.map((i) => t[i]).toSet();

    return Card(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text(
              title,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          SizedBox(
            height: 220,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: LineChart(
                LineChartData(
                  lineBarsData: [
                    LineChartBarData(
                      spots: spots,
                      isCurved: true,
                      color: color,
                      dotData: FlDotData(
                        show: true,
                        checkToShowDot: (s, _) => peakXs.contains(s.x),
                      ),
                    ),
                  ],
                  titlesData: FlTitlesData(show: false),
                  gridData: FlGridData(show: true),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _exportCsv(BuildContext context) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final file = File('${dir.path}/gait_test_$timestamp.csv');

      final rows = <List<dynamic>>[
        [
          'phone_ts',
          'esp_ts',
          'ax',
          'ay',
          'az',
          'gx',
          'gy',
          'gz',
          'pitch',
          'roll',
          'load1',
          'load2',
          'load_total',
          'side',
        ],
      ];

      for (final s in leftSamples) {
        rows.add([
          s.phoneTsMs,
          s.espTsMs,
          s.ax,
          s.ay,
          s.az,
          s.gx,
          s.gy,
          s.gz,
          s.pitch,
          s.roll,
          s.load1,
          s.load2,
          s.loadTotal,
          'LEFT',
        ]);
      }

      for (final s in rightSamples) {
        rows.add([
          s.phoneTsMs,
          s.espTsMs,
          s.ax,
          s.ay,
          s.az,
          s.gx,
          s.gy,
          s.gz,
          s.pitch,
          s.roll,
          s.load1,
          s.load2,
          s.loadTotal,
          'RIGHT',
        ]);
      }

      final csv = const ListToCsvConverter().convert(rows);
      await file.writeAsString(csv);

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('✅ CSV exported to:\n${file.path}'),
            duration: const Duration(seconds: 4),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('❌ Export failed: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (result.containsKey('error')) {
      return Scaffold(
        appBar: AppBar(title: const Text('Results')),
        body: Center(child: Text(result['error'].toString())),
      );
    }

    final t = List<double>.from(result['t_common']);
    final envL = List<double>.from(result['env_left_n']);
    final envR = List<double>.from(result['env_right_n']);
    final peaksL = List<int>.from(result['peaks_left']);
    final peaksR = List<int>.from(result['peaks_right']);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Gait Analysis Results'),
        backgroundColor: Colors.teal,
        actions: [
          IconButton(
            icon: const Icon(Icons.download),
            onPressed: () => _exportCsv(context),
            tooltip: 'Export CSV',
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Card(
              color: Colors.green.shade50,
              child: ListTile(
                leading: const Icon(Icons.save_alt, color: Colors.green),
                title: const Text(
                  'Export Test Results',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                subtitle: const Text('Download CSV file to device'),
                trailing: ElevatedButton.icon(
                  icon: const Icon(Icons.download),
                  label: const Text('Export CSV'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green,
                    foregroundColor: Colors.white,
                  ),
                  onPressed: () => _exportCsv(context),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _metric(
                  'Duration (s)',
                  result['duration_s'].toStringAsFixed(2),
                ),
                _metric('Left Steps', result['left_steps'].toString()),
                _metric('Right Steps', result['right_steps'].toString()),
                _metric('Total Steps', result['total_steps'].toString()),
                _metric(
                  'Cadence (spm)',
                  result['cadence_spm'].toStringAsFixed(2),
                ),
                _metric(
                  'Symmetry (%)',
                  result['symmetry_percent'] != null
                      ? result['symmetry_percent'].toStringAsFixed(2)
                      : '-',
                ),
                _metric(
                  'Impact Sym (%)',
                  result['impact_symmetry_percent'] != null
                      ? result['impact_symmetry_percent'].toStringAsFixed(2)
                      : '-',
                ),
                _metric(
                  'Roll Stability (%)',
                  result['roll_stability_percent'].toStringAsFixed(2),
                ),
              ],
            ),
            const SizedBox(height: 16),
            _lineChart('Left Envelope', t, envL, peaksL, Colors.blue),
            const SizedBox(height: 12),
            _lineChart('Right Envelope', t, envR, peaksR, Colors.red),
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  children: [
                    const Text(
                      'Load Summary (Mean)',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        Column(
                          children: [
                            const Text('Left'),
                            Text(
                              'Toe: ${result['mean_toe_left'].toStringAsFixed(2)}',
                            ),
                            Text(
                              'Heel: ${result['mean_heel_left'].toStringAsFixed(2)}',
                            ),
                            Text('Region: ${result['pressure_region_left']}'),
                          ],
                        ),
                        Column(
                          children: [
                            const Text('Right'),
                            Text(
                              'Toe: ${result['mean_toe_right'].toStringAsFixed(2)}',
                            ),
                            Text(
                              'Heel: ${result['mean_heel_right'].toStringAsFixed(2)}',
                            ),
                            Text('Region: ${result['pressure_region_right']}'),
                          ],
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Load Symmetry: ${result['load_symmetry_percent'].toStringAsFixed(2)}%',
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================
// ACCOUNT PAGE (UPDATED WITH REAL PAGES)
// =============================================================
enum AccountView { home, setupDevice, profile, doctorProfile, faqs }

class AccountPage extends StatefulWidget {
  const AccountPage({super.key});

  @override
  State<AccountPage> createState() => _AccountPageState();
}

class _AccountPageState extends State<AccountPage> {
  AccountView _view = AccountView.home;

  void resetToHome() {
    setState(() {
      _view = AccountView.home;
    });
  }

  void openSetupDevice() {
    setState(() {
      _view = AccountView.setupDevice;
    });
  }

  void openProfile() {
    setState(() {
      _view = AccountView.profile;
    });
  }

  void openDoctorProfile() {
    setState(() {
      _view = AccountView.doctorProfile;
    });
  }

  void openFAQs() {
    setState(() {
      _view = AccountView.faqs;
    });
  }

  @override
  Widget build(BuildContext context) {
    // Setup Device view
    // Setup Device view
    if (_view == AccountView.setupDevice) {
      return PopScope(
        canPop: false,
        onPopInvoked: (didPop) {
          if (!didPop) {
            resetToHome();
          }
        },
        child: Column(
          children: [
            Container(
              margin: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.05),
                    blurRadius: 10,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Row(
                children: [
                  Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: resetToHome,
                      borderRadius: BorderRadius.circular(12),
                      child: Container(
                        padding: const EdgeInsets.all(8),
                        child: Icon(
                          Icons.arrow_back_ios_new_rounded,
                          size: 20,
                          color: Colors.teal.shade600,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  const Text(
                    'Setup Device',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),
            const Expanded(child: BleScanPage()),
          ],
        ),
      );
    }

    // Profile view
    if (_view == AccountView.profile) {
      return PopScope(
        canPop: false,
        onPopInvoked: (didPop) {
          if (!didPop) {
            resetToHome();
          }
        },
        child: ProfilePage(onBack: resetToHome),
      );
    }

    // Doctor Profile view
    if (_view == AccountView.doctorProfile) {
      return PopScope(
        canPop: false,
        onPopInvoked: (didPop) {
          if (!didPop) {
            resetToHome();
          }
        },
        child: DoctorProfilePage(onBack: resetToHome),
      );
    }

    // FAQs view
    if (_view == AccountView.faqs) {
      return PopScope(
        canPop: false,
        onPopInvoked: (didPop) {
          if (!didPop) {
            resetToHome();
          }
        },
        child: FAQsPage(onBack: resetToHome),
      );
    }

    // Home view (default)
    return Scaffold(
      backgroundColor: const Color(0xFFE0F2F1), // Light cyan background
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              // User Profile Header - Curved bubble like gait score card
              GestureDetector(
                onTap: openProfile,
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [Colors.teal.shade400, Colors.teal.shade600],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.teal.withOpacity(0.3),
                        blurRadius: 15,
                        offset: const Offset(0, 5),
                      ),
                    ],
                  ),
                  child: Row(
                    children: [
                      // Profile Picture
                      Stack(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(3),
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(color: Colors.white, width: 3),
                            ),
                            child: CircleAvatar(
                              radius: 42,
                              backgroundColor: Colors.white,
                              child: Icon(
                                Icons.person,
                                size: 48,
                                color: Colors.teal.shade400,
                              ),
                            ),
                          ),
                          Positioned(
                            bottom: 0,
                            right: 0,
                            child: Container(
                              padding: const EdgeInsets.all(6),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                shape: BoxShape.circle,
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withOpacity(0.2),
                                    blurRadius: 4,
                                  ),
                                ],
                              ),
                              child: Icon(
                                Icons.edit,
                                size: 14,
                                color: Colors.teal.shade600,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(width: 20),
                      // Name and greeting
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Santhosh',
                              style: TextStyle(
                                fontSize: 22,
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              'Tap to edit profile',
                              style: TextStyle(
                                fontSize: 13,
                                color: Colors.white.withOpacity(0.85),
                              ),
                            ),
                          ],
                        ),
                      ),
                      // Arrow indicator
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.2),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Icon(
                          Icons.arrow_forward_ios,
                          color: Colors.white,
                          size: 18,
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 16),

              // Menu Items - Expanded to fill remaining space
              Expanded(
                child: Column(
                  children: [
                    _accountCard(
                      icon: Icons.medical_services_outlined,
                      title: 'Doctor\'s Details',
                      subtitle: 'Your assigned healthcare provider',
                      color: Colors.purple,
                      onTap: openDoctorProfile,
                    ),
                    _accountCard(
                      icon: Icons.bluetooth_connected,
                      title: 'Setup Device',
                      subtitle: 'Connect device',
                      color: Colors.teal,
                      onTap: openSetupDevice,
                      showStatus: true,
                    ),
                    _accountCard(
                      icon: Icons.help_outline,
                      title: 'FAQs',
                      subtitle: 'Frequently asked questions',
                      color: Colors.orange,
                      onTap: openFAQs,
                    ),
                    _accountCard(
                      icon: Icons.info_outline,
                      title: 'About App',
                      subtitle: 'Version 1.0.0',
                      color: Colors.grey,
                      onTap: () {
                        showGeneralDialog(
                          context: context,
                          barrierDismissible: true,
                          barrierLabel: 'About',
                          barrierColor: Colors.black.withOpacity(0.5),
                          transitionDuration: const Duration(milliseconds: 300),
                          pageBuilder: (context, anim1, anim2) {
                            return Center(
                              child: Material(
                                color: Colors.transparent,
                                child: Container(
                                  margin: const EdgeInsets.all(24),
                                  padding: const EdgeInsets.all(24),
                                  decoration: BoxDecoration(
                                    gradient: LinearGradient(
                                      begin: Alignment.topLeft,
                                      end: Alignment.bottomRight,
                                      colors: [
                                        Colors.white.withOpacity(0.95),
                                        Colors.white.withOpacity(0.85),
                                      ],
                                    ),
                                    borderRadius: BorderRadius.circular(24),
                                    border: Border.all(
                                      color: Colors.white.withOpacity(0.5),
                                      width: 1.5,
                                    ),
                                    boxShadow: [
                                      BoxShadow(
                                        color: Colors.teal.withOpacity(0.2),
                                        blurRadius: 30,
                                        spreadRadius: 5,
                                      ),
                                    ],
                                  ),
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Container(
                                        padding: const EdgeInsets.all(16),
                                        decoration: BoxDecoration(
                                          gradient: LinearGradient(
                                            colors: [
                                              Colors.teal.shade400,
                                              Colors.teal.shade600,
                                            ],
                                            begin: Alignment.topLeft,
                                            end: Alignment.bottomRight,
                                          ),
                                          shape: BoxShape.circle,
                                          boxShadow: [
                                            BoxShadow(
                                              color: Colors.teal.withOpacity(
                                                0.3,
                                              ),
                                              blurRadius: 15,
                                              spreadRadius: 2,
                                            ),
                                          ],
                                        ),
                                        child: const Icon(
                                          Icons.directions_walk,
                                          size: 48,
                                          color: Colors.white,
                                        ),
                                      ),
                                      const SizedBox(height: 20),
                                      const Text(
                                        'SafeStep',
                                        style: TextStyle(
                                          fontSize: 24,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 12,
                                          vertical: 4,
                                        ),
                                        decoration: BoxDecoration(
                                          color: Colors.teal.shade50,
                                          borderRadius: BorderRadius.circular(
                                            12,
                                          ),
                                        ),
                                        child: Text(
                                          'Version 1.0.0',
                                          style: TextStyle(
                                            fontSize: 12,
                                            color: Colors.teal.shade700,
                                            fontWeight: FontWeight.w500,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(height: 20),
                                      Text(
                                        'SafeStep is a smart gait analysis application that helps monitor and improve your walking patterns for better rehabilitation outcomes.',
                                        textAlign: TextAlign.center,
                                        style: TextStyle(
                                          fontSize: 14,
                                          color: Colors.grey.shade600,
                                          height: 1.5,
                                        ),
                                      ),
                                      const SizedBox(height: 24),
                                      Container(
                                        padding: const EdgeInsets.all(16),
                                        decoration: BoxDecoration(
                                          color: Colors.grey.shade50,
                                          borderRadius: BorderRadius.circular(
                                            12,
                                          ),
                                        ),
                                        child: Column(
                                          children: [
                                            _aboutInfoRow(
                                              Icons.code,
                                              'Developed by',
                                              'SafeStep Team',
                                            ),
                                            const SizedBox(height: 12),
                                            _aboutInfoRow(
                                              Icons.calendar_today,
                                              'Released',
                                              'January 2026',
                                            ),
                                            const SizedBox(height: 12),
                                            _aboutInfoRow(
                                              Icons.phone_android,
                                              'Platform',
                                              'Android & iOS',
                                            ),
                                          ],
                                        ),
                                      ),
                                      const SizedBox(height: 24),
                                      SizedBox(
                                        width: double.infinity,
                                        child: ElevatedButton(
                                          onPressed: () =>
                                              Navigator.pop(context),
                                          style: ElevatedButton.styleFrom(
                                            backgroundColor: Colors.teal,
                                            foregroundColor: Colors.white,
                                            padding: const EdgeInsets.symmetric(
                                              vertical: 14,
                                            ),
                                            shape: RoundedRectangleBorder(
                                              borderRadius:
                                                  BorderRadius.circular(12),
                                            ),
                                          ),
                                          child: const Text('Close'),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            );
                          },
                          transitionBuilder: (context, anim1, anim2, child) {
                            return FadeTransition(
                              opacity: anim1,
                              child: ScaleTransition(
                                scale: Tween<double>(begin: 0.8, end: 1.0)
                                    .animate(
                                      CurvedAnimation(
                                        parent: anim1,
                                        curve: Curves.easeOutBack,
                                      ),
                                    ),
                                child: child,
                              ),
                            );
                          },
                        );
                      },
                    ),
                    const Spacer(),
                    // Logout Button
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: () {
                          showDialog(
                            context: context,
                            builder: (context) => AlertDialog(
                              title: const Text('Logout'),
                              content: const Text(
                                'Are you sure you want to logout?',
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(context),
                                  child: const Text('Cancel'),
                                ),
                                ElevatedButton(
                                  onPressed: () {
                                    Navigator.pop(context);
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(
                                        content: Text(
                                          'Logged out successfully',
                                        ),
                                        backgroundColor: Colors.teal,
                                      ),
                                    );
                                  },
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: Colors.red,
                                    foregroundColor: Colors.white,
                                  ),
                                  child: const Text('Logout'),
                                ),
                              ],
                            ),
                          );
                        },
                        icon: const Icon(Icons.logout, color: Colors.red),
                        label: const Text(
                          'Logout',
                          style: TextStyle(color: Colors.red),
                        ),
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(color: Colors.red),
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _quickStat(String value, String label) {
    return Column(
      children: [
        Text(
          value,
          style: const TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: TextStyle(fontSize: 12, color: Colors.white.withOpacity(0.8)),
        ),
      ],
    );
  }

  Widget _aboutInfoRow(IconData icon, String label, String value) {
    return Row(
      children: [
        Icon(icon, size: 18, color: Colors.teal.shade600),
        const SizedBox(width: 12),
        Text(
          label,
          style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
        ),
        const Spacer(),
        Text(
          value,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
      ],
    );
  }

  Widget _accountCard({
    required IconData icon,
    required String title,
    required String subtitle,
    required Color color,
    required VoidCallback onTap,
    bool showStatus = false,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: color.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(icon, color: color, size: 24),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        subtitle,
                        style: TextStyle(
                          fontSize: 13,
                          color: Colors.grey.shade600,
                        ),
                      ),
                    ],
                  ),
                ),
                if (showStatus)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: DeviceManager.isReady
                          ? Colors.green.shade50
                          : Colors.orange.shade50,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      DeviceManager.isReady ? 'Connected' : 'Not Connected',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: DeviceManager.isReady
                            ? Colors.green.shade700
                            : Colors.orange.shade700,
                      ),
                    ),
                  ),
                const SizedBox(width: 8),
                Icon(Icons.chevron_right, color: Colors.grey.shade400),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// =============================================================
// PROFILE PAGE (WITH EDIT & SAVE)
// =============================================================
class ProfilePage extends StatefulWidget {
  final VoidCallback onBack;

  const ProfilePage({super.key, required this.onBack});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  bool _isEditing = false;

  // Controllers for text fields
  final TextEditingController _nameController = TextEditingController(
    text: 'Santhosh',
  );
  final TextEditingController _emailController = TextEditingController(
    text: 'santhosh@example.com',
  );
  final TextEditingController _phoneController = TextEditingController(
    text: '+91 9876543210',
  );
  final TextEditingController _ageController = TextEditingController(
    text: '23',
  );
  final TextEditingController _genderController = TextEditingController(
    text: 'Male',
  );
  final TextEditingController _weightController = TextEditingController(
    text: '65 kg',
  );
  final TextEditingController _heightController = TextEditingController(
    text: '175 cm',
  );

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _phoneController.dispose();
    _ageController.dispose();
    _genderController.dispose();
    _weightController.dispose();
    _heightController.dispose();
    super.dispose();
  }

  void _toggleEdit() {
    setState(() {
      _isEditing = !_isEditing;
    });
  }

  void _saveProfile() {
    setState(() {
      _isEditing = false;
    });
    _showProfileSnackBar('Profile saved successfully');
  }

  OverlayEntry? _snackBarOverlay;

  void _showProfileSnackBar(String message) {
    _snackBarOverlay?.remove();
    _snackBarOverlay = null;

    late OverlayEntry overlayEntry;

    overlayEntry = OverlayEntry(
      builder: (context) => _ProfileSnackBar(
        message: message,
        onDismiss: () {
          overlayEntry.remove();
          _snackBarOverlay = null;
        },
      ),
    );

    _snackBarOverlay = overlayEntry;
    Overlay.of(context).insert(overlayEntry);

    Future.delayed(const Duration(milliseconds: 2500), () {
      if (_snackBarOverlay == overlayEntry) {
        overlayEntry.remove();
        _snackBarOverlay = null;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFE0F2F1),
      body: SafeArea(
        child: Column(
          children: [
            // Header bar
            Container(
              margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.05),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Row(
                children: [
                  Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: widget.onBack,
                      borderRadius: BorderRadius.circular(8),
                      child: Container(
                        padding: const EdgeInsets.all(6),
                        child: Icon(
                          Icons.arrow_back_ios_new_rounded,
                          size: 18,
                          color: Colors.teal.shade600,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  const Text(
                    'Profile',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),
            // Content
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    // Profile Header Card
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [Colors.teal.shade400, Colors.teal.shade600],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                        borderRadius: BorderRadius.circular(20),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.teal.withOpacity(0.3),
                            blurRadius: 15,
                            offset: const Offset(0, 5),
                          ),
                        ],
                      ),
                      child: Column(
                        children: [
                          Stack(
                            children: [
                              Container(
                                padding: const EdgeInsets.all(4),
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: Colors.white,
                                    width: 3,
                                  ),
                                ),
                                child: CircleAvatar(
                                  radius: 45,
                                  backgroundColor: Colors.white,
                                  child: Icon(
                                    Icons.person,
                                    size: 50,
                                    color: Colors.teal.shade400,
                                  ),
                                ),
                              ),
                              if (_isEditing)
                                Positioned(
                                  bottom: 0,
                                  right: 0,
                                  child: Container(
                                    padding: const EdgeInsets.all(6),
                                    decoration: BoxDecoration(
                                      color: Colors.white,
                                      shape: BoxShape.circle,
                                      boxShadow: [
                                        BoxShadow(
                                          color: Colors.black.withOpacity(0.2),
                                          blurRadius: 4,
                                        ),
                                      ],
                                    ),
                                    child: Icon(
                                      Icons.camera_alt,
                                      size: 16,
                                      color: Colors.teal.shade600,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Text(
                            _nameController.text,
                            style: const TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            _emailController.text,
                            style: TextStyle(
                              fontSize: 14,
                              color: Colors.white.withOpacity(0.9),
                            ),
                          ),
                          const SizedBox(height: 16),
                          GestureDetector(
                            onTap: _toggleEdit,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 20,
                                vertical: 8,
                              ),
                              decoration: BoxDecoration(
                                color: _isEditing
                                    ? Colors.red.withOpacity(0.2)
                                    : Colors.white.withOpacity(0.2),
                                borderRadius: BorderRadius.circular(20),
                                border: Border.all(
                                  color: _isEditing
                                      ? Colors.red.shade200
                                      : Colors.white.withOpacity(0.5),
                                ),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    _isEditing ? Icons.close : Icons.edit,
                                    size: 16,
                                    color: _isEditing
                                        ? Colors.red.shade100
                                        : Colors.white,
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    _isEditing
                                        ? 'Cancel Editing'
                                        : 'Edit Profile',
                                    style: TextStyle(
                                      fontSize: 13,
                                      color: _isEditing
                                          ? Colors.red.shade100
                                          : Colors.white,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),
                    // Personal Info Section
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(16),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.05),
                            blurRadius: 10,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(
                                Icons.person_outline,
                                color: Colors.teal.shade600,
                                size: 20,
                              ),
                              const SizedBox(width: 8),
                              const Text(
                                'Personal Information',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          _modernProfileField(
                            'Name',
                            _nameController,
                            Icons.badge_outlined,
                          ),
                          _modernProfileField(
                            'Phone',
                            _phoneController,
                            Icons.phone_outlined,
                          ),
                          _modernProfileField(
                            'Age',
                            _ageController,
                            Icons.cake_outlined,
                          ),
                          _modernProfileField(
                            'Gender',
                            _genderController,
                            Icons.wc_outlined,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    // Health Info Section
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(16),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.05),
                            blurRadius: 10,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(
                                Icons.monitor_heart_outlined,
                                color: Colors.teal.shade600,
                                size: 20,
                              ),
                              const SizedBox(width: 8),
                              const Text(
                                'Health Information',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          _modernProfileField(
                            'Weight',
                            _weightController,
                            Icons.fitness_center_outlined,
                          ),
                          _modernProfileField(
                            'Height',
                            _heightController,
                            Icons.height_outlined,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),
                    // Save Button
                    if (_isEditing)
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          onPressed: _saveProfile,
                          icon: const Icon(Icons.check, size: 20),
                          label: const Text('Save Changes'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.teal,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                        ),
                      ),
                    const SizedBox(height: 16),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _modernProfileField(
    String label,
    TextEditingController controller,
    IconData icon,
  ) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
          color: _isEditing ? Colors.teal.shade50 : Colors.grey.shade50,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: _isEditing ? Colors.teal.shade200 : Colors.grey.shade200,
          ),
        ),
        child: Row(
          children: [
            Icon(
              icon,
              size: 20,
              color: _isEditing ? Colors.teal.shade600 : Colors.grey.shade500,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 11,
                      color: Colors.grey.shade600,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  TextField(
                    controller: controller,
                    enabled: _isEditing,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                      color: _isEditing ? Colors.black : Colors.grey.shade700,
                    ),
                    decoration: const InputDecoration(
                      border: InputBorder.none,
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(vertical: 4),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// Profile Snackbar Widget
class _ProfileSnackBar extends StatefulWidget {
  final String message;
  final VoidCallback onDismiss;

  const _ProfileSnackBar({required this.message, required this.onDismiss});

  @override
  State<_ProfileSnackBar> createState() => _ProfileSnackBarState();
}

class _ProfileSnackBarState extends State<_ProfileSnackBar>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<Offset> _slideAnimation;
  late Animation<double> _fadeAnimation;
  Offset _dragOffset = Offset.zero;
  bool _isDragging = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
    );
    _slideAnimation = Tween<Offset>(
      begin: const Offset(0, 1),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOut));
    _fadeAnimation = Tween<double>(begin: 0, end: 1).animate(_controller);
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _dismiss() {
    _controller.reverse().then((_) => widget.onDismiss());
  }

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: 16,
      right: 16,
      bottom: 16,
      child: FadeTransition(
        opacity: _fadeAnimation,
        child: SlideTransition(
          position: _slideAnimation,
          child: GestureDetector(
            onPanStart: (_) => setState(() => _isDragging = true),
            onPanUpdate: (details) {
              setState(() {
                _dragOffset += details.delta;
              });
            },
            onPanEnd: (details) {
              if (_dragOffset.dx.abs() > 80 || _dragOffset.dy.abs() > 40) {
                _dismiss();
              } else {
                setState(() {
                  _dragOffset = Offset.zero;
                  _isDragging = false;
                });
              }
            },
            child: Transform.translate(
              offset: _dragOffset,
              child: Opacity(
                opacity: _isDragging
                    ? (1 - (_dragOffset.distance / 200).clamp(0, 0.5))
                    : 1,
                child: Material(
                  color: Colors.transparent,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.green,
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.green.withOpacity(0.4),
                          blurRadius: 12,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.2),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: const Icon(
                            Icons.check_circle,
                            color: Colors.white,
                            size: 20,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            widget.message,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                        GestureDetector(
                          onTap: _dismiss,
                          child: Container(
                            padding: const EdgeInsets.all(4),
                            child: const Icon(
                              Icons.close,
                              color: Colors.white70,
                              size: 18,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// =============================================================
// DOCTOR'S PROFILE PAGE
// =============================================================
class DoctorProfilePage extends StatelessWidget {
  final VoidCallback onBack;

  const DoctorProfilePage({super.key, required this.onBack});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFFE0F2F1),
      child: Column(
        children: [
          // Header
          Container(
            margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.05),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Row(
              children: [
                Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: onBack,
                    borderRadius: BorderRadius.circular(8),
                    child: Container(
                      padding: const EdgeInsets.all(6),
                      child: Icon(
                        Icons.arrow_back_ios_new_rounded,
                        size: 18,
                        color: Colors.teal.shade600,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                const Text(
                  'Doctor\'s Profile',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
          // Content
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 16),
                  // Doctor card
                  Card(
                    elevation: 2,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Row(
                        children: [
                          CircleAvatar(
                            radius: 40,
                            backgroundColor: Colors.teal.shade100,
                            child: Icon(
                              Icons.person,
                              size: 40,
                              color: Colors.teal.shade700,
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'Dr. Pooja',
                                  style: TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  'Orthopedic Specialist',
                                  style: TextStyle(
                                    fontSize: 14,
                                    color: Colors.grey.shade600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  // About section
                  const Text(
                    'About',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Dr. Pooja is a highly experienced orthopedic specialist with over 15 years of practice in rehabilitation and gait analysis. She specializes in post-surgical recovery, mobility disorders, and custom treatment plans for patients with walking difficulties.',
                    style: TextStyle(
                      fontSize: 14,
                      color: Colors.grey.shade700,
                      height: 1.5,
                    ),
                  ),
                  const SizedBox(height: 24),
                  // Working hours and reviews
                  Row(
                    children: [
                      Expanded(
                        child: _infoButton(
                          'Working Hours',
                          Icons.access_time,
                          () {},
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _infoButton('Review', Icons.star_outline, () {}),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  // Recent review card
                  Card(
                    elevation: 1,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              CircleAvatar(
                                radius: 20,
                                backgroundColor: Colors.grey.shade300,
                                child: const Icon(Icons.person, size: 20),
                              ),
                              const SizedBox(width: 12),
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text(
                                    'Karthik Kumar',
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  Text(
                                    '10 days ago',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: Colors.grey.shade600,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Text(
                            'Excellent doctor! Very attentive and thorough in her assessments. She took the time to explain my condition and provided a clear treatment plan.',
                            style: TextStyle(
                              fontSize: 14,
                              color: Colors.grey.shade700,
                              height: 1.4,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: List.generate(
                              5,
                              (index) => Icon(
                                Icons.star,
                                size: 16,
                                color: Colors.amber.shade600,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _infoButton(String label, IconData icon, VoidCallback onTap) {
    return OutlinedButton.icon(
      onPressed: onTap,
      icon: Icon(icon, size: 18),
      label: Text(label),
      style: OutlinedButton.styleFrom(
        foregroundColor: Colors.teal,
        side: BorderSide(color: Colors.teal.shade300),
        padding: const EdgeInsets.symmetric(vertical: 12),
      ),
    );
  }
}

// =============================================================
// FAQs PAGE
// =============================================================
class FAQsPage extends StatelessWidget {
  final VoidCallback onBack;

  const FAQsPage({super.key, required this.onBack});

  @override
  Widget build(BuildContext context) {
    final faqs = [
      {
        'q': 'What is Safe Step? How it works?',
        'a':
            'Safe Step is a smart wearable footwear system that monitors your gait and weight distribution in real-time using sensors embedded in the sole.',
      },
      {
        'q': 'How to use this step help device?',
        'a':
            'Simply wear the smart footwear, connect it to your phone via Bluetooth, and start walking. The app will automatically track your data.',
      },
      {
        'q': 'What does the buzzer alert signifies?',
        'a':
            'The buzzer alerts you when there is improper weight distribution or an abnormal gait pattern detected.',
      },
      {
        'q': 'How do I connect the device to my phone?',
        'a':
            'Go to Account → Setup Device, scan for your footwear, and tap Connect for both left and right devices.',
      },
      {
        'q': 'Can I update the weight sensing threshold?',
        'a':
            'Yes, weight thresholds can be adjusted in the device settings based on your rehabilitation plan.',
      },
      {
        'q': 'Which should I do if I experience issues with the device or app?',
        'a':
            'Try restarting the device and app. If issues persist, contact support through the app or check the troubleshooting guide.',
      },
      {
        'q': 'Is the data shared with my doctor automatically?',
        'a':
            'Yes, if you enable cloud sync, your doctor can remotely access your gait data and monitor your progress.',
      },
      {
        'q':
            'What is expected if I repeatedly receive alerts with no change in gait?',
        'a':
            'Recalibrate the sensors or consult your doctor. Persistent alerts may indicate an underlying issue requiring attention.',
      },
    ];

    return Container(
      color: const Color(0xFFE0F2F1),
      child: Column(
        children: [
          // Header
          Container(
            margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.05),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Row(
              children: [
                Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: onBack,
                    borderRadius: BorderRadius.circular(8),
                    child: Container(
                      padding: const EdgeInsets.all(6),
                      child: Icon(
                        Icons.arrow_back_ios_new_rounded,
                        size: 18,
                        color: Colors.teal.shade600,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                const Text(
                  'FAQs',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
          // Content
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: faqs.length,
              itemBuilder: (context, index) {
                return _FAQTile(
                  question: faqs[index]['q']!,
                  answer: faqs[index]['a']!,
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _FAQTile extends StatefulWidget {
  final String question;
  final String answer;

  const _FAQTile({required this.question, required this.answer});

  @override
  State<_FAQTile> createState() => _FAQTileState();
}

class _FAQTileState extends State<_FAQTile> {
  bool _isExpanded = false;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Column(
        children: [
          ListTile(
            title: Text(
              widget.question,
              style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 15),
            ),
            trailing: Icon(
              _isExpanded ? Icons.expand_less : Icons.expand_more,
              color: Colors.teal,
            ),
            onTap: () {
              setState(() {
                _isExpanded = !_isExpanded;
              });
            },
          ),
          if (_isExpanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Text(
                widget.answer,
                style: TextStyle(
                  fontSize: 14,
                  color: Colors.grey.shade700,
                  height: 1.4,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// =============================================================
// BLE SCAN PAGE (UPDATES DeviceManager)
// =============================================================
class BleScanPage extends StatefulWidget {
  const BleScanPage({super.key});

  @override
  State<BleScanPage> createState() => _BleScanPageState();
}

class _BleScanPageState extends State<BleScanPage> {
  final List<ScanResult> scanResults = [];
  BluetoothDevice? leftDevice;
  BluetoothDevice? rightDevice;
  bool scanning = false;
  bool leftConnected = false;
  bool rightConnected = false;

  @override
  void initState() {
    super.initState();
    _initBluetooth();
  }

  Future<void> _initBluetooth() async {
    await _checkPermissions();
    FlutterBluePlus.scanResults.listen((results) {
      if (!mounted) return;
      setState(() {
        scanResults
          ..clear()
          ..addAll(results);
      });
    });
    FlutterBluePlus.isScanning.listen((s) {
      if (!mounted) return;
      setState(() {
        scanning = s;
      });
    });
  }

  Future<void> _checkPermissions() async {
    if (Platform.isAndroid) {
      await [
        Permission.bluetooth,
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.location,
      ].request();
    }
  }

  Future<void> startScan() async {
    final state = await FlutterBluePlus.adapterState.first;
    if (state != BluetoothAdapterState.on) {
      await FlutterBluePlus.turnOn();
      return;
    }

    if (scanning) return;

    // Aggressive scan settings for maximum range
    await FlutterBluePlus.startScan(
      timeout: const Duration(seconds: 15),
      androidScanMode: AndroidScanMode.lowLatency,
      androidUsesFineLocation: true,
    );
  }

  Future<void> stopScan() async {
    if (scanning) {
      await FlutterBluePlus.stopScan();
    }
  }

  Future<void> connect(BluetoothDevice d, bool isLeft) async {
    await stopScan();

    try {
      await d.connect(
        timeout: const Duration(seconds: 30),
        autoConnect: false,
        mtu: null,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Connection failed: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
      return;
    }

    // Request HIGH PRIORITY for better connection stability
    try {
      await d.requestConnectionPriority(
        connectionPriorityRequest: ConnectionPriority.high,
      );
    } catch (e) {
      // Non-fatal error
    }

    // Request larger MTU for better throughput
    try {
      await d.requestMtu(512);
    } catch (e) {
      // Non-fatal error
    }

    // Stabilization delay
    await Future.delayed(const Duration(milliseconds: 800));

    // Now save device
    setState(() {
      if (isLeft) {
        leftDevice = d;
        leftConnected = true;
        DeviceManager.setLeft(d);
      } else {
        rightDevice = d;
        rightConnected = true;
        DeviceManager.setRight(d);
      }
    });

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${isLeft ? "LEFT" : "RIGHT"} device connected: ${d.platformName}',
          ),
          backgroundColor: Colors.green,
        ),
      );
    }
  }

  @override
  void dispose() {
    stopScan();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool bothConnected = leftConnected && rightConnected;

    return Container(
      color: const Color(
        0xFFE0F2F1,
      ), // Light teal background matching app theme
      child: Column(
        children: [
          // Header with connection status
          Container(
            width: double.infinity,
            margin: const EdgeInsets.all(16),
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: bothConnected
                    ? [Colors.green.shade400, Colors.green.shade600]
                    : [Colors.teal.shade400, Colors.teal.shade600],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(20),
              boxShadow: [
                BoxShadow(
                  color: (bothConnected ? Colors.green : Colors.teal)
                      .withOpacity(0.3),
                  blurRadius: 15,
                  offset: const Offset(0, 5),
                ),
              ],
            ),
            child: Column(
              children: [
                // Device icons row
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    // Left device
                    _buildDeviceIndicator(
                      'Left',
                      Icons.chevron_left,
                      leftConnected,
                      leftDevice?.platformName,
                    ),
                    // Connection line
                    Container(
                      width: 60,
                      height: 3,
                      decoration: BoxDecoration(
                        color: bothConnected
                            ? Colors.white
                            : Colors.white.withOpacity(0.3),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    // Right device
                    _buildDeviceIndicator(
                      'Right',
                      Icons.chevron_right,
                      rightConnected,
                      rightDevice?.platformName,
                    ),
                  ],
                ),
                if (bothConnected) ...[
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.2),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.check_circle, color: Colors.white, size: 18),
                        SizedBox(width: 8),
                        Text(
                          'Ready for testing!',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),

          // Scan button
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: GestureDetector(
              onTap: scanning ? null : startScan,
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: scanning ? Colors.grey.shade300 : Colors.teal,
                    width: 2,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.05),
                      blurRadius: 10,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (scanning) ...[
                      SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.teal.shade400,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        'Scanning for devices...',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: Colors.grey.shade600,
                        ),
                      ),
                    ] else ...[
                      Icon(
                        Icons.bluetooth_searching,
                        color: Colors.teal.shade600,
                      ),
                      const SizedBox(width: 12),
                      Text(
                        'Scan for Devices',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: Colors.teal.shade700,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),

          const SizedBox(height: 16),

          // Section label
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: [
                Text(
                  'Available Devices',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: Colors.grey.shade700,
                  ),
                ),
                const Spacer(),
                if (scanResults.isNotEmpty)
                  Text(
                    '${scanResults.length} found',
                    style: TextStyle(fontSize: 14, color: Colors.grey.shade500),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          // Device List
          Expanded(
            child: scanResults.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          padding: const EdgeInsets.all(24),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            shape: BoxShape.circle,
                            boxShadow: [
                              BoxShadow(
                                color: Colors.teal.withOpacity(0.1),
                                blurRadius: 20,
                                spreadRadius: 5,
                              ),
                            ],
                          ),
                          child: Icon(
                            Icons.bluetooth,
                            size: 48,
                            color: Colors.teal.shade300,
                          ),
                        ),
                        const SizedBox(height: 20),
                        Text(
                          'No devices found',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                            color: Colors.grey.shade700,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Tap scan to search for nearby devices',
                          style: TextStyle(
                            fontSize: 14,
                            color: Colors.grey.shade500,
                          ),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    itemCount: scanResults.length,
                    itemBuilder: (context, index) {
                      final r = scanResults[index];
                      final name = r.device.platformName.isNotEmpty
                          ? r.device.platformName
                          : 'Unknown Device';
                      final isLeftDevice = leftDevice == r.device;
                      final isRightDevice = rightDevice == r.device;

                      return Container(
                        margin: const EdgeInsets.only(bottom: 12),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(16),
                          border: (isLeftDevice || isRightDevice)
                              ? Border.all(color: Colors.green, width: 2)
                              : null,
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.05),
                              blurRadius: 10,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Container(
                                    padding: const EdgeInsets.all(10),
                                    decoration: BoxDecoration(
                                      color: Colors.teal.shade50,
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                    child: Icon(
                                      Icons.bluetooth,
                                      color: Colors.teal.shade600,
                                      size: 20,
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          name,
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w600,
                                            fontSize: 15,
                                          ),
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          r.device.remoteId.str,
                                          style: TextStyle(
                                            fontSize: 12,
                                            color: Colors.grey.shade500,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  // RSSI indicator
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 4,
                                    ),
                                    decoration: BoxDecoration(
                                      color: Colors.grey.shade100,
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                          Icons.signal_cellular_alt,
                                          size: 14,
                                          color: r.rssi > -60
                                              ? Colors.green
                                              : r.rssi > -80
                                              ? Colors.orange
                                              : Colors.red,
                                        ),
                                        const SizedBox(width: 4),
                                        Text(
                                          '${r.rssi}',
                                          style: TextStyle(
                                            fontSize: 11,
                                            color: Colors.grey.shade600,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              Row(
                                children: [
                                  Expanded(
                                    child: _buildConnectButton(
                                      'Left',
                                      Icons.chevron_left,
                                      isLeftDevice,
                                      leftDevice == null,
                                      () => connect(r.device, true),
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: _buildConnectButton(
                                      'Right',
                                      Icons.chevron_right,
                                      isRightDevice,
                                      rightDevice == null,
                                      () => connect(r.device, false),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),

          // Continue button when both connected
          if (bothConnected)
            Padding(
              padding: const EdgeInsets.all(16),
              child: GestureDetector(
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => DataCollectionPage(
                        leftDevice: leftDevice!,
                        rightDevice: rightDevice!,
                      ),
                    ),
                  );
                },
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [Colors.green.shade400, Colors.green.shade600],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.green.withOpacity(0.3),
                        blurRadius: 10,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.play_arrow, color: Colors.white),
                      SizedBox(width: 8),
                      Text(
                        'Continue to Test',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildDeviceIndicator(
    String label,
    IconData icon,
    bool connected,
    String? deviceName,
  ) {
    return Column(
      children: [
        Container(
          width: 60,
          height: 60,
          decoration: BoxDecoration(
            color: connected ? Colors.white : Colors.white.withOpacity(0.2),
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 2),
          ),
          child: Icon(
            connected ? Icons.check : icon,
            color: connected ? Colors.green : Colors.white,
            size: 28,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w600,
            fontSize: 14,
          ),
        ),
        if (deviceName != null)
          Text(
            deviceName,
            style: TextStyle(
              color: Colors.white.withOpacity(0.8),
              fontSize: 10,
            ),
            overflow: TextOverflow.ellipsis,
          ),
      ],
    );
  }

  Widget _buildConnectButton(
    String label,
    IconData icon,
    bool isConnected,
    bool canConnect,
    VoidCallback onTap,
  ) {
    return GestureDetector(
      onTap: canConnect && !isConnected ? onTap : null,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: isConnected
              ? Colors.green.shade50
              : canConnect
              ? Colors.teal.shade50
              : Colors.grey.shade100,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isConnected
                ? Colors.green
                : canConnect
                ? Colors.teal
                : Colors.grey.shade300,
            width: 1.5,
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              isConnected ? Icons.check : icon,
              size: 18,
              color: isConnected
                  ? Colors.green
                  : canConnect
                  ? Colors.teal
                  : Colors.grey,
            ),
            const SizedBox(width: 6),
            Text(
              isConnected ? '$label ✓' : label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: isConnected
                    ? Colors.green.shade700
                    : canConnect
                    ? Colors.teal.shade700
                    : Colors.grey,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
