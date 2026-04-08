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

import 'dart:io';
import 'services/mqtt_service.dart';
import 'services/filtering_engine.dart';
import 'models/packet.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:qr_code_scanner/qr_code_scanner.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();
final FilteringEngine filteringEngine = FilteringEngine();
final GlobalKey<ScaffoldMessengerState> scaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();
MqttService? mqttService;
String serverAddress = "nb.ansy.us";
int serverPort = 1883;
String deviceDisplayName = "Android Device";
String currentGuid = "";
String deviceId = "";
Map<String, String> appNameCache = {};

List<NotificationItem> history = [];

class NotificationItem {
  final String deviceName;
  final String appName;
  final String title;
  final String body;
  final DateTime timestamp;

  NotificationItem({required this.deviceName, required this.appName, required this.title, required this.body, required this.timestamp});

  Map<String, dynamic> toJson() => {
    'deviceName': deviceName,
    'appName': appName,
    'title': title,
    'body': body,
    'timestamp': timestamp.toIso8601String(),
  };

  factory NotificationItem.fromJson(Map<String, dynamic> json) => NotificationItem(
    deviceName: json['deviceName'] ?? "",
    appName: json['appName'] ?? "",
    title: json['title'] ?? "",
    body: json['body'] ?? "",
    timestamp: DateTime.parse(json['timestamp']),
  );

  bool equals(NotificationItem other) {
    return deviceName == other.deviceName && appName == other.appName && title == other.title && body == other.body;
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  NotificationsListener.initialize(callbackHandle: onData);

  const AndroidInitializationSettings initializationSettingsAndroid = AndroidInitializationSettings('@mipmap/ic_launcher');
  const InitializationSettings initializationSettings = InitializationSettings(android: initializationSettingsAndroid);
  await flutterLocalNotificationsPlugin.initialize(settings: initializationSettings, onDidReceiveNotificationResponse: (_) {});

  final prefs = await SharedPreferences.getInstance();
  currentGuid = prefs.getString('guid') ?? "";
  deviceId = prefs.getString('device_id') ?? const Uuid().v4();
  serverAddress = prefs.getString('server_address') ?? "nb.ansy.us";
  serverPort = prefs.getInt('server_port') ?? 1883;
  
  String? savedName = prefs.getString('device_display_name');
  if (savedName == null) {
      deviceDisplayName = await _getDeviceModel();
      await prefs.setString('device_display_name', deviceDisplayName);
  } else {
      deviceDisplayName = savedName;
  }
  
  final historyJson = prefs.getStringList('history') ?? [];
  history = historyJson.map((e) => NotificationItem.fromJson(jsonDecode(e))).toList();
  
  await prefs.setString('device_id', deviceId);

  await filteringEngine.loadSettings();

  bool isFirstRun = prefs.getBool('first_run') ?? true;
  if (isFirstRun) {
    List<AppInfo> apps = await InstalledApps.getInstalledApps(excludeSystemApps: true);
    filteringEngine.allowedApps = apps.map((e) => e.packageName ?? "").where((e) => e.isNotEmpty).toList();
    await filteringEngine.saveSettings();
    await prefs.setBool('first_run', false);
  }

  if (currentGuid.isNotEmpty) {
    _initMqtt(currentGuid);
    _showPersistentNotification(); // Ensure foreground service is alive
  }

  // Request Battery Optimization Exemption on first run
  if (isFirstRun) {
    _requestBatteryOptimizationExemption();
  }

  // Listen for connectivity changes
  Connectivity().onConnectivityChanged.listen((List<ConnectivityResult> results) {
    if (results.isNotEmpty && results.any((r) => r != ConnectivityResult.none) && currentGuid.isNotEmpty) {
      if (mqttService == null || mqttService!.connectionState.value != MqttConnectionState.connected) {
        _initMqtt(currentGuid);
      }
    }
  });

  runApp(const MyApp());
}

Future<void> _requestBatteryOptimizationExemption() async {
  if (Platform.isAndroid) {
    final status = await Permission.ignoreBatteryOptimizations.status;
    if (!status.isGranted) {
       await Permission.ignoreBatteryOptimizations.request();
    }
  }
}

Future<String> _getDeviceModel() async {
  try {
    DeviceInfoPlugin deviceInfo = DeviceInfoPlugin();
    if (Platform.isAndroid) {
      AndroidDeviceInfo androidInfo = await deviceInfo.androidInfo;
      return androidInfo.model; // e.g. "mha-l29"
    }
  } catch (e) {
    // fallback
  }
  return "Android Device";
}

void _showPersistentNotification() async {
  const AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
    'service_channel',
    'Service Status',
    channelDescription: 'Keeps the app alive in background',
    importance: Importance.low,
    priority: Priority.low,
    ongoing: true,
    autoCancel: false,
    showWhen: false,
  );
  const NotificationDetails details = NotificationDetails(android: androidDetails);
  await flutterLocalNotificationsPlugin.show(
    id: 999,
    title: 'Notification Bridge',
    body: 'Служба активна и ожидает уведомлений',
    notificationDetails: details,
  );
}

