import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:installed_apps/app_info.dart';
import 'package:installed_apps/installed_apps.dart';
import 'package:app_links/app_links.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:uuid/uuid.dart';
import 'package:flutter_notification_listener/flutter_notification_listener.dart';
import 'package:mqtt_client/mqtt_client.dart';

import 'services/mqtt_service.dart';
import 'services/filtering_engine.dart';
import 'models/packet.dart';

final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();
final FilteringEngine filteringEngine = FilteringEngine();
MqttService? mqttService;
String currentGuid = "";
String deviceId = const Uuid().v4();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  NotificationsListener.initialize(callbackHandle: onData);

  const AndroidInitializationSettings initializationSettingsAndroid = AndroidInitializationSettings('@mipmap/ic_launcher');
  const InitializationSettings initializationSettings = InitializationSettings(android: initializationSettingsAndroid);
  await flutterLocalNotificationsPlugin.initialize(initializationSettings: initializationSettings);

  final prefs = await SharedPreferences.getInstance();
  currentGuid = prefs.getString('guid') ?? "";
  deviceId = prefs.getString('device_id') ?? const Uuid().v4();
  await prefs.setString('device_id', deviceId);

  await filteringEngine.loadSettings();

  if (currentGuid.isNotEmpty) {
    _initMqtt(currentGuid);
  }

  runApp(const MyApp());
}

@pragma('vm:entry-point')
void onData(NotificationEvent event) async {
  await filteringEngine.loadSettings();
  if (mqttService == null && currentGuid.isNotEmpty) {
    _initMqtt(currentGuid);
  }

  final String pack = event.packageName ?? "";
  final String title = event.title ?? "";
  final String text = event.text ?? "";

  if (filteringEngine.shouldSend(pack, title, text)) {
    final packet = Packet(
      type: "notification",
      version: 1,
      metadata: PacketMetadata(
        deviceId: deviceId,
        deviceName: "Android Receiver",
        guid: currentGuid,
        timestamp: DateTime.now().millisecondsSinceEpoch,
      ),
      data: PacketData(appPackage: pack, title: title, body: text),
    );
    mqttService?.publishPacket(packet);
  }
}

Future<void> _showLocalNotification(String content) async {
  const AndroidNotificationDetails androidNotificationDetails = AndroidNotificationDetails(
    'bridge_channel',
    'Bridge Notifications',
    importance: Importance.max,
    priority: Priority.high,
  );
  const NotificationDetails notificationDetails = NotificationDetails(android: androidNotificationDetails);
  await flutterLocalNotificationsPlugin.show(
    id: 0,
    title: 'Bridge Message',
    body: content,
    notificationDetails: notificationDetails,
  );
}

void _initMqtt(String guid) async {
  // Use a hardcoded local IP or configuration in production apps
  mqttService = MqttService(server: "10.0.2.2", port: 1883, deviceId: deviceId);
  bool connected = await mqttService!.connect(guid);
  if (!connected) return;

  mqttService!.messages?.listen((messages) {
    for (var m in messages) {
      final MqttPublishMessage recMess = m.payload as MqttPublishMessage;
      final payload = MqttPublishPayload.bytesToStringAsString(recMess.payload.message);
      try {
        final decoded = jsonDecode(payload);
        final packet = Packet.fromJson(decoded);
        if (packet.metadata.deviceId == deviceId) continue; // ignore own loopback

        if (packet.type == 'link_test') {
          _showLocalNotification("Устройство ${packet.metadata.deviceName} успешно подключено к вашей группе!");
        } else if (packet.type == 'notification') {
          _showLocalNotification("${packet.data?.title} - ${packet.data?.body}");
        }
      } catch (e) {
        // malformed packet
      }
    }
  });
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Notification Bridge',
      theme: ThemeData(primarySwatch: Colors.blue),
      home: const MainScreen(),
    );
  }
}

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});
  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  final _appLinks = AppLinks();
  int _currentIndex = 0;

  @override
  void initState() {
    super.initState();
    _handleIncomingLinks();
  }

  void _handleIncomingLinks() {
    _appLinks.uriLinkStream.listen((Uri? uri) async {
      if (uri != null && uri.scheme == 'bridge' && uri.host == 'join') {
        final newGuid = uri.queryParameters['guid'];
        if (newGuid != null) {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString('guid', newGuid);
          currentGuid = newGuid;
          _initMqtt(newGuid);
          setState(() {});
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Joined new group!')));
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    List<Widget> pages = [
      const HomeTab(),
      const FiltersTab(),
    ];

    return Scaffold(
      body: pages[_currentIndex],
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        onTap: (i) => setState(() => _currentIndex = i),
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.link), label: "Onboarding"),
          BottomNavigationBarItem(icon: Icon(Icons.filter_list), label: "Filters"),
        ],
      ),
    );
  }
}

