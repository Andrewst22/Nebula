import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

class PhotoAttachment {
  const PhotoAttachment({
    required this.id,
    required this.path,
    required this.bytes,
    required this.mimeType,
  });

  final String id;
  final String path;
  final int bytes;
  final String mimeType;

  factory PhotoAttachment.fromMap(Object? value) {
    if (value is! Map<Object?, Object?> ||
        value['id'] is! String ||
        value['path'] is! String ||
        value['bytes'] is! int ||
        value['mimeType'] is! String) {
      throw const FormatException('La foto seleccionada no es válida.');
    }
    return PhotoAttachment(
      id: value['id']! as String,
      path: value['path']! as String,
      bytes: value['bytes']! as int,
      mimeType: value['mimeType']! as String,
    );
  }
}

class NearbyNode {
  const NearbyNode({required this.id, required this.name, required this.rssi});

  final String id;
  final String name;
  final int rssi;

  factory NearbyNode.fromMap(Object? value) {
    if (value is! Map<Object?, Object?> ||
        value['id'] is! String ||
        value['rssi'] is! int) {
      throw const FormatException(
        'La información del nodo cercano no es válida.',
      );
    }
    final id = value['id']! as String;
    return NearbyNode(
      id: id,
      name: value['name'] is String ? value['name']! as String : id,
      rssi: value['rssi']! as int,
    );
  }
}

class CurrentGpsLocation {
  const CurrentGpsLocation({
    required this.latitude,
    required this.longitude,
    required this.accuracyMeters,
  });

  final double latitude;
  final double longitude;
  final double accuracyMeters;

  String get coordinates =>
      '${latitude.toStringAsFixed(6)}, ${longitude.toStringAsFixed(6)}';
}

class BleNodeSnapshot {
  const BleNodeSnapshot({
    this.active,
    this.peers,
    this.receivedPayload,
    this.sourceAddress,
    this.error,
    this.transferStatus,
    this.wifiTransferStatus,
    this.seismicAlarmMonitoring,
    this.seismicAlarmTriggered,
    this.seismicAlarmError,
  });

  final bool? active;
  final List<NearbyNode>? peers;
  final String? receivedPayload;
  final String? sourceAddress;
  final String? error;
  final String? transferStatus;
  final String? wifiTransferStatus;
  final bool? seismicAlarmMonitoring;
  final bool? seismicAlarmTriggered;
  final String? seismicAlarmError;

  factory BleNodeSnapshot.fromMap(Object? value) {
    if (value is! Map<Object?, Object?>) {
      throw const FormatException('El estado Bluetooth recibido no es válido.');
    }
    final active = value['active'];
    final peerValues = value['peers'];
    final monitoring = value['seismicAlarmMonitoring'];
    final triggered = value['seismicAlarmTriggered'];
    if ((active != null && active is! bool) ||
        (peerValues != null && peerValues is! List) ||
        (monitoring != null && monitoring is! bool) ||
        (triggered != null && triggered is! bool)) {
      throw const FormatException('El estado Bluetooth recibido no es válido.');
    }
    return BleNodeSnapshot(
      active: active as bool?,
      peers: peerValues == null
          ? null
          : (peerValues as List).map(NearbyNode.fromMap).toList(),
      receivedPayload: value['payload'] is String
          ? value['payload']! as String
          : null,
      sourceAddress: value['sourceAddress'] is String
          ? value['sourceAddress']! as String
          : null,
      error: value['error'] is String ? value['error']! as String : null,
      transferStatus: value['transferStatus'] is String
          ? value['transferStatus']! as String
          : null,
      wifiTransferStatus: value['wifiTransferStatus'] is String
          ? value['wifiTransferStatus']! as String
          : null,
      seismicAlarmMonitoring: monitoring as bool?,
      seismicAlarmTriggered: triggered as bool?,
      seismicAlarmError: value['seismicAlarmError'] is String
          ? value['seismicAlarmError']! as String
          : null,
    );
  }
}

class BleNodeService {
  static const _methodChannel = MethodChannel('org.comunidad.enlace/ble');
  static const _eventChannel = EventChannel('org.comunidad.enlace/ble-events');

  Stream<BleNodeSnapshot> get snapshots =>
      _eventChannel.receiveBroadcastStream().map(BleNodeSnapshot.fromMap);