@pragma('vm:entry-point')
void onData(NotificationEvent event) async {
  await filteringEngine.loadSettings();
  if (mqttService == null && currentGuid.isNotEmpty) {
    final prefs = await SharedPreferences.getInstance();
    serverAddress = prefs.getString('server_address') ?? "10.0.2.2";
    serverPort = prefs.getInt('server_port') ?? 1883;
    deviceDisplayName = prefs.getString('device_display_name') ?? "Android Device";
    _initMqtt(currentGuid);
  }

  String appName = appNameCache[event.packageName] ?? event.packageName ?? "Unknown";
  if (appName == event.packageName && event.packageName != null) {
     // Not in cache, try to fetch (this is async, so we might miss it for the very first notification)
     _getAndCacheAppName(event.packageName!);
  }

  if (filteringEngine.shouldSend(event.packageName ?? "", event.title ?? "", event.text ?? "")) {
    final packet = Packet(
      type: "notification",
      version: 1,
      metadata: PacketMetadata(
        deviceId: deviceId,
        deviceName: deviceDisplayName,
        guid: currentGuid,
        timestamp: DateTime.now().millisecondsSinceEpoch,
      ),
      data: PacketData(
        title: event.title ?? "",
        body: event.text ?? "",
        appPackage: event.packageName ?? "",
        appName: appName,
      ),
    );
    mqttService?.publishPacket(packet);
  }
}

Future<void> _getAndCacheAppName(String packageName) async {
  try {
    final app = await InstalledApps.getAppInfo(packageName);
    if (app != null && app.name != null) {
      appNameCache[packageName] = app.name!;
    }
  } catch (e) {}
}

void _initMqtt(String guid) async {
  mqttService = MqttService(server: serverAddress, port: serverPort, deviceId: deviceId);
  bool connected = await mqttService!.connect(guid);
  if (!connected) return;

  mqttService!.messages?.listen((messages) {
    for (var m in messages) {
      final MqttPublishMessage recMess = m.payload as MqttPublishMessage;
      final payload = utf8.decode(recMess.payload.message.toList());
      try {
        final decoded = jsonDecode(payload);
        final packet = Packet.fromJson(decoded);
        if (packet.metadata.deviceId == deviceId) continue; // ignore own loopback

        if (packet.type == 'link_test') {
          _showLocalNotification("Система", "Устройство ${packet.metadata.deviceName} успешно подключено к вашей группе!");
        } else if (packet.type == 'notification') {
          final item = NotificationItem(
            deviceName: packet.metadata.deviceName,
            appName: packet.data?.appName ?? packet.data?.appPackage ?? "Unknown",
            title: packet.data?.title ?? "",
            body: packet.data?.body ?? "",
            timestamp: DateTime.fromMillisecondsSinceEpoch(packet.metadata.timestamp),
          );
          _handleIncomingNotification(item);
        }
      } catch (e) {
        // malformed packet
      }
    }
  });
}

void _handleIncomingNotification(NotificationItem item) async {
  // Check for duplicates in history
  for (var existing in history) {
    if (existing.equals(item)) return; // Ignore duplicate
  }

  history.insert(0, item);
  if (history.length > 100) history.removeLast();

  final prefs = await SharedPreferences.getInstance();
  await prefs.setStringList('history', history.map((e) => jsonEncode(e.toJson())).toList());

  _showLocalNotification(
    item.appName,
    "${item.deviceName}\n${item.title}: ${item.body}",
    payload: jsonEncode(item.toJson()),
  );
}

