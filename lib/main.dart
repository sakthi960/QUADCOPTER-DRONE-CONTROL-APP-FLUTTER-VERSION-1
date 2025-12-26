// ignore_for_file: deprecated_member_use, use_build_context_synchronously

import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:math' as math;
import 'dart:io';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  runApp(const DroneControlApp());
}

class DroneControlApp extends StatelessWidget {
  const DroneControlApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'UDP Drone Control',
      theme: ThemeData(
        brightness: Brightness.dark,
        primaryColor: const Color(0xFF4A5FFF),
        scaffoldBackgroundColor: const Color(0xFF1A1D2E),
        cardColor: const Color(0xFF262B3F),
      ),
      home: const DroneHomePage(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class DroneHomePage extends StatefulWidget {
  const DroneHomePage({super.key});

  @override
  State<DroneHomePage> createState() => _DroneHomePageState();
}

class _DroneHomePageState extends State<DroneHomePage> {
  // Connection
  bool isConnected = false;
  String droneIP = "192.168.4.1";
  int udpPort = 8888;
  RawDatagramSocket? socket;
  
  Timer? connectionTimeoutTimer;
  bool isConnecting = false;
  Timer? udpSendTimer;
  Timer? failsafeTimer;
  
  // Constants
  static const double EXPO = 0.3;
  static const double THROTTLE_EXPO = 0.0;
  static const int MIN_THROTTLE = 1000;
  static const int MAX_THROTTLE = 2000;
  static const int CENTER_VALUE = 1500;
  static const int FAILSAFE_TIMEOUT_MS = 1000; // 1 second without packets
  static const double THROTTLE_RAMP_RATE = 50.0; // PWM units per update
  static const int MAX_THROTTLE_SPIKE = 100; // Max allowed throttle change per cycle

  // Control Values
  int throttle = 1000;
  int targetThrottle = 1000; // For ramping
  int roll = 1500;
  int pitch = 1500;
  int yaw = 1500;
  int arm = 0;
  bool ledOn = false;

  double maxThrottlePercent = 100.0;

  // Joystick positions
  double leftX = 0.0;
  double leftY = 0.0;
  double rightX = 0.0;
  double rightY = 0.0;

  // Smoothing
  double lastLeftX = 0.0, lastLeftY = 0.0;
  double lastRightX = 0.0, lastRightY = 0.0;

  // Telemetry
  String flightMode = "DISCONNECTED";
  double altitude = 0.0;
  double batteryVoltage = 11.1;
  double batteryPercent = 0.0;
  int packetsPerSecond = 0;
  int _packetCounter = 0;
  Timer? _ppsTimer;
  DateTime? lastPacketTime;
  
  // Packet sequence tracking
  int txSequenceNumber = 0;
  int rxSequenceNumber = 0;
  int packetLossCount = 0;
  
  // Motor values
  int m1 = 1000;
  int m2 = 1000;
  int m3 = 1000;
  int m4 = 1000;

  // Safety flags
  bool failsafeActive = false;
  bool lowBatteryWarning = false;
  String safetyStatus = "SAFE";
  
  // Scroll lock
  bool scrollLocked = false;
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    _loadSavedSettings();
    _startPPSCounter();
    _startFailsafeMonitor();
  }

  @override
  void dispose() {
    udpSendTimer?.cancel();
    connectionTimeoutTimer?.cancel();
    failsafeTimer?.cancel();
    _ppsTimer?.cancel();
    _scrollController.dispose();
    socket?.close();
    super.dispose();
  }

  Future<void> _loadSavedSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedIP = prefs.getString('drone_ip');
      final savedThrottle = prefs.getDouble('max_throttle');
      
      if (savedIP != null && savedIP.isNotEmpty) {
        setState(() => droneIP = savedIP);
      }
      
      if (savedThrottle != null) {
        setState(() => maxThrottlePercent = savedThrottle);
      }
    } catch (e) {
      debugPrint('Error loading settings: $e');
    }
  }

  Future<void> _saveIP(String ip) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('drone_ip', ip);
    } catch (e) {
      debugPrint('Error saving IP: $e');
    }
  }

  Future<void> _saveThrottleLimit(double limit) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble('max_throttle', limit);
    } catch (e) {
      debugPrint('Error saving throttle limit: $e');
    }
  }

  void _startPPSCounter() {
    _ppsTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      setState(() {
        packetsPerSecond = _packetCounter;
        _packetCounter = 0;
      });
    });
  }

  void _startFailsafeMonitor() {
    failsafeTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      _checkFailsafe();
      _checkBattery();
      _applyThrottleRamping();
    });
  }

  void _checkFailsafe() {
    if (!isConnected || lastPacketTime == null) return;

    final timeSinceLastPacket = DateTime.now().difference(lastPacketTime!).inMilliseconds;
    
    if (timeSinceLastPacket > FAILSAFE_TIMEOUT_MS && !failsafeActive) {
      setState(() {
        failsafeActive = true;
        safetyStatus = "FAILSAFE";
      });
      _activateFailsafe();
    }
  }

  void _checkBattery() {
    if (batteryVoltage < 10.5 && !lowBatteryWarning) {
      setState(() {
        lowBatteryWarning = true;
        safetyStatus = "LOW BATTERY";
      });
      _showError('⚠ LOW BATTERY! Land immediately!');
    }
  }

  void _activateFailsafe() {
    debugPrint('FAILSAFE ACTIVATED - Connection lost');
    emergencyStop();
    _showError('⚠ FAILSAFE: Connection lost! Motors disarmed.');
  }

  void _applyThrottleRamping() {
    if (targetThrottle != throttle) {
      int difference = targetThrottle - throttle;
      int step = (difference.abs() > THROTTLE_RAMP_RATE) 
          ? (difference > 0 ? THROTTLE_RAMP_RATE.toInt() : -THROTTLE_RAMP_RATE.toInt())
          : difference;
      
      setState(() {
        throttle = (throttle + step).clamp(MIN_THROTTLE, MAX_THROTTLE);
      });
    }
  }

  bool _validateESCSignal(int value) {
    return value >= MIN_THROTTLE && value <= MAX_THROTTLE;
  }

  int _applyThrottleCurve(double normalizedInput) {
    // Non-linear thrust curve for better low-speed control
    // 0.0 to 1.0 input -> smoother response at low end
    double curved = math.pow(normalizedInput, 1.5).toDouble();
    double throttlePercent = (curved * (maxThrottlePercent / 100.0)).clamp(0.0, 1.0);
    return (MIN_THROTTLE + throttlePercent * (MAX_THROTTLE - MIN_THROTTLE))
        .toInt()
        .clamp(MIN_THROTTLE, MAX_THROTTLE);
  }

  Future<void> initUdp() async {
    if (isConnecting) return;
    
    setState(() {
      isConnecting = true;
      flightMode = "CONNECTING...";
      txSequenceNumber = 0;
      rxSequenceNumber = 0;
      packetLossCount = 0;
    });

    try {
      socket?.close();
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      
      bool connectionVerified = false;
      
      socket?.listen((event) {
        if (event == RawSocketEvent.read) {
          Datagram? dg = socket?.receive();
          if (dg != null) {
            connectionVerified = true;
            connectionTimeoutTimer?.cancel();
            
            // Update last packet time for failsafe
            lastPacketTime = DateTime.now();
            
            if (failsafeActive) {
              setState(() {
                failsafeActive = false;
                safetyStatus = "SAFE";
              });
            }
            
            if (!isConnected) {
              setState(() {
                isConnected = true;
                isConnecting = false;
                flightMode = arm == 1 ? "ARMED" : "DISARMED";
              });
              
              _startContinuousSend();
              
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('✓ UDP Connected to $droneIP:$udpPort'),
                  backgroundColor: Colors.green,
                  duration: const Duration(seconds: 2),
                ),
              );
            }
            
            _processTelemetry(utf8.decode(dg.data));
          }
        }
      });
      
      _sendHandshake();
      
      connectionTimeoutTimer = Timer(const Duration(seconds: 5), () {
        if (!connectionVerified) {
          socket?.close();
          socket = null;
          setState(() {
            isConnected = false;
            isConnecting = false;
            flightMode = "CONNECTION FAILED";
          });
          
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('✗ Connection Failed: ESP32 not responding'),
              backgroundColor: Colors.red,
              duration: Duration(seconds: 3),
            ),
          );
        }
      });
      
    } catch (e) {
      setState(() {
        isConnected = false;
        isConnecting = false;
        flightMode = "ERROR";
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('✗ UDP Init Failed: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  void _sendHandshake() {
    if (socket == null) return;
    try {
      String handshake = "HELLO\n";
      socket?.send(utf8.encode(handshake), InternetAddress(droneIP), udpPort);
    } catch (e) {
      debugPrint('Handshake error: $e');
    }
  }

  double applyExpo(double value, double expo) {
    double sign = value.sign;
    double absValue = value.abs();
    return sign * (expo * absValue * absValue * absValue + (1 - expo) * absValue);
  }

  double smoothValue(double target, double last, [double step = 0.02]) {
    if (target > last) {
      last += step;
    } else if (target < last) {
      last -= step;
    }
    return last.clamp(-1.0, 1.0);
  }

  int mapRC(double value) {
    return (CENTER_VALUE + value * 500).toInt().clamp(1000, 2000);
  }

  void updateLeftJoystick(double x, double y) {
    setState(() {
      leftX = smoothValue(applyExpo(x, EXPO), lastLeftX);
      leftY = smoothValue(applyExpo(-y, THROTTLE_EXPO), lastLeftY);
      lastLeftX = leftX;
      lastLeftY = leftY;
    });
  }

  void updateRightJoystick(double x, double y) {
    setState(() {
      rightX = smoothValue(applyExpo(x, EXPO), lastRightX);
      rightY = smoothValue(applyExpo(-y, EXPO), lastRightY);
      lastRightX = rightX;
      lastRightY = rightY;
    });
  }

  void calculateMotorValues() {
    // Safety check: disarmed or throttle at minimum
    if (arm == 0 || throttle <= MIN_THROTTLE) {
      m1 = m2 = m3 = m4 = MIN_THROTTLE;
      return;
    }

    int thrBase = throttle;
    int rollOffset = roll - CENTER_VALUE;
    int pitchOffset = pitch - CENTER_VALUE;
    int yawOffset = yaw - CENTER_VALUE;

    // Calculate motor values with mixing
    m1 = (thrBase - rollOffset - pitchOffset + yawOffset).clamp(MIN_THROTTLE, MAX_THROTTLE);
    m2 = (thrBase + rollOffset - pitchOffset - yawOffset).clamp(MIN_THROTTLE, MAX_THROTTLE);
    m3 = (thrBase + rollOffset + pitchOffset + yawOffset).clamp(MIN_THROTTLE, MAX_THROTTLE);
    m4 = (thrBase - rollOffset + pitchOffset - yawOffset).clamp(MIN_THROTTLE, MAX_THROTTLE);

    // Ensure minimum spin speed when armed
    if (thrBase > MIN_THROTTLE) {
      m1 = math.max(m1, MIN_THROTTLE + 50);
      m2 = math.max(m2, MIN_THROTTLE + 50);
      m3 = math.max(m3, MIN_THROTTLE + 50);
      m4 = math.max(m4, MIN_THROTTLE + 50);
    }

    // ESC signal validation
    if (!_validateESCSignal(m1) || !_validateESCSignal(m2) || 
        !_validateESCSignal(m3) || !_validateESCSignal(m4)) {
      debugPrint('WARNING: Motor value out of ESC range!');
      m1 = m1.clamp(MIN_THROTTLE, MAX_THROTTLE);
      m2 = m2.clamp(MIN_THROTTLE, MAX_THROTTLE);
      m3 = m3.clamp(MIN_THROTTLE, MAX_THROTTLE);
      m4 = m4.clamp(MIN_THROTTLE, MAX_THROTTLE);
    }
  }

  String buildPacket() {
    // Apply thrust curve to throttle input
    double normalizedThrottle = (leftY + 1) / 2.0;
    int newTargetThrottle = _applyThrottleCurve(normalizedThrottle);
    
    // Anti-spike protection
    int throttleDiff = (newTargetThrottle - targetThrottle).abs();
    if (throttleDiff > MAX_THROTTLE_SPIKE) {
      // Limit the change rate
      if (newTargetThrottle > targetThrottle) {
        targetThrottle += MAX_THROTTLE_SPIKE;
      } else {
        targetThrottle -= MAX_THROTTLE_SPIKE;
      }
    } else {
      targetThrottle = newTargetThrottle;
    }
    
    yaw = mapRC(leftX);
    roll = mapRC(rightX);
    pitch = mapRC(rightY);

    // Auto-stop if throttle at minimum
    if (targetThrottle <= MIN_THROTTLE && arm == 1) {
      // Don't auto-disarm, just keep motors at idle
      throttle = MIN_THROTTLE;
    }

    calculateMotorValues();

    // Include sequence number for packet tracking
    txSequenceNumber++;
    return "$throttle,$roll,$pitch,$yaw,$arm,${ledOn ? 1 : 0},$txSequenceNumber,${batteryVoltage.toStringAsFixed(1)}\n";
  }

  void sendPacket() {
    if (socket == null || !isConnected || failsafeActive) return;
    
    try {
      String packet = buildPacket();
      socket?.send(utf8.encode(packet), InternetAddress(droneIP), udpPort);
      _packetCounter++;
      lastPacketTime = DateTime.now();
    } catch (e) {
      debugPrint('Send error: $e');
    }
  }

  void _startContinuousSend() {
    udpSendTimer?.cancel();
    udpSendTimer = Timer.periodic(
      const Duration(milliseconds: 20), // 50Hz
      (_) => sendPacket(),
    );
  }

  void armMotors() {
    if (!isConnected) {
      _showError('Not connected to drone');
      return;
    }
    
    if (failsafeActive) {
      _showError('Cannot arm: Failsafe active');
      return;
    }
    
    if (lowBatteryWarning) {
      _showError('Cannot arm: Battery too low');
      return;
    }
    
    // Safety check: throttle must be at minimum
    if (leftY > -0.9) {
      _showError('Cannot arm: Lower throttle to minimum');
      return;
    }
    
    setState(() {
      arm = 1;
      flightMode = "ARMED";
      safetyStatus = "ARMED";
    });
    _showSuccess('✓ Motors ARMED - Fly safe!');
  }

  void disarmMotors() {
    setState(() {
      arm = 0;
      throttle = MIN_THROTTLE;
      targetThrottle = MIN_THROTTLE;
      leftY = -1.0;
      lastLeftY = -1.0;
      flightMode = "DISARMED";
      safetyStatus = "SAFE";
    });
    _showSuccess('✓ Motors DISARMED');
  }

  void toggleLed() {
    setState(() => ledOn = !ledOn);
    sendPacket();
    _showSuccess('✓ NEOPIXEL ${ledOn ? 'ON' : 'OFF'}');
  }

  void emergencyStop() {
    setState(() {
      throttle = MIN_THROTTLE;
      targetThrottle = MIN_THROTTLE;
      roll = pitch = yaw = CENTER_VALUE;
      arm = 0;
      leftX = rightX = rightY = 0;
      leftY = -1.0;
      lastLeftX = lastRightX = lastRightY = 0;
      lastLeftY = -1.0;
      flightMode = "EMERGENCY";
      safetyStatus = "EMERGENCY";
    });
    sendPacket();
    _showError('⚠ EMERGENCY STOP ACTIVATED');
  }

  void disconnect() {
    udpSendTimer?.cancel();
    connectionTimeoutTimer?.cancel();
    socket?.close();
    socket = null;

    setState(() {
      isConnected = false;
      isConnecting = false;
      arm = 0;
      throttle = MIN_THROTTLE;
      targetThrottle = MIN_THROTTLE;
      roll = pitch = yaw = CENTER_VALUE;
      leftX = rightX = rightY = 0;
      leftY = -1.0;
      lastLeftX = lastRightX = lastRightY = 0;
      lastLeftY = -1.0;
      flightMode = "DISCONNECTED";
      packetsPerSecond = 0;
      failsafeActive = false;
      lowBatteryWarning = false;
      safetyStatus = "SAFE";
      lastPacketTime = null;
    });

    _showSuccess('✓ Disconnected from drone');
  }

  void _processTelemetry(String data) {
    try {
      Map<String, String> telemetry = {};
      for (var pair in data.split(',')) {
        var kv = pair.split(':');
        if (kv.length == 2) {
          telemetry[kv[0]] = kv[1];
        }
      }
      
      setState(() {
        altitude = double.tryParse(telemetry['ALT'] ?? '0') ?? altitude;
        batteryVoltage = double.tryParse(telemetry['BAT'] ?? '11.1') ?? batteryVoltage;
        batteryPercent = ((batteryVoltage - 10.2) / (12.6 - 10.2) * 100).clamp(0, 100);
        
        if (telemetry['M1'] != null) m1 = int.tryParse(telemetry['M1']!) ?? m1;
        if (telemetry['M2'] != null) m2 = int.tryParse(telemetry['M2']!) ?? m2;
        if (telemetry['M3'] != null) m3 = int.tryParse(telemetry['M3']!) ?? m3;
        if (telemetry['M4'] != null) m4 = int.tryParse(telemetry['M4']!) ?? m4;
        
        if (telemetry['MODE'] != null && telemetry['MODE']!.isNotEmpty) {
          flightMode = telemetry['MODE']!;
        }
        
        // Track packet sequence for loss detection
        if (telemetry['SEQ'] != null) {
          int receivedSeq = int.tryParse(telemetry['SEQ']!) ?? 0;
          if (receivedSeq > rxSequenceNumber + 1) {
            packetLossCount += (receivedSeq - rxSequenceNumber - 1);
          }
          rxSequenceNumber = receivedSeq;
        }
      });
    } catch (e) {
      debugPrint('Telemetry parse error: $e');
    }
  }

  void _showError(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: Colors.red, duration: const Duration(seconds: 3)),
    );
  }

  void _showSuccess(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: Colors.green, duration: const Duration(seconds: 2)),
    );
  }

  void _handleIPChange(String newIP) {
    final ipRegex = RegExp(r'^(\d{1,3}\.){3}\d{1,3}$');
    if (!ipRegex.hasMatch(newIP)) {
      _showError('⚠ Invalid IP format');
      return;
    }

    if (isConnected) disconnect();

    setState(() => droneIP = newIP);
    _saveIP(newIP);
    _showSuccess('✓ IP updated to $newIP');
  }

  Widget buildJoystick({
    required Function(double, double) onUpdate,
    required double size,
    required String label,
  }) {
    return Column(
      children: [
        Text(
          label,
          style: const TextStyle(
            color: Colors.white70,
            fontSize: 12,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 8),
        GestureDetector(
          onPanUpdate: (details) {
            final x = ((details.localPosition.dx - size / 2) / (size / 2)).clamp(-1.0, 1.0);
            final y = ((details.localPosition.dy - size / 2) / (size / 2)).clamp(-1.0, 1.0);
            onUpdate(x, y);
          },
          onPanEnd: (_) => onUpdate(0, 0),
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                colors: [
                  const Color(0xFF4A5FFF).withOpacity(0.3),
                  const Color(0xFF9C27B0).withOpacity(0.3),
                ],
              ),
              border: Border.all(
                color: const Color(0xFF4A5FFF).withOpacity(0.5),
                width: 2,
              ),
            ),
            child: Center(
              child: Container(
                width: size / 3,
                height: size / 3,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      const Color(0xFF4A5FFF),
                      const Color(0xFF4A5FFF).withOpacity(0.5),
                    ],
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF4A5FFF).withOpacity(0.5),
                      blurRadius: 15,
                      spreadRadius: 3,
                    ),
                  ],
                ),
                child: const Icon(
                  Icons.center_focus_strong,
                  size: 24,
                  color: Colors.white,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      drawer: _buildDrawer(),
      body: SafeArea(
        child: Column(
          children: [
            _buildAppBar(),
            if (failsafeActive || lowBatteryWarning) _buildSafetyBanner(),
            Expanded(
              child: ListView(
                controller: _scrollController,
                physics: scrollLocked 
                    ? const NeverScrollableScrollPhysics() 
                    : const AlwaysScrollableScrollPhysics(),
                children: [
                  _buildTelemetryBar(),
                  _buildFlightControls(),
                  _buildJoystickArea(),
                  _buildMotorDisplay(),
                  _buildDebugInfo(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSafetyBanner() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      color: failsafeActive ? Colors.red : Colors.orange,
      child: Row(
        children: [
          const Icon(Icons.warning, color: Colors.white),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              failsafeActive 
                  ? '⚠ FAILSAFE ACTIVE - CONNECTION LOST'
                  : '⚠ LOW BATTERY - LAND IMMEDIATELY',
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 14,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAppBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF262B3F),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.3),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          Builder(
            builder: (context) => IconButton(
              icon: const Icon(Icons.menu),
              onPressed: () => Scaffold.of(context).openDrawer(),
            ),
          ),
          const Icon(Icons.flight, color: Color(0xFF4A5FFF)),
          const SizedBox(width: 12),
          const Text(
            'UDP Drone Control',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: Color(0xFF4A5FFF),
            ),
          ),
          const Spacer(),
          // Scroll Lock Button
          Container(
            margin: const EdgeInsets.only(right: 12),
            child: ElevatedButton.icon(
              onPressed: () {
                setState(() => scrollLocked = !scrollLocked);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(scrollLocked ? '🔒 Scroll Locked' : '🔓 Scroll Unlocked'),
                    duration: const Duration(seconds: 1),
                    backgroundColor: scrollLocked ? Colors.orange : Colors.green,
                  ),
                );
              },
              icon: Icon(
                scrollLocked ? Icons.lock : Icons.lock_open,
                size: 16,
              ),
              label: Text(
                scrollLocked ? 'LOCKED' : 'UNLOCKED',
                style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: scrollLocked 
                    ? Colors.orange.withOpacity(0.2) 
                    : Colors.green.withOpacity(0.2),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(
                    color: scrollLocked ? Colors.orange : Colors.green,
                    width: 2,
                  ),
                ),
              ),
            ),
          ),
          Text(
            '$droneIP:$udpPort',
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
          const SizedBox(width: 12),
          _buildConnectionStatus(),
        ],
      ),
    );
  }

  Widget _buildConnectionStatus() {
    Color statusColor = isConnecting 
        ? Colors.orange 
        : isConnected 
            ? Colors.green 
            : Colors.red;
    
    String statusText = isConnecting 
        ? 'Connecting...' 
        : isConnected 
            ? 'UDP Active' 
            : 'Disconnected';
    
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: statusColor.withOpacity(0.2),
        border: Border.all(color: statusColor, width: 2),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        children: [
          Icon(Icons.circle, size: 12, color: statusColor),
          const SizedBox(width: 8),
          Text(
            statusText,
            style: TextStyle(
              color: statusColor,
              fontWeight: FontWeight.bold,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTelemetryBar() {
    Color modeColor = flightMode == "DISARMED"
        ? Colors.blue
        : flightMode == "ARMED"
            ? Colors.yellow
            : flightMode == "FLYING"
                ? Colors.green
                : flightMode == "CONNECTING..."
                    ? Colors.orange
                    : Colors.red;

    return Container(
      margin: const EdgeInsets.all(16),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            const Color(0xFF4A5FFF).withOpacity(0.3),
            const Color(0xFF9C27B0).withOpacity(0.3),
          ],
        ),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _buildTelemetryItem(Icons.height, '${altitude.toStringAsFixed(1)}m', 'ALT'),
              _buildTelemetryItem(
                Icons.battery_charging_full, 
                '${batteryPercent.toStringAsFixed(0)}%', 
                'BAT',
                color: batteryPercent < 20 ? Colors.red : null
              ),
              _buildTelemetryItem(arm == 1 ? Icons.lock_open : Icons.lock, flightMode, 'MODE', color: modeColor),
              _buildTelemetryItem(Icons.signal_cellular_alt, '$packetsPerSecond Hz', 'PPS'),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _buildTelemetryItem(Icons.shield, safetyStatus, 'SAFETY', 
                color: safetyStatus == "SAFE" ? Colors.green : Colors.red),
              _buildTelemetryItem(Icons.error_outline, '$packetLossCount', 'LOSS'),
              _buildTelemetryItem(Icons.thermostat, '${targetThrottle}µs', 'THR'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildTelemetryItem(IconData icon, String value, String label, {Color? color}) {
    return Column(
      children: [
        Icon(icon, color: color ?? Colors.white, size: 20),
        const SizedBox(height: 4),
        Text(label, style: TextStyle(color: Colors.white.withOpacity(0.7), fontSize: 9)),
        Text(
          value,
          style: TextStyle(
            color: color ?? Colors.white,
            fontSize: 12,
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    );
  }

  Widget _buildMotorDisplay() {
    return Container(
      margin: const EdgeInsets.all(16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            Colors.purple.withOpacity(0.3),
            Colors.blue.withOpacity(0.3),
          ],
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: arm == 1 ? Colors.green : Colors.red, width: 2),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                '🚁 Motor Values (PWM)',
                style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: arm == 1 ? Colors.green.withOpacity(0.2) : Colors.red.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: arm == 1 ? Colors.green : Colors.red),
                ),
                child: Text(
                  arm == 1 ? '✓ ARMED' : '✗ DISARMED',
                  style: TextStyle(
                    color: arm == 1 ? Colors.green : Colors.red,
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              Column(
                children: [
                  _buildMotorCard('M1', m1, 'FL', Colors.red),
                  const SizedBox(height: 16),
                  _buildMotorCard('M4', m4, 'RL', Colors.yellow),
                ],
              ),
              Container(
                width: 80,
                height: 180,
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.white24, width: 2),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.flight, color: arm == 1 ? Colors.green : Colors.white24, size: 40),
                    const SizedBox(height: 8),
                    Text(
                      'QUAD',
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.5),
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
              Column(
                children: [
                  _buildMotorCard('M2', m2, 'FR', Colors.blue),
                  const SizedBox(height: 16),
                  _buildMotorCard('M3', m3, 'RR', Colors.green),
                ],
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _buildMotorLegend(Colors.red, 'Front-Left (CW)'),
              _buildMotorLegend(Colors.blue, 'Front-Right (CCW)'),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _buildMotorLegend(Colors.yellow, 'Rear-Left (CCW)'),
              _buildMotorLegend(Colors.green, 'Rear-Right (CW)'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildMotorCard(String label, int value, String position, Color color) {
    double percentage = ((value - 1000) / 10.0).clamp(0, 100);
    bool isSpinning = arm == 1 && value > 1050;
    
    return Container(
      width: 90,
      height: 80,
      decoration: BoxDecoration(
        color: const Color(0xFF1A1D2E),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: isSpinning ? color : Colors.white24, width: 2),
        boxShadow: isSpinning
            ? [BoxShadow(color: color.withOpacity(0.5), blurRadius: 10, spreadRadius: 2)]
            : [],
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(label, style: TextStyle(color: isSpinning ? color : Colors.white70, fontSize: 14, fontWeight: FontWeight.bold)),
              const SizedBox(width: 4),
              Text(position, style: TextStyle(color: Colors.white.withOpacity(0.5), fontSize: 10)),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            value.toString(),
            style: TextStyle(
              color: isSpinning ? color : Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.bold,
              fontFamily: 'monospace',
            ),
          ),
          const SizedBox(height: 2),
          Text('${percentage.toInt()}%', style: TextStyle(color: Colors.white.withOpacity(0.5), fontSize: 11)),
        ],
      ),
    );
  }

  Widget _buildMotorLegend(Color color, String label) {
    return Row(
      children: [
        Container(width: 12, height: 12, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 6),
        Text(label, style: TextStyle(color: Colors.white.withOpacity(0.7), fontSize: 10)),
      ],
    );
  }

  Widget _buildJoystickArea() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _buildCompactButton(
                icon: Icons.lock_open,
                label: 'ARM',
                color: Colors.green,
                enabled: isConnected && arm == 0 && !failsafeActive && !lowBatteryWarning,
                onPressed: armMotors,
              ),
              const SizedBox(height: 12),
              _buildCompactButton(
                icon: Icons.lock,
                label: 'DISARM',
                color: Colors.orange,
                enabled: isConnected && arm == 1,
                onPressed: disarmMotors,
              ),
            ],
          ),
          const SizedBox(width: 12),
          buildJoystick(onUpdate: updateLeftJoystick, size: 200, label: 'THROTTLE / YAW'),
          const SizedBox(width: 16),
          buildJoystick(onUpdate: updateRightJoystick, size: 200, label: 'PITCH / ROLL'),
          const SizedBox(width: 12),
          Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _buildCompactButton(
                icon: Icons.warning,
                label: 'EMERGENCY',
                color: Colors.red,
                enabled: isConnected,
                onPressed: emergencyStop,
              ),
              const SizedBox(height: 12),
              _buildCompactButton(
                icon: ledOn ? Icons.lightbulb : Icons.lightbulb_outline,
                label: ledOn ? 'LED ON' : 'LED OFF',
                color: ledOn ? Colors.yellow : Colors.grey,
                enabled: isConnected,
                onPressed: toggleLed,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildCompactButton({
    required IconData icon,
    required String label,
    required Color color,
    required bool enabled,
    required VoidCallback onPressed,
  }) {
    return SizedBox(
      width: 80,
      height: 80,
      child: ElevatedButton(
        onPressed: enabled ? onPressed : null,
        style: ElevatedButton.styleFrom(
          backgroundColor: color.withOpacity(0.2),
          padding: const EdgeInsets.all(8),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: enabled ? color : Colors.grey, width: 2),
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: enabled ? color : Colors.grey, size: 28),
            const SizedBox(height: 4),
            Text(
              label,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: enabled ? color : Colors.grey,
                fontSize: 10,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFlightControls() {
    return Container(
      margin: const EdgeInsets.all(16),
      child: Row(
        children: [
          Expanded(
            child: ElevatedButton.icon(
              onPressed: isConnected || isConnecting ? null : initUdp,
              icon: const Icon(Icons.wifi),
              label: Text(isConnecting ? 'Connecting...' : isConnected ? 'UDP Connected' : 'Connect UDP'),
              style: ElevatedButton.styleFrom(
                backgroundColor: isConnecting
                    ? Colors.orange.withOpacity(0.2)
                    : isConnected
                        ? Colors.green.withOpacity(0.2)
                        : const Color(0xFF4A5FFF).withOpacity(0.3),
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(
                    color: isConnecting ? Colors.orange : isConnected ? Colors.green : const Color(0xFF4A5FFF),
                    width: 2,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: ElevatedButton.icon(
              onPressed: isConnected ? disconnect : null,
              icon: const Icon(Icons.close),
              label: const Text('Disconnect'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.orange.withOpacity(0.2),
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: const BorderSide(color: Colors.orange, width: 2),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDebugInfo() {
    return Container(
      margin: const EdgeInsets.all(16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF262B3F),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Control Values & Safety Info',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
          ),
          const SizedBox(height: 12),
          _buildDebugRow('Throttle', throttle, '${((throttle - 1000) / 10).toInt()}%'),
          _buildDebugRow('Target Thr', targetThrottle, 'Ramping'),
          _buildDebugRow('Roll', roll, '${roll - 1500 > 0 ? '+' : ''}${roll - 1500}'),
          _buildDebugRow('Pitch', pitch, '${pitch - 1500 > 0 ? '+' : ''}${pitch - 1500}'),
          _buildDebugRow('Yaw', yaw, '${yaw - 1500 > 0 ? '+' : ''}${yaw - 1500}'),
          _buildDebugRow('Arm', arm, arm == 1 ? 'ARMED' : 'DISARMED'),
          const Divider(color: Colors.white24, height: 24),
          const Text(
            'Safety Status',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.white70),
          ),
          const SizedBox(height: 8),
          _buildSafetyRow('Failsafe', failsafeActive ? 'ACTIVE' : 'OK', failsafeActive),
          _buildSafetyRow('Battery', lowBatteryWarning ? 'LOW' : 'OK', lowBatteryWarning),
          _buildSafetyRow('Connection', isConnected ? 'ACTIVE' : 'LOST', !isConnected),
          const Divider(color: Colors.white24, height: 24),
          const Text(
            'Motor Outputs (PWM)',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.white70),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _buildMiniMotorInfo('M1', m1),
              _buildMiniMotorInfo('M2', m2),
              _buildMiniMotorInfo('M3', m3),
              _buildMiniMotorInfo('M4', m4),
            ],
          ),
          const Divider(color: Colors.white24, height: 24),
          Text(
            'TX: $throttle,$roll,$pitch,$yaw,$arm,${ledOn ? 1 : 0},$txSequenceNumber,${batteryVoltage.toStringAsFixed(1)}',
            style: const TextStyle(color: Colors.white70, fontSize: 10, fontFamily: 'monospace'),
          ),
          const SizedBox(height: 4),
          Text(
            'Joystick: L(${leftX.toStringAsFixed(2)},${leftY.toStringAsFixed(2)}) R(${rightX.toStringAsFixed(2)},${rightY.toStringAsFixed(2)})',
            style: const TextStyle(color: Colors.white70, fontSize: 10, fontFamily: 'monospace'),
          ),
          const SizedBox(height: 4),
          Text(
            'Packets Lost: $packetLossCount | TX Seq: $txSequenceNumber | RX Seq: $rxSequenceNumber',
            style: const TextStyle(color: Colors.white70, fontSize: 10, fontFamily: 'monospace'),
          ),
        ],
      ),
    );
  }

  Widget _buildSafetyRow(String label, String status, bool isWarning) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(color: Colors.white70, fontSize: 13)),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: isWarning ? Colors.red.withOpacity(0.2) : Colors.green.withOpacity(0.2),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: isWarning ? Colors.red : Colors.green),
            ),
            child: Text(
              status,
              style: TextStyle(
                color: isWarning ? Colors.red : Colors.green,
                fontSize: 11,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMiniMotorInfo(String label, int value) {
    return Column(
      children: [
        Text(label, style: TextStyle(color: Colors.white.withOpacity(0.5), fontSize: 11)),
        Text(
          value.toString(),
          style: const TextStyle(
            color: Color(0xFF4A5FFF),
            fontSize: 14,
            fontWeight: FontWeight.bold,
            fontFamily: 'monospace',
          ),
        ),
      ],
    );
  }

  Widget _buildDebugRow(String label, int value, String extra) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(color: Colors.white70, fontSize: 14)),
          Row(
            children: [
              Text(
                value.toString(),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  fontFamily: 'monospace',
                ),
              ),
              const SizedBox(width: 8),
              Text(
                extra,
                style: TextStyle(
                  color: Colors.white.withOpacity(0.5),
                  fontSize: 12,
                  fontFamily: 'monospace',
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildDrawer() {
    return Drawer(
      backgroundColor: const Color(0xFF1A1D2E),
      child: ListView(
        padding: EdgeInsets.zero,
        children: [
          DrawerHeader(
            decoration: const BoxDecoration(
              gradient: LinearGradient(colors: [Color(0xFF4A5FFF), Color(0xFF9C27B0)]),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                const Icon(Icons.flight, size: 48, color: Colors.white),
                const SizedBox(height: 8),
                const Text(
                  'UDP Drone Control',
                  style: TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold),
                ),
                Text(
                  'Version 5.0.0 - Enhanced Safety',
                  style: TextStyle(color: Colors.white.withOpacity(0.7), fontSize: 12),
                ),
              ],
            ),
          ),
          ListTile(
            leading: const Icon(Icons.settings, color: Color(0xFF4A5FFF)),
            title: const Text('Settings', style: TextStyle(color: Colors.white)),
            onTap: () {
              Navigator.pop(context);
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => SettingsPage(
                    currentIP: droneIP,
                    currentPort: udpPort,
                    isConnected: isConnected,
                    maxThrottle: maxThrottlePercent,
                    onIPChanged: _handleIPChange,
                    onPortChanged: (port) => setState(() => udpPort = port),
                    onThrottleChanged: (value) {
                      setState(() => maxThrottlePercent = value);
                      _saveThrottleLimit(value);
                    },
                  ),
                ),
              );
            },
          ),
          ListTile(
            leading: const Icon(Icons.info_outline, color: Color(0xFF4A5FFF)),
            title: const Text('About', style: TextStyle(color: Colors.white)),
            onTap: () {
              Navigator.pop(context);
              showAboutDialog(
                context: context,
                applicationName: 'UDP Drone Control',
                applicationVersion: '5.0.0 - Enhanced Safety',
                applicationIcon: const Icon(Icons.flight, size: 48, color: Color(0xFF4A5FFF)),
                children: const [
                  Text(
                    'Professional-grade UDP drone control with advanced safety features.\n\n'
                    'NEW Safety Features:\n'
                    '• Automatic failsafe (1s timeout)\n'
                    '• Throttle ramping & anti-spike\n'
                    '• ESC signal validation (1000-2000µs)\n'
                    '• Low battery auto-warning (<10.5V)\n'
                    '• Packet loss tracking\n'
                    '• Non-linear thrust curve\n'
                    '• Auto-stop on throttle=0\n\n'
                    'Core Features:\n'
                    '• 50Hz packet rate (20ms)\n'
                    '• Mode-2 joystick layout\n'
                    '• Adjustable throttle limiter\n'
                    '• Expo curves for smooth control\n'
                    '• ARM/DISARM with safety checks\n'
                    '• Emergency stop\n'
                    '• Real-time telemetry\n\n'
                    'Control Layout:\n'
                    '• Left: Throttle (Y) + Yaw (X)\n'
                    '• Right: Pitch (Y) + Roll (X)',
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

// Settings Page
class SettingsPage extends StatefulWidget {
  final String currentIP;
  final int currentPort;
  final bool isConnected;
  final double maxThrottle;
  final Function(String) onIPChanged;
  final Function(int) onPortChanged;
  final Function(double) onThrottleChanged;

  const SettingsPage({
    super.key,
    required this.currentIP,
    required this.currentPort,
    required this.isConnected,
    required this.maxThrottle,
    required this.onIPChanged,
    required this.onPortChanged,
    required this.onThrottleChanged,
  });

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late TextEditingController ipController;
  late TextEditingController portController;
  late double throttleLimit;

  @override
  void initState() {
    super.initState();
    ipController = TextEditingController(text: widget.currentIP);
    portController = TextEditingController(text: widget.currentPort.toString());
    throttleLimit = widget.maxThrottle;
  }

  @override
  void dispose() {
    ipController.dispose();
    portController.dispose();
    super.dispose();
  }

  bool _validateIP(String ip) {
    final ipRegex = RegExp(r'^(\d{1,3}\.){3}\d{1,3}$');
    if (!ipRegex.hasMatch(ip)) return false;

    final parts = ip.split('.');
    for (var part in parts) {
      final num = int.tryParse(part);
      if (num == null || num < 0 || num > 255) return false;
    }
    return true;
  }

  void _handleSave() {
    final newIP = ipController.text.trim();
    final newPort = int.tryParse(portController.text.trim()) ?? 8888;

    if (newIP.isEmpty) {
      _showError('IP address cannot be empty');
      return;
    }

    if (!_validateIP(newIP)) {
      _showError('Invalid IP address format');
      return;
    }

    if (newPort < 1 || newPort > 65535) {
      _showError('Port must be between 1 and 65535');
      return;
    }

    if (widget.isConnected && newIP != widget.currentIP) {
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: const Color(0xFF262B3F),
          title: const Text('⚠ Change Settings?', style: TextStyle(color: Colors.white)),
          content: const Text(
            'You are currently connected.\n\nChanging IP/Port will disconnect the current session.',
            style: TextStyle(color: Colors.white70),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.pop(context);
                widget.onIPChanged(newIP);
                widget.onPortChanged(newPort);
                widget.onThrottleChanged(throttleLimit);
                Navigator.pop(context);
              },
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF4A5FFF)),
              child: const Text('Apply'),
            ),
          ],
        ),
      );
    } else {
      widget.onIPChanged(newIP);
      widget.onPortChanged(newPort);
      widget.onThrottleChanged(throttleLimit);
      Navigator.pop(context);
    }
  }

  void _showError(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: Colors.red),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        backgroundColor: const Color(0xFF262B3F),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (widget.isConnected)
            Container(
              padding: const EdgeInsets.all(12),
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                color: Colors.green.withOpacity(0.2),
                border: Border.all(color: Colors.green),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  const Icon(Icons.check_circle, color: Colors.green),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Currently connected to ${widget.currentIP}:${widget.currentPort}',
                      style: const TextStyle(color: Colors.white),
                    ),
                  ),
                ],
              ),
            ),
          const Text(
            'Connection Settings',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: ipController,
            style: const TextStyle(color: Colors.white),
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: 'Drone IP Address',
              labelStyle: const TextStyle(color: Colors.white70),
              hintText: '192.168.4.1 or 10.189.133.122',
              hintStyle: TextStyle(color: Colors.white.withOpacity(0.3)),
              prefixIcon: const Icon(Icons.wifi, color: Color(0xFF4A5FFF)),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: Color(0xFF4A5FFF)),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: Color(0xFF4A5FFF), width: 2),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              _buildQuickIPButton('192.168.4.1'),
              _buildQuickIPButton('10.189.133.122'),
            ],
          ),
          const SizedBox(height: 16),
          TextField(
            controller: portController,
            style: const TextStyle(color: Colors.white),
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: 'UDP Port',
              labelStyle: const TextStyle(color: Colors.white70),
              hintText: '8888',
              hintStyle: TextStyle(color: Colors.white.withOpacity(0.3)),
              prefixIcon: const Icon(Icons.settings_ethernet, color: Color(0xFF4A5FFF)),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: Color(0xFF4A5FFF)),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: Color(0xFF4A5FFF), width: 2),
              ),
            ),
          ),
          const SizedBox(height: 24),
          const Text(
            'Throttle Limiter',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white),
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF262B3F),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Max Throttle:', style: TextStyle(color: Colors.white70)),
                    Text(
                      '${throttleLimit.toInt()}%',
                      style: const TextStyle(
                        color: Color(0xFF4A5FFF),
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                SliderTheme(
                  data: SliderThemeData(
                    activeTrackColor: const Color(0xFF4A5FFF),
                    inactiveTrackColor: Colors.white24,
                    thumbColor: const Color(0xFF4A5FFF),
                    overlayColor: const Color(0xFF4A5FFF).withOpacity(0.2),
                  ),
                  child: Slider(
                    value: throttleLimit,
                    min: 50,
                    max: 100,
                    divisions: 10,
                    label: '${throttleLimit.toInt()}%',
                    onChanged: (value) => setState(() => throttleLimit = value),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          ElevatedButton.icon(
            onPressed: _handleSave,
            icon: const Icon(Icons.save),
            label: const Text('Save Settings', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF4A5FFF),
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
          const SizedBox(height: 32),
          const Divider(color: Colors.white24),
          const SizedBox(height: 16),
          const Text(
            'Protocol Information',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white),
          ),
          const SizedBox(height: 16),
          _buildInfoCard('Protocol', 'UDP (User Datagram Protocol)'),
          _buildInfoCard('Packet Rate', '50 Hz (20ms interval)'),
          _buildInfoCard('Packet Format', 'THR,ROLL,PITCH,YAW,ARM,LED,SEQ,BAT'),
          _buildInfoCard('RC Range', '1000 - 2000 µs'),
          _buildInfoCard('Center Value', '1500 µs (neutral)'),
          _buildInfoCard('Expo', '30% (0.3)'),
          _buildInfoCard('Failsafe Timeout', '1000ms'),
          _buildInfoCard('Throttle Ramp', '50 PWM units/cycle'),
        ],
      ),
    );
  }

  Widget _buildInfoCard(String label, String value) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      color: const Color(0xFF262B3F),
      child: ListTile(
        title: Text(label, style: const TextStyle(color: Colors.white70)),
        trailing: Text(value, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
      ),
    );
  }

  Widget _buildQuickIPButton(String ip) {
    return ElevatedButton(
      onPressed: () {
        setState(() => ipController.text = ip);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('IP set to $ip'),
            duration: const Duration(seconds: 1),
            backgroundColor: const Color(0xFF4A5FFF),
          ),
        );
      },
      style: ElevatedButton.styleFrom(
        backgroundColor: const Color(0xFF262B3F),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: const BorderSide(color: Color(0xFF4A5FFF)),
        ),
      ),
      child: Text(ip, style: const TextStyle(color: Color(0xFF4A5FFF), fontSize: 12)),
    );
  }
}