// ----------------------------------------------------
// UI: Onboarding & Link Testing
// ----------------------------------------------------
class HomeTab extends StatefulWidget {
  const HomeTab({super.key});
  @override
  State<HomeTab> createState() => _HomeTabState();
}

class _HomeTabState extends State<HomeTab> {
  void _createGroup() async {
    final newGuid = const Uuid().v4();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('guid', newGuid);
    setState(() => currentGuid = newGuid);
    _initMqtt(newGuid);
  }

  void _testConnection() {
    if (mqttService != null && currentGuid.isNotEmpty) {
      final packet = Packet(
        type: "link_test",
        version: 1,
        metadata: PacketMetadata(
          deviceId: deviceId,
          deviceName: "Android User",
          guid: currentGuid,
          timestamp: DateTime.now().millisecondsSinceEpoch,
        ),
      );
      mqttService!.publishPacket(packet);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Link test sent!')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Center(
        child: currentGuid.isEmpty
            ? ElevatedButton(onPressed: _createGroup, child: const Text("Создать группу"))
            : Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text('Group Active', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 20),
                  QrImageView(
                    data: "bridge://join?guid=$currentGuid",
                    version: QrVersions.auto,
                    size: 200.0,
                  ),
                  const SizedBox(height: 20),
                  SelectableText(currentGuid),
                  const SizedBox(height: 40),
                  ElevatedButton(
                      onPressed: _testConnection,
                      child: const Text('Проверить связь')),
                ],
              ),
      ),
    );
  }
}

// ----------------------------------------------------
// UI: Priority Filtering
// ----------------------------------------------------
class FiltersTab extends StatefulWidget {
  const FiltersTab({super.key});
  @override
  State<FiltersTab> createState() => _FiltersTabState();
}

class _FiltersTabState extends State<FiltersTab> {
  final TextEditingController _whiteListController = TextEditingController();
  final TextEditingController _blackListController = TextEditingController();
  List<AppInfo> _installedApps = [];
  
  @override
  void initState() {
    super.initState();
    _whiteListController.text = filteringEngine.whitelist.join('\n');
    _blackListController.text = filteringEngine.blacklist.join('\n');
    _loadApps();
  }

  void _loadApps() async {
    List<AppInfo> apps = await InstalledApps.getInstalledApps(excludeSystemApps: true, withIcon: true);
    setState(() {
      _installedApps = apps;
    });
  }

  void _save() async {
    filteringEngine.whitelist = _whiteListController.text.split('\n').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
    filteringEngine.blacklist = _blackListController.text.split('\n').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
    await filteringEngine.saveSettings();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Настройки сохранены')));
    }
  }

  void _reset() async {
    filteringEngine.whitelist.clear();
    filteringEngine.blacklist.clear();
    filteringEngine.allowedApps.clear();
    await filteringEngine.saveSettings();
    _whiteListController.clear();
    _blackListController.clear();
    setState(() {});
  }

  void _toggleApp(String package, bool? selected) {
    setState(() {
      if (selected == true) {
        filteringEngine.allowedApps.add(package);
      } else {
        filteringEngine.allowedApps.remove(package);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: TextField(
              controller: _whiteListController,
              decoration: const InputDecoration(labelText: 'Белый список (каждое правило с новой строки)', border: OutlineInputBorder()),
              maxLines: 3,
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: TextField(
              controller: _blackListController,
              decoration: const InputDecoration(labelText: 'Черный список (каждое правило с новой строки)', border: OutlineInputBorder()),
              maxLines: 3,
            ),
          ),
          Expanded(
            child: _installedApps.isEmpty
                ? const Center(child: CircularProgressIndicator())
                : ListView.builder(
                    itemCount: _installedApps.length,
                    itemBuilder: (context, index) {
                      final app = _installedApps[index];
                      final pName = app.packageName ?? '';
                      final isSelected = filteringEngine.allowedApps.contains(pName);
                      return CheckboxListTile(
                        value: isSelected,
                        onChanged: (val) => _toggleApp(pName, val),
                        title: Text(app.name ?? ''),
                        subtitle: Text(pName),
                        secondary: app.icon != null ? Image.memory(app.icon!, width: 40, height: 40) : null,
                      );
                    },
                  ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              ElevatedButton(onPressed: _reset, child: const Text('Сброс')),
              ElevatedButton(onPressed: _save, child: const Text('Применить')),
            ],
          ),
          const SizedBox(height: 10),
        ],
      ),
    );
  }
}
