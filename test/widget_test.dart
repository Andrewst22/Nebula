import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:telefonos_mesh/main.dart';
import 'package:telefonos_mesh/models/local_message.dart';

void main() {
  testWidgets('quick alert message cards use a color for each alert type', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('org.comunidad.enlace/ble'),
          (call) async {
            if (call.method == 'getBackgroundMessages') return <String>[];
            if (call.method == 'getAutoStartDiagnostics') {
              return <String, Object>{
                'status': 'Sin evento de arranque registrado.',
                'timestamp': 0,
                'autoStartEnabled': false,
              };
            }
            return null;
          },
        );
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('org.comunidad.enlace/ble'),
            null,
          ),
    );

    const alertTexts = [
      '🆘 PIDO AYUDA\nGPS: 10.0, -66.0',
      '🔥 INCENDIO EN CASA\nGPS: 10.0, -66.0',
      '🚨 ROBO EN CASA\nGPS: 10.0, -66.0',
      'PERSONA DESAPARECIDA | Visto: Plaza',
      'MASCOTA DESAPARECIDA | Visto: Plaza',
    ];
    final expectedBackgrounds = [
      const Color(0xFFFFEFEC),
      const Color(0xFFFFF0E6),
      const Color(0xFFF2EDF5),
      const Color(0xFFF1EDF8),
      const Color(0xFFEDF5EE),
    ];
    final messages = alertTexts
        .map(
          (text) =>
              LocalMessage.create(text: text, priority: MessagePriority.urgent),
        )
        .toList();
    SharedPreferences.setMockInitialValues({
      'enlace.local_messages.v1': jsonEncode(
        messages.map((message) => message.toJson()).toList(),
      ),
    });

    await tester.pumpWidget(const EnlaceApp());
    await tester.pumpAndSettle();
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -2000));
    await tester.pumpAndSettle();

    for (var index = 0; index < messages.length; index++) {
      final card = tester.widget<Container>(
        find.byKey(Key('message-card-${messages[index].id}')),
      );
      final decoration = card.decoration! as BoxDecoration;
      expect(decoration.color, expectedBackgrounds[index]);
    }
  });

  testWidgets('seismic alarm preference is visible and can be disabled', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var nativeAlarmEnabled = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('org.comunidad.enlace/ble'),
          (call) async {
            if (call.method == 'getBackgroundMessages') return <String>[];
            if (call.method == 'getAutoStartDiagnostics') {
              return <String, Object>{
                'status': 'Sin evento de arranque registrado.',
                'timestamp': 0,
                'autoStartEnabled': false,
              };
            }
            if (call.method == 'setSeismicAlarmEnabled') {
              nativeAlarmEnabled = call.arguments['enabled'] as bool;
            }
            return null;
          },
        );
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('org.comunidad.enlace/ble'),
            null,
          ),
    );
    SharedPreferences.setMockInitialValues({'seismic_alarm_enabled': true});
    await tester.pumpWidget(const EnlaceApp());
    await tester.pumpAndSettle();
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -1000));
    await tester.pumpAndSettle();

    expect(find.text('Alarma experimental de vibración'), findsOneWidget);
    expect(
      find.textContaining('activa el nodo Bluetooth para iniciar'),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('seismic-alarm-switch')));
    await tester.pumpAndSettle();

    expect(nativeAlarmEnabled, isFalse);
    expect(
      (await SharedPreferences.getInstance()).getBool('seismic_alarm_enabled'),
      isFalse,
    );
  });

  testWidgets('dark mode switch changes theme and persists preference', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('org.comunidad.enlace/ble'),
          (call) async {
            if (call.method == 'getBackgroundMessages') return <String>[];
            if (call.method == 'getAutoStartDiagnostics') {
              return <String, Object>{
                'status': 'Sin evento de arranque registrado.',
                'timestamp': 0,
                'autoStartEnabled': false,
              };
            }
            return null;
          },
        );
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('org.comunidad.enlace/ble'),
            null,
          ),
    );
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const EnlaceApp());
    await tester.pumpAndSettle();
    expect(
      Theme.of(tester.element(find.byType(Scaffold).first)).brightness,
      Brightness.light,
    );

    await tester.ensureVisible(find.byKey(const Key('dark-mode-switch')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('dark-mode-switch')));
    await tester.pumpAndSettle();

    expect(
      Theme.of(tester.element(find.byType(Scaffold).first)).brightness,
      Brightness.dark,
    );
    expect(
      (await SharedPreferences.getInstance()).getBool('dark_mode'),
      isTrue,
    );
  });

  testWidgets(
    'missing reports use entered location and do not request sender GPS',
    (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('org.comunidad.enlace/ble'),
            (call) async {
              if (call.method == 'getBackgroundMessages') return <String>[];
              if (call.method == 'getAutoStartDiagnostics') {
                return <String, Object>{
                  'status': 'Sin evento de arranque registrado.',
                  'timestamp': 0,
                  'autoStartEnabled': false,
                };
              }
              if (call.method == 'getCurrentGpsLocation') {
                return <String, Object>{
                  'latitude': 10.123456,
                  'longitude': -66.987654,
                  'accuracyMeters': 8.0,
                };
              }
              return null;
            },
          );
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('org.comunidad.enlace/ble'),
              null,
            ),
      );
      const permissionChannel = MethodChannel(
        'flutter.baseflow.com/permissions/methods',
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(permissionChannel, (call) async {
            if (call.method == 'requestPermissions') {
              final requested = call.arguments as List<Object?>;
              return {
                for (final permission in requested) permission! as int: 1,
              };
            }
            if (call.method == 'checkServiceStatus') return 1;
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(permissionChannel, null),
      );
      SharedPreferences.setMockInitialValues({});
      await tester.pumpWidget(const EnlaceApp());
      await tester.pumpAndSettle();

      await tester.ensureVisible(
        find.byKey(const Key('quick-report-missing-person')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('quick-report-missing-person')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('select-missing-person-photo')),
        findsOneWidget,
      );
      await tester.enterText(
        find.byKey(const Key('missing-person-name')),
        'Ana',
      );
      await tester.enterText(
        find.byKey(const Key('missing-last-seen')),
        'Parque, hoy 15h',
      );
      await tester.enterText(
        find.byKey(const Key('missing-person-clothing')),
        'Camisa azul',
      );
      await tester.enterText(
        find.byKey(const Key('missing-characteristics')),
        'Pelo oscuro',
      );
      await tester.ensureVisible(
        find.byKey(const Key('continue-missing-report')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('continue-missing-report')));
      await tester.pumpAndSettle();

      expect(find.textContaining('PERSONA DESAPARECIDA'), findsOneWidget);
      expect(find.textContaining('Camisa azul'), findsOneWidget);
      expect(find.textContaining('Visto: Parque, hoy 15h'), findsOneWidget);
      expect(find.textContaining('GPS:'), findsNothing);
      await tester.tap(find.byKey(const Key('confirm-quick-alert')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Ana'), findsOneWidget);

      await tester.ensureVisible(
        find.byKey(const Key('quick-report-missing-pet')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('quick-report-missing-pet')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('missing-pet-category')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Gato').last);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('missing-pet-name')),
        'Michi',
      );
      await tester.enterText(
        find.byKey(const Key('missing-last-seen')),
        'Calle 4, hoy',
      );
      await tester.enterText(
        find.byKey(const Key('missing-characteristics')),
        'Gris, collar rojo',
      );
      await tester.ensureVisible(
        find.byKey(const Key('continue-missing-report')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('continue-missing-report')));
      await tester.pumpAndSettle();
      expect(find.text('Completa este campo.'), findsOneWidget);
      expect(find.text('Tipo de mascota'), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('missing-pet-breed')),
        'Siamés',
      );
      await tester.ensureVisible(
        find.byKey(const Key('continue-missing-report')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('continue-missing-report')));
      await tester.pumpAndSettle();
      expect(find.textContaining('MASCOTA DESAPARECIDA'), findsOneWidget);
      expect(find.textContaining('Gato'), findsOneWidget);
      expect(find.textContaining('Raza: Siamés'), findsOneWidget);
      expect(find.textContaining('Visto: Calle 4, hoy'), findsOneWidget);
      expect(find.textContaining('GPS:'), findsNothing);
      expect(find.textContaining('Gris, collar rojo'), findsOneWidget);
      await tester.tap(find.byKey(const Key('confirm-quick-alert')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Michi'), findsOneWidget);
      expect(find.textContaining('URGENTE · GUARDADO LOCAL'), findsNWidgets(2));
    },
  );

  testWidgets('robbery report can attach an evidence photo', (tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('org.comunidad.enlace/ble'),
          (call) async {
            switch (call.method) {
              case 'getBackgroundMessages':
                return <String>[];
              case 'getAutoStartDiagnostics':
                return <String, Object>{
                  'status': 'Sin evento de arranque registrado.',
                  'timestamp': 0,
                  'autoStartEnabled': false,
                };
              case 'getAndroidSdk':
                return 35;
              case 'hasWifiDirectPermission':
                return true;
              case 'pickPhoto':
                return <String, Object>{
                  'id': 'a' * 32,
                  'path':
                      'android/app/src/main/res/mipmap-mdpi/ic_launcher.png',
                  'bytes': 1024,
                  'mimeType': 'image/png',
                };
              case 'getCurrentGpsLocation':
                return <String, Object>{
                  'latitude': 10.123456,
                  'longitude': -66.987654,
                  'accuracyMeters': 8.0,
                };
              default:
                return null;
            }
          },
        );
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('org.comunidad.enlace/ble'),
            null,
          ),
    );
    const permissionChannel = MethodChannel(
      'flutter.baseflow.com/permissions/methods',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(permissionChannel, (call) async {
          if (call.method == 'requestPermissions') {
            final requested = call.arguments as List<Object?>;
            return {for (final permission in requested) permission! as int: 1};
          }
          if (call.method == 'checkServiceStatus') return 1;
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(permissionChannel, null),
    );
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const EnlaceApp());
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byKey(const Key('quick-report-robbery')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('quick-report-robbery')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('select-robbery-photo')), findsOneWidget);

    await tester.tap(find.byKey(const Key('select-robbery-photo')));
    await tester.pumpAndSettle();
    expect(find.text('Cambiar foto'), findsOneWidget);
    await tester.tap(find.byKey(const Key('continue-robbery-report')));
    await tester.pumpAndSettle();
    expect(find.textContaining('GPS: 10.123456, -66.987654'), findsOneWidget);
    expect(
      find.textContaining('La foto también se compartirá'),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('confirm-quick-alert')));
    await tester.pumpAndSettle();

    final savedMessages = jsonDecode(
      (await SharedPreferences.getInstance()).getString(
        'enlace.local_messages.v1',
      )!,
    ) as List<Object?>;
    final savedMessage = savedMessages.single! as Map<String, Object?>;
    expect(savedMessage['text'], contains('ROBO EN CASA'));
    expect(savedMessage['photoId'], 'a' * 32);
    expect(savedMessage['photoMimeType'], 'image/png');
    expect(savedMessage['photoBytes'], 1024);
  });

  testWidgets(
    'quick fire report includes GPS coordinates before confirmation',
    (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('org.comunidad.enlace/ble'),
            (call) async {
              if (call.method == 'getBackgroundMessages') return <String>[];
              if (call.method == 'getAutoStartDiagnostics') {
                return <String, Object>{
                  'status': 'Sin evento de arranque registrado.',
                  'timestamp': 0,
                  'autoStartEnabled': false,
                };
              }
              if (call.method == 'getCurrentGpsLocation') {
                return <String, Object>{
                  'latitude': 10.123456,
                  'longitude': -66.987654,
                  'accuracyMeters': 8.0,
                };
              }
              return null;
            },
          );
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('org.comunidad.enlace/ble'),
              null,
            ),
      );
      const permissionChannel = MethodChannel(
        'flutter.baseflow.com/permissions/methods',
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(permissionChannel, (call) async {
            if (call.method == 'requestPermissions') {
              final requested = call.arguments as List<Object?>;
              return {
                for (final permission in requested) permission! as int: 1,
              };
            }
            if (call.method == 'checkServiceStatus') return 1;
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(permissionChannel, null),
      );
      SharedPreferences.setMockInitialValues({'node_name': 'Casa norte'});
      await tester.pumpWidget(const EnlaceApp());
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.byKey(const Key('quick-report-fire')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('quick-report-fire')));
      await tester.pumpAndSettle();
      await tester.pumpAndSettle();
      expect(
        find.text('🔥 INCENDIO EN CASA\nGPS: 10.123456, -66.987654'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('confirm-quick-alert')));
      await tester.pumpAndSettle();

      expect(find.textContaining('🔥 INCENDIO EN CASA'), findsOneWidget);
      expect(find.textContaining('GUARDADO LOCAL'), findsOneWidget);
      expect(find.textContaining('Casa norte ·'), findsOneWidget);
      expect(find.textContaining('hora local del remitente'), findsOneWidget);
      final savedMessages = jsonDecode(
        (await SharedPreferences.getInstance()).getString(
          'enlace.local_messages.v1',
        )!,
      ) as List<Object?>;
      final savedMessage = savedMessages.single! as Map<String, Object?>;
      expect(savedMessage['senderName'], 'Casa norte');
      expect(
        savedMessage['senderLocalTime'],
        matches(RegExp(r'^\d{4}-\d{2}-\d{2} \d{2}:\d{2} UTC[+-]\d{2}:\d{2}$')),
      );
    },
  );

  testWidgets('clears all messages from local and native storage', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var nativeHistoryCleared = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('org.comunidad.enlace/ble'),
          (call) async {
            if (call.method == 'getBackgroundMessages') return <String>[];
            if (call.method == 'getAutoStartDiagnostics') {
              return <String, Object>{
                'status': 'Sin evento de arranque registrado.',
                'timestamp': 0,
                'autoStartEnabled': false,
              };
            }
            if (call.method == 'clearAllMessages') {
              nativeHistoryCleared = true;
              return null;
            }
            return null;
          },
        );
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('org.comunidad.enlace/ble'),
            null,
          ),
    );

    final now = DateTime.now().toUtc();
    SharedPreferences.setMockInitialValues({
      'enlace.local_messages.v1': jsonEncode([
        {
          'id': '0123456789abcdef0123456789abcdef',
          'text': 'Aviso recibido de prueba',
          'priority': 'normal',
          'createdAt': now.toIso8601String(),
          'expiresAt': now.add(const Duration(hours: 1)).toIso8601String(),
          'remainingHops': 4,
          'received': true,
        },
        {
          'id': '1123456789abcdef0123456789abcdef',
          'text': 'Aviso creado aquí',
          'priority': 'normal',
          'createdAt': now.toIso8601String(),
          'expiresAt': now.add(const Duration(hours: 1)).toIso8601String(),
          'remainingHops': 8,
          'received': false,
        },
      ]),
    });
    await tester.pumpWidget(const EnlaceApp());
    await tester.pumpAndSettle();

    await tester.drag(find.byType(CustomScrollView), const Offset(0, -1200));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('refresh-messages')), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('clear-all-messages')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('clear-all-messages')));
    await tester.pumpAndSettle();
    expect(find.text('Borrar todo'), findsNWidgets(2));
    expect(
      find.textContaining('¿Seguro deseas eliminar todo el historial?'),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('confirm-clear-all-messages')));
    await tester.pumpAndSettle();

    expect(nativeHistoryCleared, isTrue);
    expect(find.text('Aviso recibido de prueba'), findsNothing);
    expect(find.text('Aviso creado aquí'), findsNothing);
    final preferences = await SharedPreferences.getInstance();
    expect(
      jsonDecode(preferences.getString('enlace.local_messages.v1')!) as List,
      isEmpty,
    );
  });

  testWidgets('switches node mode and saves a local draft', (tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('org.comunidad.enlace/ble'),
          (call) async {
            if (call.method == 'getBackgroundMessages') return <String>[];
            if (call.method == 'getAutoStartDiagnostics') {
              return <String, Object>{
                'status': 'Sin evento de arranque registrado.',
                'timestamp': 0,
                'autoStartEnabled': false,
              };
            }
            return null;
          },
        );
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('org.comunidad.enlace/ble'),
            null,
          ),
    );
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const EnlaceApp());
    await tester.pumpAndSettle();

    expect(find.text('Nodo fijo'), findsWidgets);
    expect(find.text('NODO DETENIDO'), findsOneWidget);
    expect(find.text('Activar nodo Bluetooth'), findsOneWidget);

    expect(find.byKey(const Key('node-name-input')), findsNothing);
    await tester.ensureVisible(find.byKey(const Key('node-name-edit')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('node-name-edit')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('node-name-input')), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('node-name-input')),
      'Casa norte',
    );
    await tester.tap(find.byKey(const Key('save-node-name')));
    await tester.pumpAndSettle();
    expect(find.textContaining('verán “Casa norte”'), findsOneWidget);
    expect(
      (await SharedPreferences.getInstance()).getString('node_name'),
      'Casa norte',
    );

    await tester.ensureVisible(find.text('Teléfono personal'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Teléfono personal'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.text('Este teléfono está configurado para acompañarte.'),
    );
    await tester.pumpAndSettle();
    expect(
      find.text('Este teléfono está configurado para acompañarte.'),
      findsOneWidget,
    );

    await tester.ensureVisible(find.text('Aún no hay avisos'));
    await tester.pumpAndSettle();
    expect(find.text('Aún no hay avisos'), findsOneWidget);
    await tester.ensureVisible(find.text('Crear aviso'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Crear aviso'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('message-input')),
      'Necesitamos agua en el centro comunitario.',
    );
    await tester.tap(find.byKey(const Key('save-message')));
    await tester.pumpAndSettle();

    expect(
      find.text('Necesitamos agua en el centro comunitario.'),
      findsOneWidget,
    );
    expect(find.textContaining('GUARDADO LOCAL'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(const EnlaceApp());
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.text('Necesitamos agua en el centro comunitario.'),
    );
    await tester.pumpAndSettle();
    expect(
      find.text('Necesitamos agua en el centro comunitario.'),
      findsOneWidget,
    );
  });
}
