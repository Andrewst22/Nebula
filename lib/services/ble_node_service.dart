import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

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

    await _methodChannel.invokeMethod<void>('startNode');
  }

  Future<void> stop() => _methodChannel.invokeMethod<void>('stopNode');

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
                  'Aplicaciones > Enlace > Permisos.'
            : 'Concede permiso de ubicación mientras se usa la app para pedir ayuda.',
      );
    }
    final preciseLocation = await Permission.location.request();
    if (!preciseLocation.isGranted) {
      throw PlatformException(
        code: 'location_precise_permission_denied',
        message: preciseLocation.isPermanentlyDenied
            ? 'La ubicación precisa está bloqueada. Actívala en Ajustes > '
                  'Aplicaciones > Enlace > Permisos.'
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
}
