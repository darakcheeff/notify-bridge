import 'dart:convert';
import 'package:flutter/foundation.dart';
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

  final ValueNotifier<MqttConnectionState> connectionState = ValueNotifier(MqttConnectionState.disconnected);
  DateTime? lastSuccess;

  MqttService({required this.server, required this.port, required this.deviceId});

  Future<bool> connect(String guid) async {
    currentGuid = guid;
    _client = MqttServerClient.withPort(server, deviceId, port);
    _client!.logging(on: false);
    _client!.keepAlivePeriod = 30;
    _client!.autoReconnect = true;
    _client!.onDisconnected = _onDisconnected;
    _client!.onConnected = _onConnected;
    _client!.onSubscribed = _onSubscribed;

    final connMess = MqttConnectMessage()
        .withClientIdentifier(deviceId)
        .startClean();
    _client!.connectionMessage = connMess;

    connectionState.value = MqttConnectionState.connecting;
    try {
      await _client!.connect();
    } catch (e) {
      _client!.disconnect();
      connectionState.value = MqttConnectionState.faulted;
      return false;
    }

    if (_client!.connectionStatus!.state == MqttConnectionState.connected) {
      _client!.subscribe('bridge/$currentGuid/downstream', MqttQos.atLeastOnce);
      connectionState.value = MqttConnectionState.connected;
      lastSuccess = DateTime.now();
      return true;
    }
    connectionState.value = _client!.connectionStatus!.state;
    return false;
  }

  void publishPacket(Packet packet) {
    if (_client == null || _client!.connectionStatus!.state != MqttConnectionState.connected) return;
    if (currentGuid == null) return;
    
    final topic = 'bridge/$currentGuid/upstream';
    final builder = MqttClientPayloadBuilder();
    final List<int> bytes = utf8.encode(jsonEncode(packet.toJson()));
    for (var b in bytes) {
      builder.addByte(b);
    }
    
    _client!.publishMessage(topic, MqttQos.atLeastOnce, builder.payload!);
  }

  void _onDisconnected() {
    print('MQTT Disconnected');
    connectionState.value = MqttConnectionState.disconnected;
  }

  void _onConnected() {
    print('MQTT Connected');
    connectionState.value = MqttConnectionState.connected;
    lastSuccess = DateTime.now();
  }

  void _onSubscribed(String topic) {
    print('MQTT Subscribed to $topic');
  }

  Stream<List<MqttReceivedMessage<MqttMessage>>>? get messages => _client?.updates;
}
