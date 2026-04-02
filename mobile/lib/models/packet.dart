class Packet {
  final String type;
  final int version;
  final PacketMetadata metadata;
  final PacketData? data;

  Packet({
    required this.type,
    required this.version,
    required this.metadata,
    this.data,
  });

  factory Packet.fromJson(Map<String, dynamic> json) {
    return Packet(
      type: json['type'] as String,
      version: json['version'] as int,
      metadata: PacketMetadata.fromJson(json['metadata'] as Map<String, dynamic>),
      data: json['data'] != null ? PacketData.fromJson(json['data'] as Map<String, dynamic>) : null,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'type': type,
      'version': version,
      'metadata': metadata.toJson(),
      if (data != null) 'data': data!.toJson(),
    };
  }
}

class PacketMetadata {
  final String deviceId;
  final String deviceName;
  final String guid;
  final int timestamp;

  PacketMetadata({
    required this.deviceId,
    required this.deviceName,
    required this.guid,
    required this.timestamp,
  });

  factory PacketMetadata.fromJson(Map<String, dynamic> json) {
    return PacketMetadata(
      deviceId: json['device_id'] as String,
      deviceName: json['device_name'] as String,
      guid: json['guid'] as String,
      timestamp: json['timestamp'] as int,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'device_id': deviceId,
      'device_name': deviceName,
      'guid': guid,
      'timestamp': timestamp,
    };
  }
}

class PacketData {
  final String? appPackage;
  final String? title;
  final String? body;

  PacketData({
    this.appPackage,
    this.title,
    this.body,
  });

  factory PacketData.fromJson(Map<String, dynamic> json) {
    return PacketData(
      appPackage: json['app_package'] as String?,
      title: json['title'] as String?,
      body: json['body'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    final Map<String, dynamic> mappedData = {};
    if (appPackage != null) mappedData['app_package'] = appPackage;
    if (title != null) mappedData['title'] = title;
    if (body != null) mappedData['body'] = body;
    return mappedData;
  }
}
