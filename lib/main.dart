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
      theme: ThemeData(primarySwatch: Colors.teal),
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 1,
        title: Row(
          children: [
            const SizedBox(width: 12),
            Image.asset('assets/Safe.png', height: 40, fit: BoxFit.contain),
            const Spacer(),
            Padding(
              padding: const EdgeInsets.only(right: 24),
              child: Text(
                'SafeStep',
                style: TextStyle(
                  color: Colors.teal,
                  fontSize: 18,
                  fontWeight: FontWeight.w500,
                ),
              ),
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
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        selectedItemColor: Colors.teal,
        unselectedItemColor: Colors.grey,
        type: BottomNavigationBarType.fixed,
        enableFeedback: false,
        selectedFontSize: 12,
        unselectedFontSize: 12,
        iconSize: 22,
        onTap: (i) {
          setState(() {
            _currentIndex = i;
            if (i == 3) {
              accountPageKey.currentState?.resetToHome();
            }
          });
        },
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.home), label: 'Home'),
          BottomNavigationBarItem(
            icon: Icon(Icons.description),
            label: 'Reports',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.assignment),
            label: 'Assignment',
          ),
          BottomNavigationBarItem(icon: Icon(Icons.person), label: 'Account'),
        ],
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
// HOME PAGE (WITH ANIMATED WALKING ICON)
// =============================================================
class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    // Check connection status
    final bool leftConnected = DeviceManager.leftDevice != null;
    final bool rightConnected = DeviceManager.rightDevice != null;
    final bool bothConnected = DeviceManager.isReady;

    return Container(
      color: Colors.white,
      child: Column(
        children: [
          // Header - Dynamic based on connection
          Container(
            padding: const EdgeInsets.all(20),
            color: bothConnected ? Colors.teal.shade50 : Colors.orange.shade50,
            child: Column(
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Icon(
                        bothConnected
                            ? Icons.directions_walk
                            : Icons.warning_amber_rounded,
                        color: bothConnected ? Colors.teal : Colors.orange,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            bothConnected
                                ? 'Ready to Record'
                                : leftConnected || rightConnected
                                ? 'Setup Incomplete'
                                : 'No Devices Connected',
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          Text(
                            bothConnected
                                ? 'Both devices connected'
                                : leftConnected || rightConnected
                                ? 'Connect remaining device'
                                : 'Please connect both footwear',
                            style: const TextStyle(
                              fontSize: 13,
                              color: Colors.grey,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),

          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Today's Activity
                  const Text(
                    'Today\'s Activity',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 16),

                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [Colors.teal.shade400, Colors.teal.shade600],
                      ),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: [
                        _statItem('0', 'Tests', Icons.assignment_turned_in),
                        Container(width: 1, height: 40, color: Colors.white30),
                        _statItem('0', 'Steps', Icons.directions_walk),
                        Container(width: 1, height: 40, color: Colors.white30),
                        _statItem('0', 'Minutes', Icons.timer),
                      ],
                    ),
                  ),

                  const SizedBox(height: 32),

                  // Device Status
                  const Text(
                    'Device Status',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 16),

                  _deviceStatusRow(
                    'Left Footwear',
                    leftConnected,
                    leftConnected ? 98 : null,
                  ),
                  const SizedBox(height: 12),
                  _deviceStatusRow(
                    'Right Footwear',
                    rightConnected,
                    rightConnected ? 95 : null,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _statItem(String value, String label, IconData icon) {
    return Column(
      children: [
        Icon(icon, color: Colors.white, size: 28),
        const SizedBox(height: 8),
        Text(
          value,
          style: const TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        ),
        Text(
          label,
          style: const TextStyle(fontSize: 12, color: Colors.white70),
        ),
      ],
    );
  }

  Widget _deviceStatusRow(String name, bool connected, int? battery) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: connected ? Colors.grey.shade50 : Colors.red.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: connected ? Colors.grey.shade200 : Colors.red.shade200,
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: connected ? Colors.green : Colors.red,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              name,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          if (connected && battery != null) ...[
            Icon(Icons.battery_full, color: Colors.green.shade600, size: 20),
            const SizedBox(width: 4),
            Text(
              '$battery%',
              style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
            ),
          ] else ...[
            Icon(Icons.link_off, color: Colors.red.shade600, size: 20),
            const SizedBox(width: 4),
            Text(
              'Not connected',
              style: TextStyle(
                fontSize: 13,
                color: Colors.red.shade700,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// =============================================================
// REPORTS PAGE
// =============================================================
class ReportsPage extends StatelessWidget {
  const ReportsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.white,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.bar_chart, size: 100, color: Colors.teal.shade200),
              const SizedBox(height: 24),
              Text(
                'Reports',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: Colors.teal.shade900,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'View your test history and progress',
                style: TextStyle(fontSize: 16, color: Colors.grey.shade600),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              const Text(
                'Coming soon...',
                style: TextStyle(
                  fontSize: 14,
                  color: Colors.grey,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// =============================================================
// ASSIGNMENT HOME PAGE (WITH CONNECTION CHECK)
// =============================================================
class AssignmentHomePage extends StatelessWidget {
  const AssignmentHomePage({super.key});

  void _handleTakeTest(BuildContext context) {
    print('═══════════════════════════════');
    print('🎯 TAKE TEST CLICKED');
    print('═══════════════════════════════');
    print('Left device: ${DeviceManager.leftDevice?.platformName ?? "NULL"}');
    print('Right device: ${DeviceManager.rightDevice?.platformName ?? "NULL"}');
    print('IsReady: ${DeviceManager.isReady}');

    // Check if both devices are connected
    if (!DeviceManager.isReady) {
      print('❌ Devices not ready - showing dialog');

      // Show dialog and redirect to setup
      showDialog(
        context: context,
        builder: (context) {
          return AlertDialog(
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Large error icon centered
                  const Icon(
                    Icons.warning_amber_rounded,
                    color: Colors.orange,
                    size: 80,
                  ),
                  const SizedBox(height: 24),

                  // Title text centered
                  const Text(
                    'Connect both footwear',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Please connect both footwear devices before taking a test.',
                    style: TextStyle(fontSize: 14),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 24),

                  // Left Device Status
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        DeviceManager.leftDevice != null
                            ? Icons.check_circle
                            : Icons.cancel,
                        color: DeviceManager.leftDevice != null
                            ? Colors.green
                            : Colors.red,
                        size: 24,
                      ),
                      const SizedBox(width: 8),
                      const Text(
                        'Left Footwear',
                        style: TextStyle(fontSize: 16),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),

                  // Right Device Status
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        DeviceManager.rightDevice != null
                            ? Icons.check_circle
                            : Icons.cancel,
                        color: DeviceManager.rightDevice != null
                            ? Colors.green
                            : Colors.red,
                        size: 24,
                      ),
                      const SizedBox(width: 8),
                      const Text(
                        'Right Footwear',
                        style: TextStyle(fontSize: 16),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),

                  // Buttons centered
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Cancel'),
                      ),
                      const SizedBox(width: 16),
                      ElevatedButton(
                        onPressed: () {
                          Navigator.pop(context);
                          appShellKey.currentState?.goToAccountSetup();
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.teal,
                          foregroundColor: Colors.white,
                        ),
                        child: const Text('Setup Devices'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      );
    } else {
      // Both devices connected - start test
      print('✅ Devices ready - navigating to DataCollectionPage');

      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => DataCollectionPage(
            leftDevice: DeviceManager.leftDevice!,
            rightDevice: DeviceManager.rightDevice!,
          ),
        ),
      ).then((_) {
        print('⬅️ Returned from DataCollectionPage');
      });
    }
  }

  Widget _buildDeviceStatusContent() {
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Connect both footwear'),
          const SizedBox(height: 16),

          // LEFT
          Row(
            children: [
              Icon(
                DeviceManager.leftDevice != null
                    ? Icons.check_circle
                    : Icons.cancel,
                color: DeviceManager.leftDevice != null
                    ? Colors.green
                    : Colors.red,
                size: 20,
              ),
              const SizedBox(width: 8),
              const Expanded(
                child: Text('Left Device', overflow: TextOverflow.ellipsis),
              ),
            ],
          ),
          const SizedBox(height: 8),

          // RIGHT
          Row(
            children: [
              Icon(
                DeviceManager.rightDevice != null
                    ? Icons.check_circle
                    : Icons.cancel,
                color: DeviceManager.rightDevice != null
                    ? Colors.green
                    : Colors.red,
                size: 20,
              ),
              const SizedBox(width: 8),
              const Expanded(
                child: Text('Right Device', overflow: TextOverflow.ellipsis),
              ),
            ],
          ),
        ],
      ),
    );
  }

  List<Widget> _buildDeviceStatusActions(BuildContext context) {
    return [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      ElevatedButton(
        onPressed: () {
          Navigator.pop(context);
          appShellKey.currentState?.goToAccountSetup();
        },
        style: ElevatedButton.styleFrom(backgroundColor: Colors.teal),
        child: const Text('Setup Devices'),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.white,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            // TAKE TEST TODAY BUTTON (1/3)
            Expanded(
              flex: 1,
              child: Card(
                elevation: 4,
                color: Colors.teal.shade50,
                child: InkWell(
                  onTap: () => _handleTakeTest(context),
                  child: Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.assignment_turned_in,
                          size: 64,
                          color: Colors.teal,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'Take Test Today',
                          style: TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.bold,
                            color: Colors.teal.shade900,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Start your gait analysis test',
                          style: TextStyle(
                            fontSize: 14,
                            color: Colors.teal.shade700,
                          ),
                        ),
                        const SizedBox(height: 16),
                        // Connection status indicator
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              DeviceManager.leftDevice != null
                                  ? Icons.check_circle
                                  : Icons.circle_outlined,
                              size: 16,
                              color: DeviceManager.leftDevice != null
                                  ? Colors.green
                                  : Colors.grey,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              'L',
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.grey.shade700,
                              ),
                            ),
                            const SizedBox(width: 16),
                            Icon(
                              DeviceManager.rightDevice != null
                                  ? Icons.check_circle
                                  : Icons.circle_outlined,
                              size: 16,
                              color: DeviceManager.rightDevice != null
                                  ? Colors.green
                                  : Colors.grey,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              'R',
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.grey.shade700,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            // RECENT ASSIGNMENTS (2/3)
            Expanded(
              flex: 2,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Recent Assignments',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: Colors.grey.shade800,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: ListView.builder(
                      itemCount: 5,
                      itemBuilder: (context, index) {
                        return Card(
                          margin: const EdgeInsets.only(bottom: 8),
                          child: ListTile(
                            leading: CircleAvatar(
                              backgroundColor: Colors.teal.shade100,
                              child: Icon(Icons.assignment, color: Colors.teal),
                            ),
                            title: Text('Test ${index + 1}'),
                            subtitle: Text(
                              'Completed on ${DateTime.now().subtract(Duration(days: index)).toString().split(' ')[0]}',
                            ),
                            trailing: Icon(Icons.arrow_forward_ios, size: 16),
                            onTap: () {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    'View Test ${index + 1} - details',
                                  ),
                                  duration: const Duration(seconds: 1),
                                ),
                              );
                            },
                          ),
                        );
                      },
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

  bool collecting = false;
  final List<ImuSample> leftSamples = [];
  final List<ImuSample> rightSamples = [];
  ImuSample? _latestLeft;
  ImuSample? _latestRight;

  @override
  void initState() {
    super.initState();
    print('🟢 DataCollectionPage initState');
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
    print('🔍 Discovering characteristics...');
    _leftChar = await _findNotifyChar(widget.leftDevice);
    _rightChar = await _findNotifyChar(widget.rightDevice);
    print('✓ Discovery complete');
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

  // ✅ FIXED: Clean start - no delays, no waiting!
  void _startCollecting() async {
    print('🔵 _startCollecting called');

    if (_leftChar == null || _rightChar == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Characteristics not ready. Please wait...'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    // Clear everything
    leftSamples.clear();
    rightSamples.clear();
    _latestLeft = null;
    _latestRight = null;
    collecting = true;

    if (mounted) setState(() {});

    print('📡 Enabling notifications...');

    // ✅ FIX 1: Request HIGH PRIORITY connection for both devices
    try {
      print('🚀 Requesting high priority connection...');
      await widget.leftDevice.requestConnectionPriority(
        connectionPriorityRequest: ConnectionPriority.high,
      );
      await widget.rightDevice.requestConnectionPriority(
        connectionPriorityRequest: ConnectionPriority.high,
      );
      print('✅ High priority enabled');
    } catch (e) {
      print('⚠️ Priority request failed (non-fatal): $e');
    }

    // ✅ FIX 2: Request larger MTU (Maximum Transmission Unit)
    try {
      print('📦 Requesting MTU increase...');
      await widget.leftDevice.requestMtu(512);
      await widget.rightDevice.requestMtu(512);
      print('✅ MTU increased');
    } catch (e) {
      print('⚠️ MTU request failed (non-fatal): $e');
    }

    // Small delay to let Android BLE stack adjust
    await Future.delayed(const Duration(milliseconds: 100));

    try {
      // Enable both simultaneously
      await _leftChar!.setNotifyValue(true);
      await _rightChar!.setNotifyValue(true);
    } catch (e) {
      print('❌ setNotify error: $e');
    }

    print('✓ Notifications enabled');

    // Cancel old subscriptions
    await _leftSub?.cancel();
    await _rightSub?.cancel();

    // Start listening
    final leftLines = _leftChar!.onValueReceived
        .map((b) => utf8.decode(b, allowMalformed: true))
        .transform(const LineSplitter());

    final rightLines = _rightChar!.onValueReceived
        .map((b) => utf8.decode(b, allowMalformed: true))
        .transform(const LineSplitter());

    _leftSub = leftLines.listen(
      (l) => _parseCsvLine(l, isLeft: true),
      onError: (e) => print('left notify err: $e'),
    );

    _rightSub = rightLines.listen(
      (l) => _parseCsvLine(l, isLeft: false),
      onError: (e) => print('right notify err: $e'),
    );

    print('✅ Collecting started - listening to both devices!');

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
      // ✅ ADD THIS: Print invalid packets
      print(
        '⚠️ Invalid packet from ${isLeft ? "LEFT" : "RIGHT"}: ${p.length} fields',
      );
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
      // ✅ CHANGE THIS: Print EVERY sample (not just every 50)
      print('📥 LEFT: ${leftSamples.length} samples');
    } else {
      rightSamples.add(s);
      _latestRight = s;
      // ✅ CHANGE THIS: Print EVERY sample (not just every 50)
      print('📥 RIGHT: ${rightSamples.length} samples');
    }

    // Update UI every 50 samples
    if (mounted &&
        (leftSamples.length % 50 == 0 || rightSamples.length % 50 == 0)) {
      setState(() {});
    }
  }

  void _stopCollecting() async {
    print('═════════════════════════════════════');
    print('🛑 STOP BUTTON CLICKED');
    print('═════════════════════════════════════');

    // ✅ FIX 1: Show "Generating Report" dialog IMMEDIATELY
    if (mounted) {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => PopScope(
          canPop: false,
          child: Dialog(
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

    // Give UI time to render the dialog
    await Future.delayed(const Duration(milliseconds: 100));

    collecting = false;

    print('🔄 Canceling subscriptions...');
    await _leftSub?.cancel();
    await _rightSub?.cancel();

    print('⏸️ Disabling notifications...');
    try {
      await _leftChar
          ?.setNotifyValue(false)
          .timeout(const Duration(seconds: 1));
      print('✅ LEFT notifications disabled');
    } catch (e) {
      print('⚠️ LEFT disable timeout: $e');
    }

    try {
      await _rightChar
          ?.setNotifyValue(false)
          .timeout(const Duration(seconds: 1));
      print('✅ RIGHT notifications disabled');
    } catch (e) {
      print('⚠️ RIGHT disable timeout: $e');
    }

    print('📊 Collection stopped');
    print('   Left samples: ${leftSamples.length}');
    print('   Right samples: ${rightSamples.length}');

    // Check if we have data
    if (leftSamples.isEmpty || rightSamples.isEmpty) {
      print('❌ No data collected');
      if (mounted) {
        Navigator.pop(context); // Close dialog
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No data collected. Please try again.'),
            backgroundColor: Colors.orange,
          ),
        );
      }
      return;
    }

    // ✅ FIX 2: Limit samples to prevent analyzer slowdown
    const maxSamples = 500; // ~5 seconds at 100Hz

    final limitedLeft = leftSamples.length > maxSamples
        ? leftSamples.sublist(leftSamples.length - maxSamples)
        : leftSamples;

    final limitedRight = rightSamples.length > maxSamples
        ? rightSamples.sublist(rightSamples.length - maxSamples)
        : rightSamples;

    print(
      '📊 Using samples: LEFT=${limitedLeft.length}, RIGHT=${limitedRight.length}',
    );

    print('🔬 Starting analysis...');
    print(
      '   Analyzing ${limitedLeft.length} left + ${limitedRight.length} right samples...',
    );

    try {
      final analyzer = GaitAnalyzer();
      final result = analyzer.analyze(
        limitedLeft,
        limitedRight,
        envelopeWindow: 50,
      );

      print('✅ Analysis complete!');

      if (result.containsKey('error')) {
        print('❌ Analysis error: ${result['error']}');
        if (mounted) {
          Navigator.pop(context); // Close dialog
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Analysis error: ${result['error']}'),
              backgroundColor: Colors.orange,
            ),
          );
        }
        return;
      }

      if (!mounted) {
        print('⚠️ Widget not mounted');
        return;
      }

      Navigator.pop(context); // Close "Generating Report" dialog

      print('📄 Navigating to ResultsScreen...');
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

      print('✅ Navigation successful');
    } catch (e, stackTrace) {
      print('❌ ERROR: $e');
      print(
        'Stack trace: ${stackTrace.toString().split('\n').take(5).join('\n')}',
      );
      if (mounted) {
        Navigator.pop(context); // Close dialog
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
    _leftSub?.cancel();
    _rightSub?.cancel();
    _leftConnSub?.cancel();
    _rightConnSub?.cancel();
    super.dispose();
  }

  // ... [Keep your existing build(), _liveCard(), etc. - NO CHANGES TO UI!]

  @override
  Widget build(BuildContext context) {
    print('🎨 Building DataCollectionPage UI');
    print('   collecting: $collecting');
    print('   _leftChar: $_leftChar');
    print('   _rightChar: $_rightChar');

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

                // Sample count display
                if (collecting) ...[
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.blue.shade50,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        Text(
                          'LEFT: ${leftSamples.length} samples',
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        Text(
                          'RIGHT: ${rightSamples.length} samples',
                          style: const TextStyle(fontWeight: FontWeight.bold),
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
    if (t.isEmpty) return List.filled(tq.length, 0.0);
    final out = List<double>.filled(tq.length, 0.0);
    int j = 0;
    for (int i = 0; i < tq.length; i++) {
      while (j < t.length - 2 && t[j + 1] < tq[i]) j++;
      final t0 = t[j], t1 = t[j + 1];
      final v0 = v[j], v1 = v[j + 1];
      final frac = (tq[i] - t0) / (t1 - t0);
      out[i] = v0 + frac * (v1 - v0);
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
              color: Colors.teal.shade50,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back),
                    onPressed: resetToHome,
                    visualDensity: VisualDensity.compact,
                    iconSize: 20,
                  ),
                  const SizedBox(width: 4),
                  const Text(
                    'Setup Device',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
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
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _accountTile(
          icon: Icons.person_outline,
          title: 'Profile',
          onTap: openProfile,
        ),
        _accountTile(
          icon: Icons.medical_information_outlined,
          title: 'Doctor\'s Details',
          onTap: openDoctorProfile,
        ),
        _accountTile(
          icon: Icons.bluetooth_connected,
          title: 'Setup Device',
          onTap: openSetupDevice,
        ),
        _accountTile(icon: Icons.help_outline, title: 'FAQs', onTap: openFAQs),
      ],
    );
  }

  Widget _accountTile({
    required IconData icon,
    required String title,
    required VoidCallback onTap,
  }) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: ListTile(
        leading: Icon(icon, color: Colors.teal),
        title: Text(title),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
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
    text: 'John Doe',
  );
  final TextEditingController _emailController = TextEditingController(
    text: 'johndoe@example.com',
  );
  final TextEditingController _phoneController = TextEditingController(
    text: '+91 9876543210',
  );
  final TextEditingController _ageController = TextEditingController(
    text: '45',
  );
  final TextEditingController _genderController = TextEditingController(
    text: 'Male',
  );
  final TextEditingController _weightController = TextEditingController(
    text: '75 kg',
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
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Profile saved successfully'),
        duration: Duration(seconds: 2),
        backgroundColor: Colors.green,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.white,
      child: Column(
        children: [
          // Header
          Container(
            color: Colors.teal.shade50,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back),
                  onPressed: widget.onBack,
                  visualDensity: VisualDensity.compact,
                  iconSize: 20,
                ),
                const SizedBox(width: 4),
                const Text(
                  'Profile',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                IconButton(
                  icon: Icon(_isEditing ? Icons.close : Icons.edit_outlined),
                  onPressed: _toggleEdit,
                  iconSize: 20,
                  color: _isEditing ? Colors.red : Colors.black,
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
                  const SizedBox(height: 16),
                  // Profile photo placeholder
                  CircleAvatar(
                    radius: 50,
                    backgroundColor: Colors.teal.shade100,
                    child: Icon(
                      Icons.person,
                      size: 60,
                      color: Colors.teal.shade700,
                    ),
                  ),
                  const SizedBox(height: 24),
                  _profileField('Name', _nameController),
                  _profileField('Email', _emailController),
                  _profileField('Phone', _phoneController),
                  _profileField('Age', _ageController),
                  _profileField('Gender', _genderController),
                  _profileField('Weight', _weightController),
                  _profileField('Height', _heightController),
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: _isEditing ? _saveProfile : null,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _isEditing ? Colors.teal : Colors.grey,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        disabledBackgroundColor: Colors.grey.shade300,
                        disabledForegroundColor: Colors.grey.shade600,
                      ),
                      child: const Text('Save'),
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

  Widget _profileField(String label, TextEditingController controller) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              fontSize: 14,
              color: Colors.grey,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: _isEditing ? Colors.white : Colors.grey.shade100,
              border: Border.all(
                color: _isEditing ? Colors.teal : Colors.grey.shade300,
              ),
              borderRadius: BorderRadius.circular(8),
            ),
            child: TextField(
              controller: controller,
              enabled: _isEditing,
              style: TextStyle(
                fontSize: 16,
                color: _isEditing ? Colors.black : Colors.grey.shade600,
              ),
              decoration: const InputDecoration(
                border: InputBorder.none,
                isDense: true,
                contentPadding: EdgeInsets.symmetric(vertical: 14),
              ),
            ),
          ),
        ],
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
      color: Colors.white,
      child: Column(
        children: [
          // Header
          Container(
            color: Colors.teal.shade50,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back),
                  onPressed: onBack,
                  visualDensity: VisualDensity.compact,
                  iconSize: 20,
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
      color: Colors.white,
      child: Column(
        children: [
          // Header
          Container(
            color: Colors.teal.shade50,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back),
                  onPressed: onBack,
                  visualDensity: VisualDensity.compact,
                  iconSize: 20,
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

    // ✅ ADD THESE HIGH-POWER SCAN SETTINGS
    await FlutterBluePlus.startScan(
      timeout: const Duration(seconds: 5),
      androidScanMode: AndroidScanMode.lowLatency, // ← High power scan
      androidUsesFineLocation: true, // ← Better accuracy
    );
  }

  Future<void> _stopScan() async {
    if (scanning) {
      await FlutterBluePlus.stopScan();
    }
  }

  Future<void> stopScan() async {
    if (scanning) {
      await FlutterBluePlus.stopScan();
    }
  }

  Future<void> connect(BluetoothDevice d, bool isLeft) async {
    await stopScan();

    print('🔵 Connecting to ${d.platformName}...');

    // ✅ FIX 1: Add autoConnect and mtu parameters
    await d.connect(
      timeout: const Duration(seconds: 15),
      autoConnect: false, // ← CRITICAL! Forces direct high-power connection
      mtu: null, // ← Let Flutter negotiate best MTU
    );

    print('✅ Connected! Optimizing connection...');

    // ✅ FIX 2: Request HIGH PRIORITY immediately after connect
    try {
      await d.requestConnectionPriority(
        connectionPriorityRequest: ConnectionPriority.high,
      );
      print('✅ High priority connection enabled');
    } catch (e) {
      print('⚠️ Priority request failed (non-fatal): $e');
    }

    // ✅ FIX 3: Request larger MTU for better throughput
    try {
      final mtu = await d.requestMtu(512);
      print('✅ MTU negotiated: $mtu bytes');
    } catch (e) {
      print('⚠️ MTU request failed (non-fatal): $e');
    }

    // ✅ FIX 4: Give Android BLE stack time to stabilize
    await Future.delayed(const Duration(milliseconds: 300));

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

    print('✅ ${isLeft ? "LEFT" : "RIGHT"} device ready');
  }

  @override
  void dispose() {
    _stopScan();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool bothConnected = leftConnected && rightConnected;

    return Container(
      color: Colors.white,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            // Scan Button
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: scanning ? null : startScan,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.teal,
                  foregroundColor: Colors.white,
                ),
                child: Text(scanning ? 'Scanning…' : 'Scan BLE Devices'),
              ),
            ),
            const SizedBox(height: 12),

            // Connection Status Card
            Card(
              color: bothConnected
                  ? Colors.green.shade50
                  : Colors.grey.shade100,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        // LEFT indicator
                        Column(
                          children: [
                            Icon(
                              leftConnected ? Icons.check_circle : Icons.cancel,
                              color: leftConnected ? Colors.green : Colors.red,
                              size: 32,
                            ),
                            const SizedBox(height: 4),
                            const Text(
                              'LEFT',
                              style: TextStyle(fontWeight: FontWeight.bold),
                            ),
                            if (leftDevice != null)
                              Text(
                                leftDevice!.platformName,
                                style: const TextStyle(fontSize: 10),
                              ),
                          ],
                        ),
                        // RIGHT indicator
                        Column(
                          children: [
                            Icon(
                              rightConnected
                                  ? Icons.check_circle
                                  : Icons.cancel,
                              color: rightConnected ? Colors.green : Colors.red,
                              size: 32,
                            ),
                            const SizedBox(height: 4),
                            const Text(
                              'RIGHT',
                              style: TextStyle(fontWeight: FontWeight.bold),
                            ),
                            if (rightDevice != null)
                              Text(
                                rightDevice!.platformName,
                                style: const TextStyle(fontSize: 10),
                              ),
                          ],
                        ),
                      ],
                    ),

                    // Show "Continue to Test" button when both connected
                    if (bothConnected) ...[
                      const SizedBox(height: 16),
                      const Divider(),
                      const SizedBox(height: 8),
                      const Text(
                        '✓ Both devices connected!',
                        style: TextStyle(
                          color: Colors.green,
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                      const SizedBox(height: 12),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          onPressed: () {
                            // Navigate to DataCollectionPage
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
                          icon: const Icon(Icons.play_arrow),
                          label: const Text('Continue to Test'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.green,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 16),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),

            const SizedBox(height: 12),

            // Device List
            Expanded(
              child: scanResults.isEmpty
                  ? const Center(
                      child: Text(
                        'No devices found.\nTap Scan to search.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.grey),
                      ),
                    )
                  : ListView.builder(
                      itemCount: scanResults.length,
                      itemBuilder: (context, index) {
                        final r = scanResults[index];
                        final name = r.device.platformName.isNotEmpty
                            ? r.device.platformName
                            : 'Unknown Device';

                        return Card(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  name,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  r.device.remoteId.str,
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: Colors.grey,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Row(
                                  children: [
                                    Expanded(
                                      child: ElevatedButton(
                                        onPressed: leftDevice == null
                                            ? () => connect(r.device, true)
                                            : null,
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor: leftDevice == null
                                              ? Colors.teal
                                              : Colors.grey,
                                        ),
                                        child: Text(
                                          leftDevice == r.device
                                              ? 'LEFT ✓'
                                              : 'Connect LEFT',
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: ElevatedButton(
                                        onPressed: rightDevice == null
                                            ? () => connect(r.device, false)
                                            : null,
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor: rightDevice == null
                                              ? Colors.teal
                                              : Colors.grey,
                                        ),
                                        child: Text(
                                          rightDevice == r.device
                                              ? 'RIGHT ✓'
                                              : 'Connect RIGHT',
                                        ),
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
          ],
        ),
      ),
    );
  }
}