  Future<void> start() async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      throw PlatformException(
        code: 'android_only',
        message:
            'El descubrimiento BLE está disponible solo en Android por ahora.',
      );
    }

    final androidSdk = await _methodChannel.invokeMethod<int>('getAndroidSdk');
    if (androidSdk == null) {
      throw PlatformException(
        code: 'android_version_unavailable',
        message: 'No se pudo determinar la versión de Android.',
      );
    }
    final requestedPermissions = androidSdk >= 31
        ? [
            Permission.bluetoothScan,
            Permission.bluetoothAdvertise,
            Permission.bluetoothConnect,
            if (androidSdk >= 33) Permission.notification,
          ]
        : [Permission.locationWhenInUse];
    final statuses = await requestedPermissions.request();
    final denied = statuses.entries
        .where((entry) => !entry.value.isGranted)
        .map((entry) => entry.key.toString())
        .toList();
    if (denied.isNotEmpty) {
      throw PlatformException(
        code: 'ble_permission_denied',
        message:
            'No se inició el nodo. Concede los permisos Bluetooth solicitados'
            ' (${denied.join(', ')}) y vuelve a intentarlo.',
      );
    }

    await _requestWifiDirectPermission(androidSdk, required: false);
    await _methodChannel.invokeMethod<void>('startNode');
  }

  Future<void> stop() => _methodChannel.invokeMethod<void>('stopNode');

  Future<void> refreshScan() =>
      _methodChannel.invokeMethod<void>('refreshBleScan');

  Future<void> setSeismicAlarmEnabled(bool enabled) => _methodChannel
      .invokeMethod<void>('setSeismicAlarmEnabled', {'enabled': enabled});

  Future<void> setNodeName(String name) =>
      _methodChannel.invokeMethod<void>('setNodeName', {'name': name});

  Future<CurrentGpsLocation> getCurrentGpsLocation() async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      throw PlatformException(
        code: 'android_only',
        message: 'La ubicación GPS está disponible solo en Android por ahora.',
      );
    }
    final foregroundLocation = await Permission.locationWhenInUse.request();
    if (!foregroundLocation.isGranted) {
      throw PlatformException(
        code: 'location_permission_denied',
        message: foregroundLocation.isPermanentlyDenied
            ? 'El permiso de ubicación está bloqueado. Actívalo en Ajustes > '
                  'Aplicaciones > NEBULA > Permisos.'
            : 'Concede permiso de ubicación mientras se usa la app para pedir ayuda.',
      );
    }
    final preciseLocation = await Permission.location.request();
    if (!preciseLocation.isGranted) {
      throw PlatformException(
        code: 'location_precise_permission_denied',
        message: preciseLocation.isPermanentlyDenied
            ? 'La ubicación precisa está bloqueada. Actívala en Ajustes > '
                  'Aplicaciones > NEBULA > Permisos.'
            : 'Permite ubicación precisa para compartir coordenadas GPS. '
                  'La ubicación aproximada no es suficiente.',
      );
    }
    final locationService = await Permission.location.serviceStatus;
    if (!locationService.isEnabled) {
      throw PlatformException(
        code: 'location_services_disabled',
        message:
            'Activa Ubicación/GPS en los ajustes rápidos e inténtalo otra vez.',
      );
    }
    final value = await _methodChannel.invokeMapMethod<String, Object?>(
      'getCurrentGpsLocation',
    );
    if (value == null ||
        value['latitude'] is! num ||
        value['longitude'] is! num ||
        value['accuracyMeters'] is! num) {
      throw PlatformException(
        code: 'location_result_invalid',
        message: 'Android devolvió una ubicación GPS no válida.',
      );
    }
    return CurrentGpsLocation(
      latitude: (value['latitude']! as num).toDouble(),
      longitude: (value['longitude']! as num).toDouble(),
      accuracyMeters: (value['accuracyMeters']! as num).toDouble(),
    );
  }

  Future<List<String>> loadBackgroundMessages() async {
    if (defaultTargetPlatform != TargetPlatform.android) return const [];
    final values = await _methodChannel.invokeListMethod<String>(
      'getBackgroundMessages',
    );
    if (values == null) {
      throw PlatformException(
        code: 'ble_message_store_unavailable',
        message:
            'No se pudieron recuperar los mensajes recibidos en segundo plano.',
      );
    }
    return values;
  }

  Future<void> clearAllBackgroundMessages() async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    await _methodChannel.invokeMethod<void>('clearAllMessages');
  }

  Future<Map<String, Object?>> getAutoStartDiagnostics() async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return const {};
    }
    final values = await _methodChannel.invokeMapMethod<String, Object?>(
      'getAutoStartDiagnostics',
    );
    if (values == null ||
        values['status'] is! String ||
        values['autoStartEnabled'] is! bool ||
        values['timestamp'] is! int) {
      throw PlatformException(
        code: 'auto_start_diagnostics_invalid',
        message: 'No se pudo leer el diagnóstico de arranque.',
      );
    }
    return values;
  }

  Future<bool> requestNotificationPermission() async {
    if (defaultTargetPlatform != TargetPlatform.android) return false;
    final androidSdk = await _methodChannel.invokeMethod<int>('getAndroidSdk');
    if (androidSdk == null) {
      throw PlatformException(
        code: 'android_version_unavailable',
        message: 'No se pudo determinar la versión de Android.',
      );
    }
    if (androidSdk < 33) return true;
    return (await Permission.notification.request()).isGranted;
  }

  Future<int> broadcast(String payload, {String? excludedAddress}) async {
    final recipients = await _methodChannel.invokeMethod<int>(
      'broadcastMessage',
      {'payload': payload, 'excludedAddress': excludedAddress},
    );
    if (recipients == null) {
      throw PlatformException(
        code: 'ble_broadcast_failed',
        message: 'No se pudo iniciar el envío Bluetooth.',
      );
    }
    return recipients;
  }

  Future<PhotoAttachment?> pickPhoto() async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      throw PlatformException(
        code: 'android_only',
        message:
            'La transferencia Wi-Fi Direct está disponible solo en Android.',
      );
    }
    final androidSdk = await _methodChannel.invokeMethod<int>('getAndroidSdk');
    if (androidSdk == null) {
      throw PlatformException(
        code: 'android_version_unavailable',
        message: 'No se pudo determinar la versión de Android.',
      );
    }
    await startPhotoTransport(androidSdk: androidSdk);
    final hasPermission = await _methodChannel.invokeMethod<bool>(
      'hasWifiDirectPermission',
    );
    if (hasPermission != true) {
      throw PlatformException(
        code: 'wifi_direct_permission_denied',
        message: 'Concede el permiso de ubicación para descubrir nodos Wi-Fi cercanos.',
      );
    }
    final value = await _methodChannel.invokeMapMethod<String, Object?>(
      'pickPhoto',
    );
    if (value == null) return null;
    try {
      return PhotoAttachment.fromMap(value);
    } on FormatException catch (error) {
      throw PlatformException(
        code: 'photo_pick_invalid',
        message: error.message,
      );
    }
  }

  Future<void> startPhotoTransport({int? androidSdk}) async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    final sdk =
        androidSdk ?? await _methodChannel.invokeMethod<int>('getAndroidSdk');
    if (sdk == null) {
      throw PlatformException(
        code: 'android_version_unavailable',
        message: 'No se pudo determinar la versión de Android.',
      );
    }
    await _requestWifiDirectPermission(sdk, required: true);
    await _methodChannel.invokeMethod<void>('startPhotoTransport');
  }

  Future<bool> _requestWifiDirectPermission(
    int androidSdk, {
    required bool required,
  }) async {
    final permission = androidSdk >= 33
        ? Permission.nearbyWifiDevices
        : Permission.locationWhenInUse;
    final status = await permission.request();
    if (status.isGranted) return true;
    if (required) {
      throw PlatformException(
        code: androidSdk >= 33
            ? 'wifi_direct_permission_denied'
            : 'wifi_direct_location_permission_denied',
        message: androidSdk >= 33
            ? 'Concede “Dispositivos Wi-Fi cercanos” a NEBULA para que este nodo reciba y reenvíe fotos.'
            : 'Concede ubicación mientras se usa NEBULA para descubrir nodos Wi-Fi Direct.',
      );
    }
    return false;
  }

  Future<void> enqueuePhoto(String id, String reportPayload) async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    await _methodChannel.invokeMethod<void>('enqueuePhoto', {
      'id': id,
      'reportPayload': reportPayload,
    });
  }

  Future<String?> getPhotoPath(String id) async {
    if (defaultTargetPlatform != TargetPlatform.android) return null;
    return _methodChannel.invokeMethod<String>('getPhotoPath', {'id': id});
  }

  Future<void> openWifiSettings() async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    await _methodChannel.invokeMethod<void>('openWifiSettings');
  }
}