void _showLocalNotification(String title, String message, {String? payload}) async {
  const AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
    'bridge_channel',
    'Notification Bridge Relays',
    importance: Importance.max,
    priority: Priority.high,
  );
  const NotificationDetails details = NotificationDetails(android: androidDetails);
  await flutterLocalNotificationsPlugin.show(
    id: DateTime.now().millisecondsSinceEpoch % 100000,
    title: title,
    body: message,
    notificationDetails: details,
    payload: payload,
  );
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      scaffoldMessengerKey: scaffoldMessengerKey,
      theme: ThemeData(primarySwatch: Colors.indigo, useMaterial3: true),
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
  int _selectedIndex = 0;

  final List<Widget> _tabs = [
    const HomeTab(),
    const FiltersTab(),
    const HistoryTab(),
  ];

  @override
  void initState() {
    super.initState();
    _handleIncomingLinks();
  }

  void _handleIncomingLinks() async {
    final initialUri = await _appLinks.getInitialLink();
    if (initialUri != null) _processUri(initialUri);
    _appLinks.uriLinkStream.listen((Uri? uri) {
      if (uri != null) _processUri(uri);
    });
  }

  void _processUri(Uri uri) async {
    if (uri.scheme == 'bridge' && uri.host == 'join') {
      final newGuid = uri.queryParameters['guid'];
      final newServer = uri.queryParameters['server'];
      final newPort = uri.queryParameters['port'];
      
      if (newGuid != null) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('guid', newGuid);
        currentGuid = newGuid;
        
        if (newServer != null) {
            serverAddress = newServer;
            await prefs.setString('server_address', newServer);
        }
        if (newPort != null) {
            int? p = int.tryParse(newPort);
            if (p != null) {
                serverPort = p;
                await prefs.setInt('server_port', p);
            }
        }
        
        _initMqtt(newGuid);
        setState(() {});
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Notification Bridge')),
      body: _tabs[_selectedIndex],
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _selectedIndex,
        onTap: (index) => setState(() => _selectedIndex = index),
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.home), label: 'Настройка'),
          BottomNavigationBarItem(icon: Icon(Icons.filter_alt), label: 'Фильтры'),
          BottomNavigationBarItem(icon: Icon(Icons.history), label: 'История'),
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
  final TextEditingController _serverController = TextEditingController();
  final TextEditingController _portController = TextEditingController();
  final TextEditingController _guidController = TextEditingController();
  final TextEditingController _nameController = TextEditingController();
  bool _hasPermission = false;

  @override
  void initState() {
    super.initState();
    _serverController.text = serverAddress;
    _portController.text = serverPort.toString();
    _guidController.text = currentGuid;
    _nameController.text = deviceDisplayName;
    _checkPermission();
  }
  
  // ... rest of methods like _saveServerConfig ...

  void _checkPermission() async {
    bool has = (await NotificationsListener.hasPermission) ?? false;
    setState(() => _hasPermission = has);
    if (has) {
       NotificationsListener.startService();
    }
  }

  void _grantPermission() async {
    await NotificationsListener.openPermissionSettings();
    // Re-check after the user returns from settings (approximate)
    Future.delayed(const Duration(seconds: 2), _checkPermission);
  }

  void _createGroup() async {
    final newGuid = const Uuid().v4();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('guid', newGuid);
    currentGuid = newGuid;
    _guidController.text = newGuid;
    _initMqtt(newGuid);
    setState(() {});
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
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Тест связи отправлен!')));
    }
  }

  void _saveServerConfig() async {
    final prefs = await SharedPreferences.getInstance();
    serverAddress = _serverController.text.trim();
    serverPort = int.tryParse(_portController.text.trim()) ?? 1883;
    deviceDisplayName = _nameController.text.trim();
    if (deviceDisplayName.isEmpty) deviceDisplayName = "Android Device";
    
    await prefs.setString('server_address', serverAddress);
    await prefs.setInt('server_port', serverPort);
    await prefs.setString('device_display_name', deviceDisplayName);
    
    if (currentGuid.isNotEmpty) {
      _initMqtt(currentGuid);
      _showPersistentNotification();
    }
    
    scaffoldMessengerKey.currentState?.showSnackBar(const SnackBar(content: Text('Настройки сохранены')));
  }

  void _joinManually() async {
    final newGuid = _guidController.text.trim();
    if (newGuid.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('guid', newGuid);
    currentGuid = newGuid;
    _initMqtt(newGuid);
    setState(() {});
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Присоединились вручную')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _buildConnectionStatus(),
              const SizedBox(height: 20),
              const Text('Настройки Сервера', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              TextField(controller: _nameController, decoration: const InputDecoration(labelText: "Имя этого устройства (напр. mha-l29)")),
              Row(
                children: [
                  Expanded(child: TextField(controller: _serverController, decoration: const InputDecoration(labelText: "Адрес сервера"))),
                  const SizedBox(width: 10),
                  SizedBox(width: 80, child: TextField(controller: _portController, decoration: const InputDecoration(labelText: "Порт"), keyboardType: TextInputType.number)),
                ],
              ),
              ElevatedButton(onPressed: _saveServerConfig, child: const Text("Сохранить настройки")),
              const Divider(height: 40),
              
              if (!_hasPermission)
                 Container(
                   padding: const EdgeInsets.all(12),
                   decoration: BoxDecoration(color: Colors.red.shade100, borderRadius: BorderRadius.circular(8)),
                   child: Column(
                     children: [
                       const Text("Нет прав на чтение уведомлений!", style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold)),
                       const SizedBox(height: 10),
                       const Text("Приложению нужен доступ к уведомлениям для пересылки сообщений.", textAlign: TextAlign.center),
                       ElevatedButton(onPressed: _grantPermission, child: const Text("Разрешить доступ")),
                     ],
                   ),
                 ),
              
              const SizedBox(height: 20),
              currentGuid.isEmpty
                  ? Column(
                      children: [
                        TextField(controller: _guidController, decoration: const InputDecoration(labelText: "GUID группы")),
                        const SizedBox(height: 10),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: [
                            ElevatedButton(onPressed: _createGroup, child: const Text("Создать группу")),
                            ElevatedButton(
                              onPressed: () async {
                                if (await Permission.camera.request().isGranted) {
                                  final result = await Navigator.push(context, MaterialPageRoute(builder: (context) => const QrScannerPage()));
                                  if (result != null) {
                                    final uri = Uri.parse(result);
                                    // Use the existing _processUri logic from MainScreen via a callback or duplicate
                                    // For simplicity here, we'll just handle it directly
                                    final newGuid = uri.queryParameters['guid'];
                                    final newServer = uri.queryParameters['server'];
                                    final newPort = uri.queryParameters['port'];
                                    if (newGuid != null) {
                                      final prefs = await SharedPreferences.getInstance();
                                      await prefs.setString('guid', newGuid);
                                      currentGuid = newGuid;
                                      if (newServer != null) {
                                        serverAddress = newServer;
                                        await prefs.setString('server_address', newServer);
                                      }
                                      if (newPort != null) {
                                        int? p = int.tryParse(newPort);
                                        if (p != null) {
                                          serverPort = p;
                                          await prefs.setInt('server_port', p);
                                        }
                                      }
                                      _initMqtt(newGuid);
                                      setState(() {});
                                    }
                                  }
                                }
                              },
                              child: const Icon(Icons.qr_code_scanner),
                            ),
                            ElevatedButton(onPressed: _joinManually, child: const Text("Присоединиться")),
                          ],
                        ),
                      ],
                    )
                  : Column(
                      children: [
                        const Text('Группа Активна', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
                        const SizedBox(height: 10),
                        QrImageView(
                          data: "bridge://join?guid=$currentGuid&server=$serverAddress&port=$serverPort",
                          version: QrVersions.auto,
                          size: 180.0,
                        ),
                        const SizedBox(height: 10),
                        SelectableText(currentGuid, textAlign: TextAlign.center),
                        const SizedBox(height: 20),
                        TextField(controller: _guidController, decoration: const InputDecoration(labelText: "Сменить GUID вручную")),
                        const SizedBox(height: 10),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: [
                            ElevatedButton(onPressed: _joinManually, child: const Text("Сменить GUID")),
                            ElevatedButton(onPressed: _testConnection, child: const Text('Проверить связь')),
                          ],
                        ),
                        const SizedBox(height: 20),
                        TextButton(onPressed: () {
                          setState(() {
                             currentGuid = "";
                             _guidController.clear();
                          });
                        }, child: const Text("Выйти из группы", style: TextStyle(color: Colors.red)))
                      ],
                    ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildConnectionStatus() {
    if (mqttService == null) {
      return const Card(
        color: Colors.grey,
        child: ListTile(
          leading: Icon(Icons.cloud_off, color: Colors.white),
          title: Text("Группа не создана", style: TextStyle(color: Colors.white)),
        ),
      );
    }

    return ValueListenableBuilder<MqttConnectionState>(
      valueListenable: mqttService!.connectionState,
      builder: (context, state, _) {
        Color color = Colors.grey;
        String statusText = "Отключено";
        IconData icon = Icons.cloud_off;

        switch (state) {
          case MqttConnectionState.connected:
            color = Colors.green;
            statusText = "Подключено";
            icon = Icons.cloud_done;
            break;
          case MqttConnectionState.connecting:
            color = Colors.orange;
            statusText = "Подключение...";
            icon = Icons.cloud_queue;
            break;
          case MqttConnectionState.faulted:
          case MqttConnectionState.disconnected:
            color = Colors.red;
            statusText = "Ошибка подключения";
            icon = Icons.cloud_off;
            break;
          default:
            break;
        }

        String lastSuccess = mqttService!.lastSuccess != null
            ? "Последнее удачное: ${_formatDateTime(mqttService!.lastSuccess!)}"
            : "Нет данных о подключении";

        return Card(
          color: color.withOpacity(0.1),
          shape: RoundedRectangleBorder(side: BorderSide(color: color, width: 2), borderRadius: BorderRadius.circular(12)),
          child: ListTile(
            leading: Icon(icon, color: color, size: 32),
            title: Text(statusText, style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 18)),
            subtitle: Text(lastSuccess, style: const TextStyle(fontSize: 12)),
          ),
        );
      },
    );
  }

  String _formatDateTime(DateTime dt) {
    return "${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}:${dt.second.toString().padLeft(2, '0')} ${dt.day.toString().padLeft(2, '0')}.${dt.month.toString().padLeft(2, '0')}";
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
    scaffoldMessengerKey.currentState?.showSnackBar(const SnackBar(content: Text('Настройки сохранены')));
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
          CheckboxListTile(
            title: const Text("Выбрать всё"),
            value: filteringEngine.allowedApps.length == _installedApps.length && _installedApps.isNotEmpty,
            onChanged: (val) {
              setState(() {
                if (val == true) {
                  filteringEngine.allowedApps = _installedApps.map((e) => e.packageName ?? "").where((e) => e.isNotEmpty).toList();
                } else {
                  filteringEngine.allowedApps.clear();
                }
              });
            },
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

class HistoryTab extends StatefulWidget {
  const HistoryTab({super.key});

  @override
  State<HistoryTab> createState() => _HistoryTabState();
}

class _HistoryTabState extends State<HistoryTab> {
  @override
  Widget build(BuildContext context) {
    return history.isEmpty
        ? const Center(child: Text("История пуста"))
        : ListView.separated(
            itemCount: history.length,
            separatorBuilder: (context, index) => const Divider(),
            itemBuilder: (context, index) {
              final item = history[index];
              return ListTile(
                leading: const Icon(Icons.notifications_active, color: Colors.indigo),
                title: Text("${item.title} (${item.appName})"),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(item.body),
                    const SizedBox(height: 4),
                    Text(
                      "${item.deviceName} • ${_formatDateTime(item.timestamp)}",
                      style: const TextStyle(fontSize: 11, color: Colors.grey),
                    ),
                  ],
                ),
              );
            },
          );
  }

  String _formatDateTime(DateTime dt) {
    return "${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}:${dt.second.toString().padLeft(2, '0')} ${dt.day.toString().padLeft(2, '0')}.${dt.month.toString().padLeft(2, '0')}";
  }
}

class QrScannerPage extends StatefulWidget {
  const QrScannerPage({super.key});

  @override
  State<QrScannerPage> createState() => _QrScannerPageState();
}

class _QrScannerPageState extends State<QrScannerPage> {
  final GlobalKey qrKey = GlobalKey(debugLabel: 'QR');
  QRViewController? controller;

  @override
  void reassemble() {
    super.reassemble();
    if (Platform.isAndroid) {
      controller?.pauseCamera();
    }
    controller?.resumeCamera();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Сканировать QR')),
      body: QRView(
        key: qrKey,
        onQRViewCreated: _onQRViewCreated,
      ),
    );
  }

  void _onQRViewCreated(QRViewController controller) {
    this.controller = controller;
    controller.scannedDataStream.listen((scanData) {
      final String? code = scanData.code;
      if (code != null && code.startsWith('bridge://join')) {
        controller.dispose();
        Navigator.pop(context, code);
      }
    });
  }

  @override
  void dispose() {
    controller?.dispose();
    super.dispose();
  }
}
// Poke stuck build
// Poke stuck build 2
