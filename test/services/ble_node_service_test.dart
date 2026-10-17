import 'package:flutter_test/flutter_test.dart';
import 'package:telefonos_mesh/services/ble_node_service.dart';

void main() {
  group('BleNodeSnapshot', () {
    test('parses nearby nodes and active state', () {
      final snapshot = BleNodeSnapshot.fromMap({
        'active': true,
        'peers': [
          {'id': 'Nodo 1', 'rssi': -54},
        ],
        'payload': '{"id":"abc"}',
        'sourceAddress': 'AA:BB:CC:DD:EE:FF',
        'transferStatus': 'Transferencia iniciada',
      });

      expect(snapshot.active, isTrue);
      expect(snapshot.peers, hasLength(1));
      expect(snapshot.peers!.single.id, 'Nodo 1');
      expect(snapshot.peers!.single.name, 'Nodo 1');
      expect(snapshot.peers!.single.rssi, -54);
      expect(snapshot.receivedPayload, '{"id":"abc"}');
      expect(snapshot.sourceAddress, 'AA:BB:CC:DD:EE:FF');
      expect(snapshot.transferStatus, 'Transferencia iniciada');
    });

    test('reads a neighbor advertised name', () {
      final snapshot = BleNodeSnapshot.fromMap({
        'active': true,
        'peers': [
          {'id': 'Nodo 1', 'name': 'Casa norte', 'rssi': -54},
        ],
      });

      expect(snapshot.peers!.single.name, 'Casa norte');
    });

    test('parses alarm events without requiring BLE status fields', () {
      final snapshot = BleNodeSnapshot.fromMap({
        'seismicAlarmMonitoring': true,
        'seismicAlarmTriggered': true,
      });

      expect(snapshot.active, isNull);
      expect(snapshot.peers, isNull);
      expect(snapshot.seismicAlarmMonitoring, isTrue);
      expect(snapshot.seismicAlarmTriggered, isTrue);
    });

    test('rejects invalid node data', () {
      expect(
        () => BleNodeSnapshot.fromMap({
          'active': true,
          'peers': [
            {'id': 'Nodo 1', 'rssi': '-54'},
          ],
        }),
        throwsFormatException,
      );
    });
  });
}
