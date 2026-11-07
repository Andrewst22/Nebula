import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:telefonos_mesh/models/local_message.dart';
import 'package:telefonos_mesh/services/local_message_store.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('decrements hop limit and marks the message as received', () {
    final source = LocalMessage.create(
      text: 'Aviso de prueba',
      priority: MessagePriority.urgent,
    ).withSenderName('Casa norte');

    final forwarded = source.forForwarding();

    expect(forwarded.id, source.id);
    expect(forwarded.remainingHops, source.remainingHops - 1);
    expect(forwarded.received, isTrue);
    final decoded = LocalMessage.fromJson(forwarded.toJson());
    expect(decoded.id, source.id);
    expect(decoded.senderName, 'Casa norte');
    expect(decoded.senderLocalTime, source.senderLocalTime);
  });

  test('preserves a photo attachment through BLE-style forwarding', () {
    final source = LocalMessage.create(
      text: 'MASCOTA DESAPARECIDA',
      priority: MessagePriority.urgent,
      photoId: 'a' * 32,
      photoMimeType: 'image/jpeg',
      photoBytes: 1024,
    ).withSenderName('Casa norte');

    final forwarded = LocalMessage.fromJson(
      jsonDecode(source.forForwarding().encode()),
    );

    expect(forwarded.photoId, source.photoId);
    expect(forwarded.photoMimeType, 'image/jpeg');
    expect(forwarded.photoBytes, 1024);
    expect(forwarded.remainingHops, 7);
  });

  test('rejects photo attachments exceeding the five megabyte limit', () {
    final message = LocalMessage.create(
      text: 'MASCOTA DESAPARECIDA',
      priority: MessagePriority.urgent,
      photoId: 'b' * 32,
      photoMimeType: 'image/png',
      photoBytes: 5 * 1024 * 1024 + 1,
    );

    expect(
      () => LocalMessage.fromJson(message.toJson()),
      throwsFormatException,
    );
  });

  test(
    'keeps sender local time and supports older messages without metadata',
    () {
      final message = LocalMessage.create(
        text: 'Aviso de prueba',
        priority: MessagePriority.urgent,
        createdAt: DateTime(2026, 10, 17, 9, 22),
      ).withSenderName('Casa norte');

      expect(
        message.senderLocalTime,
        matches(RegExp(r'^2026-10-17 09:22 UTC[+-]\d{2}:\d{2}$')),
      );

      final legacyPayload = message.toJson()
        ..remove('senderName')
        ..remove('senderLocalTime');
      final legacyMessage = LocalMessage.fromJson(legacyPayload);
      expect(legacyMessage.senderName, isNull);
      expect(legacyMessage.senderLocalTime, isNull);
    },
  );

  test('stores a message only once by its id', () async {
    final preferences = await SharedPreferences.getInstance();
    final store = LocalMessageStore(preferences);
    final message = LocalMessage.create(
      text: 'Aviso de prueba',
      priority: MessagePriority.normal,
    );

    expect(await store.addIfNew(message), isTrue);
    expect(await store.addIfNew(message), isFalse);
    expect(store.loadMessages(), hasLength(1));
  });

  test('clears all messages, including locally created and received', () async {
    final preferences = await SharedPreferences.getInstance();
    final store = LocalMessageStore(preferences);
    final created = LocalMessage.create(
      text: 'Aviso creado aquí',
      priority: MessagePriority.normal,
    );
    final received = LocalMessage.create(
      text: 'Aviso recibido',
      priority: MessagePriority.urgent,
    ).receivedAtNode();
    await store.addIfNew(created);
    await store.addIfNew(received);

    await store.clearAllMessages();

    final remainingMessages = store.loadMessages();
    expect(remainingMessages, isEmpty);
  });

  test('serializes concurrent writes without losing messages', () async {
    final preferences = await SharedPreferences.getInstance();
    final store = LocalMessageStore(preferences);
    final messages = List.generate(
      10,
      (index) => LocalMessage.create(
        text: 'Aviso $index',
        priority: MessagePriority.normal,
      ),
    );

    final results = await Future.wait(messages.map(store.addIfNew));

    expect(results, everyElement(isTrue));
    expect(store.loadMessages(), hasLength(messages.length));
  });

  test('does not forward expired messages', () {
    final now = DateTime.now();
    final message = LocalMessage.create(
      text: 'Aviso de prueba',
      priority: MessagePriority.normal,
      createdAt: now.subtract(const Duration(days: 2)),
    );

    expect(message.isExpired, isTrue);
    expect(message.canForward, isFalse);
  });
}
