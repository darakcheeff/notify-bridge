import 'dart:convert';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'dart:typed_data';
import '../models/packet.dart';

class MqttService {
  MqttServerClient? _client;
  final String server;
  final int port;
  final String deviceId;
  String? currentGuid;

  MqttService({required this.server, required this.port, required this.deviceId});

  Future<bool> connect(String guid) async {
    currentGuid = guid;
    _client = MqttServerClient.withPort(server, deviceId, port);
    _client!.logging(on: false);
    _client!.keepAlivePeriod = 30;
    _client!.autoReconnect = true;
    _client!.onDisconnected = _onDisconnected;

    final connMess = MqttConnectMessage()
        .withClientIdentifier(deviceId)
        .startClean();
    _client!.connectionMessage = connMess;

    try {
      await _client!.connect();
    } catch (e) {
      _client!.disconnect();
      return false;
    }

    if (_client!.connectionStatus!.state == MqttConnectionState.connected) {
      _client!.subscribe('bridge/$currentGuid/downstream', MqttQos.atLeastOnce);
      return true;
    }
    return false;
  }

  void publishPacket(Packet packet) {
    if (_client == null || _client!.connectionStatus!.state != MqttConnectionState.connected) return;
    if (currentGuid == null) return;
    
    final topic = 'bridge/$currentGuid/upstream';
    final builder = MqttClientPayloadBuilder();
    final payload = utf8.encode(jsonEncode(packet.toJson()));
    builder.addUint8List(Uint8List.fromList(payload));
    
    _client!.publishMessage(topic, MqttQos.atLeastOnce, builder.payload!);
  }

  void _onDisconnected() {
    print('MQTT Disconnected');
  }

  Stream<List<MqttReceivedMessage<MqttMessage>>>? get messages => _client?.updates;
}
