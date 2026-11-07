import 'dart:convert';
import 'dart:math';

enum MessagePriority { normal, urgent }

class LocalMessage {
  const LocalMessage({
    required this.id,
    required this.text,
    required this.priority,
    required this.createdAt,
    required this.expiresAt,
    required this.remainingHops,
    this.photoId,
    this.photoMimeType,
    this.photoBytes,
    this.senderName,
    this.senderLocalTime,
    this.received = false,
  });

  factory LocalMessage.create({
    required String text,
    required MessagePriority priority,
    DateTime? createdAt,
    String? photoId,
    String? photoMimeType,
    int? photoBytes,
  }) {
    final senderMoment = createdAt ?? DateTime.now();
    final now = senderMoment.toUtc();
    final random = Random.secure();
    final id = List<int>.generate(
      16,
      (_) => random.nextInt(256),
    ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
    return LocalMessage(
      id: id,
      text: text,
      priority: priority,
      createdAt: now,
      expiresAt: now.add(const Duration(hours: 24)),
      remainingHops: 8,
      photoId: photoId,
      photoMimeType: photoMimeType,
      photoBytes: photoBytes,
      senderLocalTime: _formatSenderLocalTime(senderMoment),
    );
  }

  factory LocalMessage.fromJson(Object? value) {
    if (value is! Map<String, dynamic>) {
      throw const FormatException(
        'El aviso guardado no tiene un formato válido.',
      );
    }
    final id = value['id'];
    final text = value['text'];
    final priorityName = value['priority'];
    final createdAtValue = value['createdAt'];
    final expiresAtValue = value['expiresAt'];
    final remainingHops = value['remainingHops'];
    final senderName = value['senderName'];
    final senderLocalTime = value['senderLocalTime'];
    final photoId = value['photoId'];
    final photoMimeType = value['photoMimeType'];
    final photoBytes = value['photoBytes'];
    final received = value['received'] ?? false;
    final createdAt = createdAtValue is String
        ? DateTime.tryParse(createdAtValue)
        : null;
    final expiresAt = expiresAtValue is String
        ? DateTime.tryParse(expiresAtValue)
        : null;
    final priority = priorityName is String
        ? MessagePriority.values.where((item) => item.name == priorityName)
        : const <MessagePriority>[];

    if (id is! String ||
        !RegExp(r'^[a-f0-9]{32}$').hasMatch(id) ||
        text is! String ||
        text.isEmpty ||
        text.length > 280 ||
        createdAt == null ||
        expiresAt == null ||
        !expiresAt.isAfter(createdAt) ||
        expiresAt.difference(createdAt) > const Duration(hours: 24) ||
        createdAt.isAfter(DateTime.now().add(const Duration(minutes: 5))) ||
        remainingHops is! int ||
        remainingHops < 0 ||
        (senderName != null &&
            (senderName is! String || senderName.length > 40)) ||
        (senderLocalTime != null &&
            (senderLocalTime is! String ||
                !RegExp(r'^\d{4}-\d{2}-\d{2} \d{2}:\d{2} UTC[+-]\d{2}:\d{2}$')
                    .hasMatch(senderLocalTime))) ||
        (photoId != null &&
            (photoId is! String ||
                !RegExp(r'^[a-f0-9]{32}$').hasMatch(photoId) ||
                photoBytes is! int ||
                photoBytes < 1 ||
                photoBytes > 5 * 1024 * 1024 ||
                photoMimeType is! String ||
                !const {'image/jpeg', 'image/png', 'image/webp'}
                    .contains(photoMimeType))) ||
        (photoId == null &&
            (photoMimeType != null || photoBytes != null)) ||
        received is! bool ||
        priority.isEmpty) {
      throw const FormatException(
        'El aviso guardado contiene datos inválidos.',
      );
    }

    return LocalMessage(
      id: id,
      text: text,
      priority: priority.first,
      createdAt: createdAt,
      expiresAt: expiresAt,
      remainingHops: remainingHops,
      photoId: photoId as String?,
      photoMimeType: photoMimeType as String?,
      photoBytes: photoBytes as int?,
      senderName: senderName as String?,
      senderLocalTime: senderLocalTime as String?,
      received: received,
    );
  }

  final String id;
  final String text;
  final MessagePriority priority;
  final DateTime createdAt;
  final DateTime expiresAt;
  final int remainingHops;
  final String? photoId;
  final String? photoMimeType;
  final int? photoBytes;
  final String? senderName;
  final String? senderLocalTime;
  final bool received;

  bool get isExpired => !expiresAt.isAfter(DateTime.now());
  bool get canForward => !isExpired && remainingHops > 1;

  LocalMessage receivedAtNode() => LocalMessage(
    id: id,
    text: text,
    priority: priority,
    createdAt: createdAt,
    expiresAt: expiresAt,
    remainingHops: remainingHops,
    photoId: photoId,
    photoMimeType: photoMimeType,
    photoBytes: photoBytes,
    senderName: senderName,
    senderLocalTime: senderLocalTime,
    received: true,
  );

  LocalMessage withSenderName(String name) => LocalMessage(
    id: id,
    text: text,
    priority: priority,
    createdAt: createdAt,
    expiresAt: expiresAt,
    remainingHops: remainingHops,
    photoId: photoId,
    photoMimeType: photoMimeType,
    photoBytes: photoBytes,
    senderName: name,
    senderLocalTime: senderLocalTime,
    received: received,
  );

  LocalMessage forForwarding() {
    if (!canForward) {
      throw StateError('Este aviso no puede reenviarse.');
    }
    return LocalMessage(
      id: id,
      text: text,
      priority: priority,
      createdAt: createdAt,
      expiresAt: expiresAt,
      remainingHops: remainingHops - 1,
      photoId: photoId,
      photoMimeType: photoMimeType,
      photoBytes: photoBytes,
      senderName: senderName,
      senderLocalTime: senderLocalTime,
      received: true,
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'text': text,
    'priority': priority.name,
    'createdAt': createdAt.toIso8601String(),
    'expiresAt': expiresAt.toIso8601String(),
    'remainingHops': remainingHops,
    'photoId': photoId,
    'photoMimeType': photoMimeType,
    'photoBytes': photoBytes,
    'senderName': senderName,
    'senderLocalTime': senderLocalTime,
    'received': received,
  };

  String encode() => jsonEncode(toJson());
}

String _formatSenderLocalTime(DateTime time) {
  final offset = time.timeZoneOffset;
  final sign = offset.isNegative ? '-' : '+';
  final absoluteOffset = offset.abs();
  final year = time.year.toString().padLeft(4, '0');
  final month = time.month.toString().padLeft(2, '0');
  final day = time.day.toString().padLeft(2, '0');
  final hour = time.hour.toString().padLeft(2, '0');
  final minute = time.minute.toString().padLeft(2, '0');
  final offsetHours = absoluteOffset.inHours.toString().padLeft(2, '0');
  final offsetMinutes = (absoluteOffset.inMinutes % 60).toString().padLeft(
    2,
    '0',
  );
  return '$year-$month-$day $hour:$minute UTC$sign$offsetHours:$offsetMinutes';
}
