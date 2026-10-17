import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/local_message.dart';

class LocalMessageStore {
  LocalMessageStore(this._preferences);

  static const _storageKey = 'enlace.local_messages.v1';

  final SharedPreferences _preferences;
  Future<void> _mutationQueue = Future<void>.value();

  List<LocalMessage> loadMessages() {
    final encoded = _preferences.getString(_storageKey);
    if (encoded == null) return [];

    final decoded = jsonDecode(encoded);
    if (decoded is! List) {
      throw const FormatException('La lista local de avisos no es válida.');
    }

    final messages = decoded.map(LocalMessage.fromJson).toList();
    return messages.where((message) => !message.isExpired).toList();
  }

  Future<void> _saveMessages(List<LocalMessage> messages) async {
    final encoded = jsonEncode(
      messages.map((message) => message.toJson()).toList(),
    );
    final saved = await _preferences.setString(_storageKey, encoded);
    if (!saved) {
      throw StateError(
        'No se pudieron guardar los avisos en este dispositivo.',
      );
    }
  }

  Future<bool> addIfNew(LocalMessage message) {
    final result = Completer<bool>();
    _mutationQueue = _mutationQueue.then((_) async {
      try {
        final messages = loadMessages();
        if (messages.any((existing) => existing.id == message.id)) {
          result.complete(false);
          return;
        }
        await _saveMessages([message, ...messages.take(499)]);
        result.complete(true);
      } catch (error, stackTrace) {
        result.completeError(error, stackTrace);
      }
    });
    return result.future;
  }

  Future<void> clearAllMessages() {
    final result = Completer<void>();
    _mutationQueue = _mutationQueue.then((_) async {
      try {
        await _saveMessages([]);
        result.complete();
      } catch (error, stackTrace) {
        result.completeError(error, stackTrace);
      }
    });
    return result.future;
  }
}
