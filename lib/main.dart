import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models/local_message.dart';
import 'services/ble_node_service.dart';
import 'services/local_message_store.dart';

void main() {
  runApp(const EnlaceApp());
}

class EnlaceApp extends StatefulWidget {
  const EnlaceApp({super.key});

  @override
  State<EnlaceApp> createState() => _EnlaceAppState();
}

class _EnlaceAppState extends State<EnlaceApp> {
  bool _darkMode = false;

  @override
  void initState() {
    super.initState();
    _loadThemePreference();
  }

  Future<void> _loadThemePreference() async {
    final preferences = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() => _darkMode = preferences.getBool('dark_mode') ?? false);
  }

  @override
  Widget build(BuildContext context) {
    const forest = Color(0xFF145B49);
    return MaterialApp(
      title: 'NEBULA',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: forest,
          primary: forest,
          surface: const Color(0xFFF7F8F5),
        ),
        scaffoldBackgroundColor: const Color(0xFFF7F8F5),
        useMaterial3: true,
        fontFamily: 'Roboto',
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: forest,
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xFF101714),
        useMaterial3: true,
        fontFamily: 'Roboto',
      ),
      themeMode: _darkMode ? ThemeMode.dark : ThemeMode.light,
      home: NetworkHomePage(
        darkMode: _darkMode,
        onDarkModeChanged: _setDarkMode,
      ),
    );
  }

  Future<void> _setDarkMode(bool enabled) async {
    final preferences = await SharedPreferences.getInstance();
    final saved = await preferences.setBool('dark_mode', enabled);
    if (!saved) {
      throw StateError('No se pudo guardar la preferencia del tema.');
    }
    if (mounted) setState(() => _darkMode = enabled);
  }
}

enum NodeMode { fixed, mobile }

class NetworkHomePage extends StatefulWidget {
  const NetworkHomePage({
    super.key,
    required this.darkMode,
    required this.onDarkModeChanged,
  });

  final bool darkMode;
  final Future<void> Function(bool) onDarkModeChanged;

  @override
  State<NetworkHomePage> createState() => _NetworkHomePageState();
}

class _NetworkHomePageState extends State<NetworkHomePage> {
  NodeMode _mode = NodeMode.fixed;
  LocalMessageStore? _messageStore;
  final BleNodeService _bleNodeService = BleNodeService();
  StreamSubscription<BleNodeSnapshot>? _bleSubscription;
  String? _storageError;
  String? _bleError;
  String? _transferStatus;
  List<NearbyNode> _nearbyNodes = [];
  bool _loadingMessages = true;
  bool _refreshingMessages = false;
  bool _bleActive = false;
  bool _bleStarting = false;
  bool _autoStartFixedNode = false;
  bool _savingNodeName = false;
  bool _clearingReceivedMessages = false;
  bool _sendingQuickAlert = false;
  bool _savingThemePreference = false;
  bool _seismicAlarmEnabled = false;
  bool _seismicAlarmMonitoring = false;
  bool _seismicAlarmTriggered = false;
  bool _savingSeismicAlarm = false;
  String _nodeName = 'NEBULA';
  String? _autoStartDiagnostic;
  String? _seismicAlarmError;
  final List<LocalMessage> _messages = [];
  final Set<String> _processingMessageIds = {};

  @override
  void initState() {
    super.initState();
    _initializeMessageStore();
  }

  @override
  void dispose() {
    _bleSubscription?.cancel();
    super.dispose();
  }

  Future<void> _editNodeName() async {
    final name = await showDialog<String>(
      context: context,
      builder: (context) => _EditNodeNameDialog(initialName: _nodeName),
    );
    if (name == null || !mounted) return;
    await _saveNodeName(name);
  }

  Future<void> _changeDarkMode(bool enabled) async {
    if (_savingThemePreference || enabled == widget.darkMode) return;
    setState(() => _savingThemePreference = true);
    try {
      await widget.onDarkModeChanged(enabled);
    } on StateError catch (error) {
      if (mounted) _showStorageError(error.message);
    } finally {
      if (mounted) setState(() => _savingThemePreference = false);
    }
  }

  Future<void> _saveNodeName(String value) async {
    final name = value.trim();
    if (name.isEmpty || utf8.encode(name).length > 12) {
      _showTransferStatus(
        'Escribe un nombre de 1 a 12 bytes UTF-8 para anunciarlo por BLE.',
      );
      return;
    }
    setState(() => _savingNodeName = true);
    try {
      await _bleNodeService.setNodeName(name);
      final preferences = await SharedPreferences.getInstance();
      final saved = await preferences.setString('node_name', name);
      if (!saved) {
        _showTransferStatus(
          'Android actualizó el nombre BLE, pero no se pudo guardar en la app.',
        );
        return;
      }
      if (!mounted) return;
      setState(() => _nodeName = name);
      _showTransferStatus(
        'Nombre "$name" guardado y anunciado a los teléfonos cercanos.',
      );
    } on PlatformException catch (error) {
      if (mounted) {
        _showTransferStatus(
          error.message ?? 'No se pudo guardar el nombre del nodo.',
        );
      }
    } finally {
      if (mounted) setState(() => _savingNodeName = false);
    }
  }

  Future<void> _toggleBleNode() async {
    if (_bleStarting) return;
    setState(() {
      _bleStarting = true;
      _bleError = null;
    });
    try {
      if (_bleActive) {
        await _bleNodeService.stop();
        if (!mounted) return;
        setState(() {
          _bleActive = false;
          _nearbyNodes = [];
          _bleStarting = false;
        });
        return;
      }

      await _startNodeService();
      if (!mounted) return;
      setState(() => _bleStarting = false);
    } on PlatformException catch (error) {
      if (!mounted) return;
      setState(() {
        _bleStarting = false;
        _bleActive = false;
        _bleError = error.message ?? 'No se pudo iniciar el nodo Bluetooth.';
      });
    } on FormatException catch (error) {
      if (!mounted) return;
      setState(() {
        _bleStarting = false;
        _bleActive = false;
        _bleError = error.message;
      });
    }
  }

  Future<void> _startNodeService() async {
    _bleSubscription ??= _bleNodeService.snapshots.listen(
      _handleBleSnapshot,
      onError: (Object error) {
        if (!mounted) return;
        setState(() {
          _bleActive = false;
          _bleError = error is PlatformException
              ? error.message ?? 'Falló el servicio Bluetooth.'
              : error.toString();
        });
      },
    );
    await _bleNodeService.start();
  }

  Future<void> _setMode(NodeMode mode) async {
    if (mode == NodeMode.mobile && _seismicAlarmEnabled) {
      final disabled = await _setSeismicAlarmEnabled(false);
      if (!disabled) return;
    }
    final preferences = await SharedPreferences.getInstance();
    final saved = await preferences.setString('node_mode', mode.name);
    if (!saved) {
      _showStorageError('No se pudo guardar el modo de este teléfono.');
      return;
    }
    if (!mounted) return;
    setState(() => _mode = mode);
    if (mode == NodeMode.mobile && _autoStartFixedNode) {
      await _setAutoStart(false);
    }
  }

  Future<void> _setAutoStart(bool enabled) async {
    if (_mode != NodeMode.fixed && enabled) return;
    if (enabled) {
      try {
        final granted = await _bleNodeService.requestNotificationPermission();
        if (!granted) {
          _showTransferStatus(
            'Concede permiso de notificaciones para activar el nodo fijo.',
          );
          return;
        }
      } on PlatformException catch (error) {
        _showTransferStatus(
          error.message ?? 'No se pudo solicitar permiso de notificaciones.',
        );
        return;
      }
    }
    final preferences = await SharedPreferences.getInstance();
    final saved = await preferences.setBool('auto_start_fixed_node', enabled);
    if (!saved) {
      _showStorageError('No se pudo guardar el inicio automático.');
      return;
    }
    if (!mounted) return;
    setState(() {
      _autoStartFixedNode = enabled;
      _autoStartDiagnostic = enabled
          ? 'Preferencia guardada. Reinicia el teléfono para comprobar el receptor.'
          : 'Inicio automático desactivado.';
    });
    if (enabled && !_bleActive) {
      setState(() => _bleStarting = true);
      try {
        await _startNodeService();
        if (mounted) setState(() => _bleStarting = false);
      } on PlatformException catch (error) {
        if (!mounted) return;
        setState(() {
          _bleStarting = false;
          _bleError = error.message ?? 'No se pudo iniciar el nodo fijo.';
        });
      }
    } else if (!enabled && _bleActive) {
      await _bleNodeService.stop();
      if (mounted) {
        setState(() {
          _bleActive = false;
          _nearbyNodes = [];
        });
      }
    }
  }

  Future<bool> _setSeismicAlarmEnabled(bool enabled) async {
    if (_savingSeismicAlarm || (_mode != NodeMode.fixed && enabled)) {
      return false;
    }
    setState(() => _savingSeismicAlarm = true);
    try {
      if (enabled && !_bleActive) {
        await _startNodeService();
      }
      final preferences = await SharedPreferences.getInstance();
      final saved = await preferences.setBool('seismic_alarm_enabled', enabled);
      if (!saved) {
        throw StateError('No se pudo guardar la alarma experimental.');
      }
      await _bleNodeService.setSeismicAlarmEnabled(enabled);
      if (!mounted) return false;
      setState(() {
        _seismicAlarmEnabled = enabled;
        if (!enabled) {
          _seismicAlarmMonitoring = false;
          _seismicAlarmTriggered = false;
          _seismicAlarmError = null;
        } else if (_bleActive) {
          _seismicAlarmMonitoring = true;
        }
      });
      _showTransferStatus(
        enabled
            ? 'Alarma experimental activada. El nodo debe permanecer encendido.'
            : 'Alarma experimental desactivada.',
      );
      return true;
    } on PlatformException catch (error) {
      if (mounted) {
        _showTransferStatus(
          error.message ?? 'No se pudo actualizar la alarma experimental.',
        );
      }
      return false;
    } on StateError catch (error) {
      if (mounted) _showStorageError(error.message);
      return false;
    } finally {
      if (mounted) setState(() => _savingSeismicAlarm = false);
    }
  }

  Future<void> _initializeMessageStore() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      final store = LocalMessageStore(preferences);
      final messages = store.loadMessages();
      final backgroundPayloads = await _bleNodeService.loadBackgroundMessages();
      final backgroundMessages = backgroundPayloads
          .map((payload) => LocalMessage.fromJson(jsonDecode(payload)))
          .where((message) => !message.isExpired)
          .toList();
      for (final message in backgroundMessages) {
        await store.addIfNew(message);
      }
      final savedMode = preferences.getString('node_mode');
      final mode = NodeMode.values.where((item) => item.name == savedMode);
      final autoStart = preferences.getBool('auto_start_fixed_node') ?? false;
      final seismicAlarmEnabled =
          preferences.getBool('seismic_alarm_enabled') ?? false;
      final savedNodeName = preferences.getString('node_name') ?? 'NEBULA';
      String? autoStartDiagnostic;
      try {
        final diagnostic = await _bleNodeService.getAutoStartDiagnostics();
        final timestamp = diagnostic['timestamp']! as int;
        final status = diagnostic['status']! as String;
        autoStartDiagnostic = timestamp == 0
            ? status
            : '$status (${DateTime.fromMillisecondsSinceEpoch(timestamp).toLocal()})';
      } on PlatformException catch (error) {
        autoStartDiagnostic =
            error.message ?? 'No se pudo consultar el arranque automático.';
      }
      if (!mounted) return;
      setState(() {
        _nodeName = savedNodeName;
        _messageStore = store;
        final allMessages = <String, LocalMessage>{};
        for (final message in [...messages, ...backgroundMessages]) {
          allMessages.putIfAbsent(message.id, () => message);
        }
        _messages.addAll(allMessages.values);
        _mode = mode.isEmpty ? NodeMode.fixed : mode.first;
        _autoStartFixedNode = _mode == NodeMode.fixed && autoStart;
        _seismicAlarmEnabled = _mode == NodeMode.fixed && seismicAlarmEnabled;
        _seismicAlarmMonitoring =
            _mode == NodeMode.fixed && autoStart && seismicAlarmEnabled;
        _autoStartDiagnostic = autoStartDiagnostic;
        _loadingMessages = false;
      });
      if (_autoStartFixedNode) {
        setState(() => _bleStarting = true);
        try {
          await _startNodeService();
          if (mounted) setState(() => _bleStarting = false);
        } on PlatformException catch (error) {
          if (mounted) {
            setState(() {
              _bleStarting = false;
              _bleError = error.message ?? 'No se pudo reanudar el nodo fijo.';
            });
          }
        }
      }
    } on FormatException catch (error) {
      if (!mounted) return;
      setState(() {
        _storageError = 'No se pudieron leer los avisos guardados: $error';
        _loadingMessages = false;
      });
    } on PlatformException catch (error) {
      if (!mounted) return;
      setState(() {
        _storageError = 'Falló el almacenamiento local: ${error.message}';
        _loadingMessages = false;
      });
    }
  }

  Future<void> _composeMessage() async {
    final message = await showModalBottomSheet<LocalMessage>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (context) => const ComposeMessageSheet(),
    );
    if (message == null || !mounted) return;
    await _saveAndShareMessage(message);
  }

  Future<void> _saveAndShareMessage(LocalMessage message) async {
    final attributedMessage = message.withSenderName(_nodeName);
    try {
      final added = await _messageStore!.addIfNew(attributedMessage);
      if (!added) return;
      if (!mounted) return;
      setState(() {
        _messages.insert(0, attributedMessage);
        if (_messages.length > 500) _messages.removeLast();
      });
      if (attributedMessage.photoId != null) {
        try {
          await _bleNodeService.enqueuePhoto(
            attributedMessage.photoId!,
            attributedMessage.encode(),
          );
        } on PlatformException catch (error) {
          _showTransferStatus(
            'Reporte guardado, pero no se puso la foto en cola: '
            '${error.message ?? 'error de almacenamiento'}.',
          );
          return;
        }
      }
      if (_bleActive) {
        await _broadcastMessage(attributedMessage);
      } else {
        _showTransferStatus(
          'Aviso guardado. Activa BLE para compartirlo con nodos cercanos.',
        );
      }
    } on StateError catch (error) {
      _showStorageError(error.message);
    } on PlatformException catch (error) {
      _showStorageError(error.message ?? 'Falló el almacenamiento local.');
    }
  }

  Future<void> _requestHelpWithLocation() async {
    if (_sendingQuickAlert) return;
    setState(() => _sendingQuickAlert = true);
    try {
      final location = await _bleNodeService.getCurrentGpsLocation();
      if (!mounted) return;
      final text = '🆘 PIDO AYUDA\nGPS: ${location.coordinates}';
      final confirmed = await _confirmQuickAlert(
        title: 'Confirmar solicitud de ayuda',
        text: text,
        accuracyMeters: location.accuracyMeters,
      );
      if (confirmed && mounted) {
        await _saveAndShareMessage(
          LocalMessage.create(text: text, priority: MessagePriority.urgent),
        );
      }
    } on PlatformException catch (error) {
      if (mounted) {
        _showQuickAlertError(
          error.message ?? 'No se pudo obtener la ubicación GPS.',
        );
      }
    } finally {
      if (mounted) setState(() => _sendingQuickAlert = false);
    }
  }

  Future<void> _reportHomeIncident({
    required String title,
    required String alertText,
    bool allowEvidencePhoto = false,
  }) async {
    if (_sendingQuickAlert) return;
    setState(() => _sendingQuickAlert = true);
    try {
      PhotoAttachment? photo;
      if (allowEvidencePhoto) {
        final selection = await showDialog<_IncidentEvidenceSelection>(
          context: context,
          builder: (context) => const _IncidentEvidenceDialog(),
        );
        if (selection == null || !mounted) return;
        photo = selection.photo;
      }
      final location = await _bleNodeService.getCurrentGpsLocation();
      if (!mounted) return;
      final text = _formatIncidentAlert(alertText, location);
      final confirmed = await _confirmQuickAlert(
        title: 'Confirmar alerta',
        text: text,
        accuracyMeters: location.accuracyMeters,
        photoIncluded: photo != null,
      );
      if (confirmed && mounted) {
        await _saveAndShareMessage(
          LocalMessage.create(
            text: text,
            priority: MessagePriority.urgent,
            photoId: photo?.id,
            photoMimeType: photo?.mimeType,
            photoBytes: photo?.bytes,
          ),
        );
      }
    } on PlatformException catch (error) {
      if (mounted) {
        _showQuickAlertError(
          error.message ?? 'No se pudo obtener la ubicación GPS.',
        );
      }
    } finally {
      if (mounted) setState(() => _sendingQuickAlert = false);
    }
  }

  Future<void> _reportMissingPerson() async {
    await _reportMissing(
      isPet: false,
      title: 'Reportar familiar desaparecido',
      alertTitle: 'PERSONA DESAPARECIDA',
    );
  }

  Future<void> _reportMissingPet() async {
    await _reportMissing(
      isPet: true,
      title: 'Reportar mascota desaparecida',
      alertTitle: 'MASCOTA DESAPARECIDA',
    );
  }

  Future<void> _reportMissing({
    required bool isPet,
    required String title,
    required String alertTitle,
  }) async {
    if (_sendingQuickAlert) return;
    final details = await showDialog<_MissingReportDetails>(
      context: context,
      builder: (context) => _MissingReportDialog(isPet: isPet, title: title),
    );
    if (details == null || !mounted) return;

    final text = _formatMissingReport(alertTitle, details);
    if (text.length > 280) {
      _showQuickAlertError(
        'El reporte supera el límite de 280 caracteres. Acorta los detalles.',
      );
      return;
    }
    final confirmed = await _confirmQuickAlert(
      title: 'Confirmar reporte',
      text: text,
      photoIncluded: details.photo != null,
    );
    if (confirmed && mounted) {
      await _saveAndShareMessage(
        LocalMessage.create(
          text: text,
          priority: MessagePriority.urgent,
          photoId: details.photo?.id,
          photoMimeType: details.photo?.mimeType,
          photoBytes: details.photo?.bytes,
        ),
      );
    }
  }

  String _formatMissingReport(
    String alertTitle,
    _MissingReportDetails details,
  ) {
    final fields = <String>[
      if (details.category != null) details.category!,
      if (details.name.isNotEmpty) 'Nombre: ${details.name}',
      'Visto: ${details.lastSeen}',
      if (details.clothing.isNotEmpty) 'Vestía: ${details.clothing}',
      if (details.breed.isNotEmpty) 'Raza: ${details.breed}',
      'Rasgos: ${details.characteristics}',
    ];
    return '$alertTitle | ${fields.join(' | ')}';
  }

  String _formatIncidentAlert(String alertText, CurrentGpsLocation location) {
    return '$alertText\nGPS: ${location.coordinates}';
  }

  Future<bool> _confirmQuickAlert({
    required String title,
    required String text,
    double? accuracyMeters,
    bool photoIncluded = false,
  }) async {
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(title),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Revisa el aviso antes de compartirlo. Los nodos BLE '
                    'pueden retransmitirlo a otros teléfonos; no se contacta '
                    'automáticamente a emergencias.',
                  ),
                  if (photoIncluded) ...[
                    const SizedBox(height: 10),
                    const Text(
                      'La foto también se compartirá con los nodos NEBULA '
                      'cercanos y podrá reenviarse durante 24 horas. No es '
                      'privada y puede tardar en llegar.',
                    ),
                  ],
                  const SizedBox(height: 12),
                  SelectableText(text),
                  if (accuracyMeters != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      'Precisión GPS aproximada: ±${accuracyMeters.round()} m.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancelar'),
              ),
              FilledButton(
                key: const Key('confirm-quick-alert'),
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Compartir por NEBULA'),
              ),
            ],
          ),
        ) ??
        false;
  }

  void _showQuickAlertError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: const Color(0xFFAE4A35),
      ),
    );
  }

  void _handleBleSnapshot(BleNodeSnapshot snapshot) {
    if (!mounted) return;
    setState(() {
      if (snapshot.active != null) _bleActive = snapshot.active!;
      if (snapshot.peers != null) _nearbyNodes = snapshot.peers!;
      if (snapshot.active == true) _bleError = null;
      if (snapshot.error != null) _bleError = snapshot.error;
      if (snapshot.transferStatus != null) {
        _transferStatus = snapshot.transferStatus;
      }
      if (snapshot.wifiTransferStatus != null) {
        _transferStatus = snapshot.wifiTransferStatus;
      }
      if (snapshot.seismicAlarmMonitoring != null) {
        _seismicAlarmMonitoring = snapshot.seismicAlarmMonitoring!;
        if (snapshot.seismicAlarmMonitoring!) _seismicAlarmError = null;
      }
      if (snapshot.seismicAlarmTriggered != null) {
        _seismicAlarmTriggered = snapshot.seismicAlarmTriggered!;
      }
      if (snapshot.seismicAlarmError != null) {
        _seismicAlarmError = snapshot.seismicAlarmError;
        _seismicAlarmMonitoring = false;
      }
    });
    final payload = snapshot.receivedPayload;
    if (payload != null) {
      unawaited(_handleIncomingMessage(payload));
    }
  }

  Future<void> _handleIncomingMessage(String payload) async {
    LocalMessage? message;
    try {
      message = LocalMessage.fromJson(jsonDecode(payload));
      if (message.isExpired || _messageStore == null) return;
      if (!_processingMessageIds.add(message.id)) return;
      final received = message.canForward
          ? message.forForwarding()
          : message.receivedAtNode();
      final added = await _messageStore!.addIfNew(received);
      if (!added || !mounted) return;
      setState(() {
        _messages.insert(0, received);
        if (_messages.length > 500) _messages.removeLast();
      });
    } on FormatException catch (error) {
      if (mounted) {
        setState(
          () => _bleError = 'Se descartó un mensaje BLE inválido: $error',
        );
      }
    } on StateError catch (error) {
      if (mounted) {
        setState(
          () => _storageError = 'No se guardó un aviso recibido: $error',
        );
      }
    } on PlatformException catch (error) {
      if (mounted) {
        setState(() {
          _bleError = error.message ?? 'No se pudo procesar un aviso recibido.';
        });
      }
    } finally {
      if (message != null) _processingMessageIds.remove(message.id);
    }
  }

  Future<void> _refreshMessages() async {
    if (_loadingMessages || _refreshingMessages || _clearingReceivedMessages) {
      return;
    }
    setState(() => _refreshingMessages = true);
    try {
      if (_bleActive) {
        await _bleNodeService.refreshScan();
      } else {
        await _startNodeService();
      }

      final backgroundPayloads = await _bleNodeService.loadBackgroundMessages();
      final store = _messageStore;
      if (store == null) {
        throw StateError('El almacenamiento de mensajes aún no está listo.');
      }
      final backgroundMessages = backgroundPayloads
          .map((payload) => LocalMessage.fromJson(jsonDecode(payload)))
          .where((message) => !message.isExpired)
          .toList();
      for (final message in backgroundMessages) {
        await store.addIfNew(message);
      }

      final messagesById = <String, LocalMessage>{
        for (final message in _messages)
          if (!message.isExpired) message.id: message,
        for (final message in store.loadMessages())
          if (!message.isExpired) message.id: message,
      };
      final refreshedMessages = messagesById.values.toList()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
      if (!mounted) return;
      setState(() {
        _messages
          ..clear()
          ..addAll(refreshedMessages);
        _bleError = null;
        _storageError = null;
      });
      _showTransferStatus(
        'Búsqueda BLE actualizada; se sincronizaron los mensajes guardados.',
      );
    } on FormatException catch (error) {
      if (mounted) {
        setState(() {
          _storageError = 'No se pudieron actualizar los mensajes: $error';
        });
      }
    } on StateError catch (error) {
      if (mounted) _showStorageError(error.message);
    } on PlatformException catch (error) {
      if (mounted) {
        setState(() {
          _bleError = error.message ?? 'No se pudo buscar mensajes nuevos.';
        });
      }
    } finally {
      if (mounted) setState(() => _refreshingMessages = false);
    }
  }

  Future<void> _broadcastMessage(
    LocalMessage message, {
    String? excludedAddress,
  }) async {
    try {
      final recipients = await _bleNodeService.broadcast(
        message.encode(),
        excludedAddress: excludedAddress,
      );
      if (!mounted) return;
      _showTransferStatus(
        recipients == 0
            ? 'Aviso guardado; no hay vecinos BLE disponibles ahora.'
            : 'Transferencia iniciada hacia $recipients vecino(s). '
                  'Aún no hay confirmación de lectura.',
      );
    } on PlatformException catch (error) {
      if (!mounted) return;
      setState(() {
        _bleError = error.message ?? 'No se pudo transmitir el aviso.';
      });
      _showTransferStatus(
        error.message ?? 'Aviso guardado localmente; transmisión fallida.',
      );
    }
  }

  Future<void> _retryWifiDirect() async {
    try {
      await _bleNodeService.startPhotoTransport();
    } on PlatformException catch (error) {
      _showTransferStatus(
        error.message ?? 'No se pudo activar el transporte de fotos.',
      );
    }
  }

  Future<void> _openWifiSettings() async {
    try {
      await _bleNodeService.openWifiSettings();
    } on PlatformException catch (error) {
      _showTransferStatus(
        error.message ?? 'No se pudieron abrir los ajustes de Wi-Fi.',
      );
    }
  }

  Future<void> _confirmClearAllMessages() async {
    final messageCount = _messages.length;
    if (messageCount == 0 || _clearingReceivedMessages) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Borrar todo'),
        content: Text(
          '¿Seguro deseas eliminar todo el historial? Se borrarán '
          '$messageCount mensajes de este dispositivo, incluidos los que '
          'recibiste y los que creaste aquí. También se eliminarán las fotos '
          'guardadas para retransmisión.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            key: const Key('confirm-clear-all-messages'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Sí, borrar todo'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _clearingReceivedMessages = true);
    try {
      await _bleNodeService.clearAllBackgroundMessages();
      await _messageStore!.clearAllMessages();
      if (!mounted) return;
      setState(() {
        _messages.clear();
      });
      _showTransferStatus(
        'Se borraron todos los mensajes de este dispositivo.',
      );
    } on PlatformException catch (error) {
      if (mounted) {
        _showReceivedHistoryError(
          error.message ?? 'No se pudo borrar el historial recibido.',
        );
      }
    } on StateError catch (error) {
      if (mounted) _showReceivedHistoryError(error.message);
    } finally {
      if (mounted) setState(() => _clearingReceivedMessages = false);
    }
  }

  void _showTransferStatus(String message) {
    if (!mounted) return;
    setState(() => _transferStatus = message);
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  void _showStorageError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('No se guardó el aviso: $message'),
        backgroundColor: const Color(0xFFAE4A35),
      ),
    );
  }

  void _showReceivedHistoryError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('No se borró el historial recibido: $message'),
        backgroundColor: const Color(0xFFAE4A35),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isFixed = _mode == NodeMode.fixed;
    return Scaffold(
      body: SafeArea(
        child: CustomScrollView(
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(22, 20, 22, 32),
              sliver: SliverList(
                delegate: SliverChildListDelegate([
                  _TopBar(onInfo: _showPrototypeInfo),
                  const SizedBox(height: 26),
                  const _PrototypeNotice(),
                  const SizedBox(height: 24),
                  _NetworkStatusCard(
                    isFixed: isFixed,
                    isActive: _bleActive,
                    peerCount: _nearbyNodes.length,
                  ),
                  const SizedBox(height: 13),
                  FilledButton.icon(
                    onPressed:
                        _bleStarting ||
                            _loadingMessages ||
                            _storageError != null
                        ? null
                        : _toggleBleNode,
                    icon: _bleStarting
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : Icon(
                            _bleActive
                                ? Icons.stop_circle_outlined
                                : Icons.bluetooth_searching_rounded,
                          ),
                    label: Text(
                      _bleStarting
                          ? 'Iniciando Bluetooth…'
                          : _bleActive
                          ? 'Detener nodo'
                          : 'Activar nodo Bluetooth',
                    ),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(51),
                      backgroundColor: _bleActive
                          ? const Color(0xFFAE4A35)
                          : const Color(0xFF145B49),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(15),
                      ),
                    ),
                  ),
                  if (_bleError != null) ...[
                    const SizedBox(height: 10),
                    _BleErrorCard(message: _bleError!),
                  ],
                  const SizedBox(height: 10),
                  _NearbyNodesCard(
                    isActive: _bleActive,
                    nodes: _nearbyNodes,
                    transferStatus: _transferStatus,
                    onRetryWifiDirect: _retryWifiDirect,
                    onOpenWifiSettings: _openWifiSettings,
                  ),
                  const SizedBox(height: 16),
                  _QuickHelpActionsCard(
                    busy: _sendingQuickAlert,
                    onRequestHelp: _requestHelpWithLocation,
                    onReportFire: () => _reportHomeIncident(
                      title: 'Reportar incendio en casa',
                      alertText: '🔥 INCENDIO EN CASA',
                    ),
                    onReportRobbery: () => _reportHomeIncident(
                      title: 'Reportar un robo en casa',
                      alertText: '🚨 ROBO EN CASA',
                      allowEvidencePhoto: true,
                    ),
                    onReportMissingPerson: _reportMissingPerson,
                    onReportMissingPet: _reportMissingPet,
                  ),
                  const SizedBox(height: 28),
                  const _SectionHeading(
                    title: 'Este dispositivo',
                    subtitle: 'Elige cómo participa en la comunidad',
                  ),
                  const SizedBox(height: 14),
                  _ModeSelector(mode: _mode, onChanged: _setMode),
                  const SizedBox(height: 10),
                  _ThemePreferenceCard(
                    darkMode: widget.darkMode,
                    saving: _savingThemePreference,
                    onChanged: _changeDarkMode,
                  ),
                  const SizedBox(height: 10),
                  _NodeNameEditor(
                    nodeName: _nodeName,
                    saving: _savingNodeName,
                    onEdit: _editNodeName,
                  ),
                  const SizedBox(height: 10),
                  _FixedStartupOption(
                    visible: isFixed,
                    enabled: _autoStartFixedNode,
                    diagnostic: _autoStartDiagnostic,
                    onChanged: _setAutoStart,
                  ),
                  if (isFixed) ...[
                    const SizedBox(height: 10),
                    _SeismicAlarmPreferenceCard(
                      enabled: _seismicAlarmEnabled,
                      monitoring: _seismicAlarmMonitoring,
                      triggered: _seismicAlarmTriggered,
                      saving: _savingSeismicAlarm,
                      error: _seismicAlarmError,
                      nodeActive: _bleActive,
                      autoStart: _autoStartFixedNode,
                      onChanged: (enabled) {
                        unawaited(_setSeismicAlarmEnabled(enabled));
                      },
                    ),
                  ],
                  const SizedBox(height: 24),
                  _NodeDetailsCard(
                    isFixed: isFixed,
                    peerCount: _nearbyNodes.length,
                  ),
                  const SizedBox(height: 28),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      const _SectionHeading(
                        title: 'Avisos',
                        subtitle: 'Mensajes creados y recibidos por la red',
                      ),
                      Text(
                        '${_messages.length}',
                        style: Theme.of(context).textTheme.labelLarge?.copyWith(
                          color: const Color(0xFF64736D),
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      TextButton.icon(
                        key: const Key('refresh-messages'),
                        onPressed:
                            _refreshingMessages ||
                                _loadingMessages ||
                                _clearingReceivedMessages ||
                                _bleStarting
                            ? null
                            : _refreshMessages,
                        icon: _refreshingMessages
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.refresh_rounded),
                        label: Text(
                          _refreshingMessages ? 'Buscando…' : 'Recargar',
                        ),
                      ),
                      TextButton.icon(
                        key: const Key('clear-all-messages'),
                        onPressed:
                            _messages.isNotEmpty &&
                                !_clearingReceivedMessages &&
                                !_loadingMessages
                            ? _confirmClearAllMessages
                            : null,
                        icon: _clearingReceivedMessages
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.delete_outline_rounded),
                        label: Text(
                          _clearingReceivedMessages
                              ? 'Borrando…'
                              : 'Borrar todo',
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  if (_storageError != null)
                    _StorageErrorCard(message: _storageError!)
                  else if (_loadingMessages)
                    const _LoadingMessagesCard()
                  else if (_messages.isEmpty)
                    const _EmptyMessagesCard()
                  else
                    ..._messages.map(
                      (message) => Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: _MessageCard(
                          message: message,
                          wifiTransferStatus: _transferStatus,
                          onOpenWifiSettings: _openWifiSettings,
                        ),
                      ),
                    ),
                  const SizedBox(height: 18),
                  FilledButton.icon(
                    onPressed: _loadingMessages || _storageError != null
                        ? null
                        : _composeMessage,
                    icon: const Icon(Icons.edit_note_rounded),
                    label: const Text('Crear aviso'),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(54),
                      textStyle: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Los avisos se guardan en este teléfono y se transmiten '
                    'sin cifrar. No hay confirmación de lectura.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      fontSize: 12,
                      height: 1.45,
                    ),
                  ),
                ]),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showPrototypeInfo() {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.info_outline_rounded),
        title: const Text('Sobre este prototipo'),
        content: const Text(
          'Los teléfonos pueden descubrirse y transferirse avisos por GATT '
          'BLE mientras la app está abierta. Los mensajes se reenvían con '
          'límite de saltos, pero todavía no hay cifrado ni servicio de '
          'repetición en segundo plano.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Entendido'),
          ),
        ],
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({required this.onInfo});

  final VoidCallback onInfo;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 46,
          height: 46,
          decoration: BoxDecoration(
            color: const Color(0xFFE2F0E9),
            borderRadius: BorderRadius.circular(15),
          ),
          child: const Icon(
            Icons.hub_rounded,
            color: Color(0xFF145B49),
            size: 25,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'NEBULA',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.7,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                'Red comunitaria',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: const Color(0xFF1B2E27),
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
        IconButton(
          tooltip: 'Información del prototipo',
          onPressed: onInfo,
          icon: const Icon(Icons.help_outline_rounded),
          color: const Color(0xFF53655D),
        ),
      ],
    );
  }
}

class _PrototypeNotice extends StatelessWidget {
  const _PrototypeNotice();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF4DD),
        borderRadius: BorderRadius.circular(13),
        border: Border.all(color: const Color(0xFFF1D99E)),
      ),
      child: const Row(
        children: [
          Icon(Icons.construction_rounded, size: 18, color: Color(0xFF815B12)),
          SizedBox(width: 9),
          Expanded(
            child: Text(
              'BLE GATT transmite avisos y los nodos pueden reenviarlos',
              style: TextStyle(
                color: Color(0xFF715210),
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _NetworkStatusCard extends StatelessWidget {
  const _NetworkStatusCard({
    required this.isFixed,
    required this.isActive,
    required this.peerCount,
  });

  final bool isFixed;
  final bool isActive;
  final int peerCount;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(21),
      decoration: BoxDecoration(
        color: const Color(0xFF145B49),
        borderRadius: BorderRadius.circular(23),
        boxShadow: const [
          BoxShadow(
            color: Color(0x24145B49),
            blurRadius: 22,
            offset: Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 9,
                height: 9,
                decoration: BoxDecoration(
                  color: isActive
                      ? const Color(0xFF79D6A8)
                      : const Color(0xFFFFCF70),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                isActive ? 'BLE ACTIVO' : 'NODO DETENIDO',
                style: TextStyle(
                  color: Color(0xFFD6E8DF),
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.1,
                ),
              ),
              const Spacer(),
              const Icon(
                Icons.bluetooth_searching_rounded,
                color: Color(0xFFD6E8DF),
                size: 20,
              ),
            ],
          ),
          const SizedBox(height: 22),
          Text(
            isFixed ? 'Nodo fijo' : 'Nodo móvil',
            style: TextStyle(
              color: Theme.of(context).colorScheme.surface,
              fontSize: 25,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            isFixed
                ? 'Este teléfono está configurado como nodo de casa.'
                : 'Este teléfono está configurado para acompañarte.',
            style: TextStyle(
              color: Color(0xFFD6E8DF),
              fontSize: 13,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 20),
          const Divider(color: Color(0x557DB29F), height: 1),
          const SizedBox(height: 14),
          Row(
            children: [
              Icon(
                isActive
                    ? Icons.bluetooth_connected
                    : Icons.info_outline_rounded,
                color: isActive
                    ? const Color(0xFF9DE0BC)
                    : const Color(0xFFFFD98E),
                size: 16,
              ),
              SizedBox(width: 7),
              Expanded(
                child: Text(
                  isActive
                      ? '$peerCount nodos detectados · GATT al enviar'
                      : 'Activa el nodo para anunciarte y buscar vecinos',
                  style: TextStyle(color: Color(0xFFF4E5C5), fontSize: 11),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _BleErrorCard extends StatelessWidget {
  const _BleErrorCard({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: const Color(0xFFFFEFEB),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFF0D2CA)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.bluetooth_disabled_rounded,
            color: Color(0xFFAE4A35),
            size: 19,
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                color: Color(0xFF7D382B),
                fontSize: 12,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _NearbyNodesCard extends StatelessWidget {
  const _NearbyNodesCard({
    required this.isActive,
    required this.nodes,
    required this.transferStatus,
    required this.onRetryWifiDirect,
    required this.onOpenWifiSettings,
  });

  final bool isActive;
  final List<NearbyNode> nodes;
  final String? transferStatus;
  final VoidCallback onRetryWifiDirect;
  final VoidCallback onOpenWifiSettings;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(17),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.radar_rounded,
                color: Color(0xFF4E7665),
                size: 19,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Nodos BLE cercanos',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurface,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Text(
                '${nodes.length}',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (nodes.isEmpty)
            Text(
              isActive
                  ? 'Buscando teléfonos NEBULA próximos…'
                  : 'Activa Bluetooth para buscar teléfonos próximos.',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontSize: 11,
                height: 1.4,
              ),
            )
          else
            ...nodes.map(
              (node) => Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Row(
                  children: [
                    const Icon(
                      Icons.smartphone_rounded,
                      color: Color(0xFF4E7665),
                      size: 17,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            node.name,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.onSurface,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          Text(
                            node.id,
                            style: TextStyle(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                              fontSize: 10,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Text(
                      '${node.rssi} dBm',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          if (transferStatus != null) ...[
            const SizedBox(height: 9),
            Text(
              transferStatus!,
              style: TextStyle(
                color: Color(0xFF4E7665),
                fontSize: 10,
                fontWeight: FontWeight.w600,
                height: 1.35,
              ),
            ),
            if (transferStatus!.toLowerCase().contains('wifi') ||
                transferStatus!.toLowerCase().contains('wi-fi')) ...[
              const SizedBox(height: 4),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed:
                      transferStatus!.toLowerCase().contains('activa wi-fi')
                      ? onOpenWifiSettings
                      : onRetryWifiDirect,
                  icon: Icon(
                    transferStatus!.toLowerCase().contains('activa wi-fi')
                        ? Icons.wifi
                        : Icons.refresh,
                  ),
                  label: Text(
                    transferStatus!.toLowerCase().contains('activa wi-fi')
                        ? 'Activar Wi-Fi'
                        : 'Reintentar Wi-Fi Direct',
                  ),
                ),
              ),
            ],
          ],
          if (nodes.isNotEmpty) ...[
            const SizedBox(height: 7),
            Text(
              'El intento de transferencia no confirma lectura ni guardado '
              'duradero en el teléfono vecino.',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontSize: 10,
                height: 1.35,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _SectionHeading extends StatelessWidget {
  const _SectionHeading({required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            color: const Color(0xFF1B2E27),
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          subtitle,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            height: 1.35,
          ),
        ),
      ],
    );
  }
}

class _NodeNameEditor extends StatelessWidget {
  const _NodeNameEditor({
    required this.nodeName,
    required this.saving,
    required this.onEdit,
  });

  final String nodeName;
  final bool saving;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Nombre de este nodo',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurface,
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            'Los teléfonos cercanos verán “$nodeName”. Usa un apodo, no datos personales.',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontSize: 11,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Text(
                  nodeName,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurface,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              OutlinedButton.icon(
                key: const Key('node-name-edit'),
                onPressed: saving ? null : onEdit,
                icon: const Icon(Icons.edit_outlined, size: 17),
                label: Text(saving ? 'Guardando…' : 'Editar nombre'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _EditNodeNameDialog extends StatefulWidget {
  const _EditNodeNameDialog({required this.initialName});

  final String initialName;

  @override
  State<_EditNodeNameDialog> createState() => _EditNodeNameDialogState();
}

class _EditNodeNameDialogState extends State<_EditNodeNameDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialName);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Editar nombre del nodo'),
      content: TextField(
        key: const Key('node-name-input'),
        controller: _controller,
        autofocus: true,
        maxLength: 12,
        textCapitalization: TextCapitalization.words,
        decoration: const InputDecoration(
          labelText: 'Apodo público',
          hintText: 'Casa norte',
          counterText: 'Máximo 12 bytes UTF-8',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          key: const Key('save-node-name'),
          onPressed: () => Navigator.pop(context, _controller.text),
          child: const Text('Guardar'),
        ),
      ],
    );
  }
}

class _ModeSelector extends StatelessWidget {
  const _ModeSelector({required this.mode, required this.onChanged});

  final NodeMode mode;
  final ValueChanged<NodeMode> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _ModeOption(
            icon: Icons.home_work_outlined,
            title: 'Nodo fijo',
            subtitle: 'Teléfono en casa',
            selected: mode == NodeMode.fixed,
            onTap: () => onChanged(NodeMode.fixed),
          ),
        ),
        const SizedBox(width: 11),
        Expanded(
          child: _ModeOption(
            icon: Icons.directions_walk_rounded,
            title: 'Nodo móvil',
            subtitle: 'Teléfono personal',
            selected: mode == NodeMode.mobile,
            onTap: () => onChanged(NodeMode.mobile),
          ),
        ),
      ],
    );
  }
}

class _ThemePreferenceCard extends StatelessWidget {
  const _ThemePreferenceCard({
    required this.darkMode,
    required this.saving,
    required this.onChanged,
  });

  final bool darkMode;
  final bool saving;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.surface,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: colors.outlineVariant),
        ),
        child: SwitchListTile(
          key: const Key('dark-mode-switch'),
          value: darkMode,
          onChanged: saving ? null : onChanged,
          secondary: Icon(
            darkMode ? Icons.dark_mode_outlined : Icons.light_mode_outlined,
            color: colors.primary,
          ),
          title: Text(
            'Modo oscuro',
            style: TextStyle(
              color: colors.onSurface,
              fontWeight: FontWeight.w600,
            ),
          ),
          subtitle: Text(
            saving ? 'Guardando preferencia…' : 'Apariencia de la app',
            style: TextStyle(color: colors.onSurfaceVariant, fontSize: 12),
          ),
        ),
      ),
    );
  }
}

class _FixedStartupOption extends StatelessWidget {
  const _FixedStartupOption({
    required this.visible,
    required this.enabled,
    required this.diagnostic,
    required this.onChanged,
  });

  final bool visible;
  final bool enabled;
  final String? diagnostic;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    if (!visible) return const SizedBox.shrink();
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(16),
        child: SwitchListTile(
          value: enabled,
          onChanged: onChanged,
          secondary: const Icon(
            Icons.power_settings_new_rounded,
            color: Color(0xFF4E7665),
          ),
          title: Text(
            'Iniciar al encender Android',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurface,
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
          subtitle: Text(
            diagnostic ??
                'Solo para nodo fijo. Requiere notificación permanente.',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontSize: 11,
              height: 1.35,
            ),
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 4,
          ),
          activeThumbColor: const Color(0xFF145B49),
        ),
      ),
    );
  }
}

class _SeismicAlarmPreferenceCard extends StatelessWidget {
  const _SeismicAlarmPreferenceCard({
    required this.enabled,
    required this.monitoring,
    required this.triggered,
    required this.saving,
    required this.error,
    required this.nodeActive,
    required this.autoStart,
    required this.onChanged,
  });

  final bool enabled;
  final bool monitoring;
  final bool triggered;
  final bool saving;
  final String? error;
  final bool nodeActive;
  final bool autoStart;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final status =
        error ??
        (triggered
            ? 'Alarma activada. Comprueba el entorno y sigue las indicaciones oficiales.'
            : monitoring
            ? 'Sensor activo${autoStart ? '; inicio automático configurado' : '; no se reactivará tras reiniciar Android'}.'
            : enabled && !nodeActive
            ? 'Configurada; activa el nodo Bluetooth para iniciar la vigilancia.'
            : enabled
            ? 'Esperando a que se active el sensor.'
            : 'Experimental: detecta vibración sostenida, no predice ni confirma sismos.');
    return Material(
      color: colors.surface,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: colors.outlineVariant),
        ),
        child: SwitchListTile(
          key: const Key('seismic-alarm-switch'),
          value: enabled,
          onChanged: saving ? null : onChanged,
          secondary: Icon(
            triggered ? Icons.warning_amber_rounded : Icons.sensors_rounded,
            color: triggered ? colors.error : colors.primary,
          ),
          title: Text(
            'Alarma experimental de vibración',
            style: TextStyle(
              color: colors.onSurface,
              fontWeight: FontWeight.w600,
            ),
          ),
          subtitle: Text(
            saving ? 'Guardando…' : status,
            style: TextStyle(color: colors.onSurfaceVariant, fontSize: 12),
          ),
        ),
      ),
    );
  }
}

class _ModeOption extends StatelessWidget {
  const _ModeOption({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final borderColor = selected
        ? const Color(0xFF145B49)
        : const Color(0xFFE1E7E3);
    return Semantics(
      button: true,
      selected: selected,
      child: Material(
        color: selected
            ? Theme.of(context).colorScheme.secondaryContainer
            : Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(17),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(17),
          child: Container(
            constraints: const BoxConstraints(minHeight: 91),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(17),
              border: Border.all(color: borderColor, width: selected ? 1.5 : 1),
            ),
            child: Row(
              children: [
                Icon(
                  icon,
                  color: selected
                      ? const Color(0xFF145B49)
                      : Theme.of(context).colorScheme.onSurfaceVariant,
                  size: 22,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurface,
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        subtitle,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                          fontSize: 10,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _NodeDetailsCard extends StatelessWidget {
  const _NodeDetailsCard({required this.isFixed, required this.peerCount});

  final bool isFixed;
  final int peerCount;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(17),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: Row(
        children: [
          Expanded(
            child: _DetailItem(
              icon: Icons.device_hub_outlined,
              label: 'Vecinos',
              value: '$peerCount detectados',
            ),
          ),
          Container(
            height: 35,
            width: 1,
            margin: const EdgeInsets.symmetric(horizontal: 14),
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
          Expanded(
            child: _DetailItem(
              icon: isFixed ? Icons.power_rounded : Icons.battery_5_bar_rounded,
              label: isFixed ? 'Recomendado' : 'Participación',
              value: isFixed ? 'Enchufado' : 'Voluntaria',
            ),
          ),
        ],
      ),
    );
  }
}

class _DetailItem extends StatelessWidget {
  const _DetailItem({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, color: const Color(0xFF4E7665), size: 19),
        const SizedBox(width: 9),
        Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 10,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                value,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurface,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _EmptyMessagesCard extends StatelessWidget {
  const _EmptyMessagesCard();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 23),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(17),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: Column(
        children: [
          Icon(
            Icons.mark_chat_unread_outlined,
            color: Color(0xFF9BA9A1),
            size: 27,
          ),
          SizedBox(height: 9),
          Text(
            'Aún no hay avisos',
            style: const TextStyle(
              color: Color(0xFF42534B),
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
          SizedBox(height: 4),
          Text(
            'Los avisos que redactes aparecerán aquí.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }
}

class _LoadingMessagesCard extends StatelessWidget {
  const _LoadingMessagesCard();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(17),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: const Row(
        children: [
          SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          SizedBox(width: 12),
          Text(
            'Cargando avisos guardados…',
            style: TextStyle(color: Color(0xFF52635A), fontSize: 12),
          ),
        ],
      ),
    );
  }
}

class _StorageErrorCard extends StatelessWidget {
  const _StorageErrorCard({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: const Color(0xFFFFEFEB),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFF0D2CA)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.error_outline_rounded,
            color: Color(0xFFAE4A35),
            size: 19,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(
                color: Color(0xFF7D382B),
                fontSize: 12,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MissingReportDetails {
  const _MissingReportDetails({
    required this.lastSeen,
    required this.characteristics,
    this.name = '',
    this.clothing = '',
    this.category,
    this.breed = '',
    this.photo,
  });

  final String lastSeen;
  final String characteristics;
  final String name;
  final String clothing;
  final String? category;
  final String breed;
  final PhotoAttachment? photo;
}

class _MissingReportDialog extends StatefulWidget {
  const _MissingReportDialog({required this.isPet, required this.title});

  final bool isPet;
  final String title;

  @override
  State<_MissingReportDialog> createState() => _MissingReportDialogState();
}

class _MissingReportDialogState extends State<_MissingReportDialog> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _lastSeenController = TextEditingController();
  final _clothingController = TextEditingController();
  final _breedController = TextEditingController();
  final _characteristicsController = TextEditingController();
  String? _category;
  PhotoAttachment? _photo;
  bool _pickingPhoto = false;
  String? _photoError;

  @override
  void dispose() {
    _nameController.dispose();
    _lastSeenController.dispose();
    _clothingController.dispose();
    _breedController.dispose();
    _characteristicsController.dispose();
    super.dispose();
  }

  String? _requiredField(String? value) =>
      value == null || value.trim().isEmpty ? 'Completa este campo.' : null;

  Future<void> _pickPhoto() async {
    if (_pickingPhoto) return;
    setState(() {
      _pickingPhoto = true;
      _photoError = null;
    });
    try {
      final photo = await BleNodeService().pickPhoto();
      if (mounted) setState(() => _photo = photo);
    } on PlatformException catch (error) {
      if (mounted) {
        setState(
          () => _photoError = error.message ?? 'No se pudo cargar la foto.',
        );
      }
    } finally {
      if (mounted) setState(() => _pickingPhoto = false);
    }
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    Navigator.pop(
      context,
      _MissingReportDetails(
        lastSeen: _lastSeenController.text.trim(),
        characteristics: _characteristicsController.text.trim(),
        name: _nameController.text.trim(),
        clothing: _clothingController.text.trim(),
        category: _category,
        breed: _breedController.text.trim(),
        photo: _photo,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isPet = widget.isPet;
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Completa los datos para que los vecinos puedan reconocer '
                  'a quien buscan. La última ubicación se escribe manualmente; '
                  'no se solicitará el GPS de este teléfono.',
                  style: TextStyle(fontSize: 13, height: 1.35),
                ),
                const SizedBox(height: 14),
                if (isPet)
                  DropdownButtonFormField<String>(
                    key: const Key('missing-pet-category'),
                    initialValue: _category,
                    decoration: const InputDecoration(
                      labelText: 'Tipo de mascota',
                      border: OutlineInputBorder(),
                    ),
                    items: const [
                      DropdownMenuItem(value: 'Perro', child: Text('Perro')),
                      DropdownMenuItem(value: 'Gato', child: Text('Gato')),
                      DropdownMenuItem(value: 'Ave', child: Text('Ave')),
                      DropdownMenuItem(value: 'Otro', child: Text('Otro')),
                    ],
                    validator: (value) =>
                        value == null ? 'Selecciona una categoría.' : null,
                    onChanged: (value) => setState(() => _category = value),
                  )
                else
                  TextFormField(
                    key: const Key('missing-person-name'),
                    controller: _nameController,
                    maxLength: 20,
                    textCapitalization: TextCapitalization.words,
                    decoration: const InputDecoration(
                      labelText: 'Nombre o apodo (opcional)',
                      counterText: '',
                      border: OutlineInputBorder(),
                    ),
                  ),
                if (isPet) ...[
                  const SizedBox(height: 10),
                  TextFormField(
                    key: const Key('missing-pet-name'),
                    controller: _nameController,
                    maxLength: 20,
                    textCapitalization: TextCapitalization.words,
                    decoration: const InputDecoration(
                      labelText: 'Nombre (opcional)',
                      counterText: '',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  key: Key(
                    isPet
                        ? 'select-missing-pet-photo'
                        : 'select-missing-person-photo',
                  ),
                  onPressed: _pickingPhoto ? null : _pickPhoto,
                  icon: _pickingPhoto
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.add_a_photo_outlined),
                  label: Text(
                    _photo == null
                        ? 'Añadir foto (opcional, original hasta 20 MB)'
                        : 'Cambiar foto',
                  ),
                ),
                if (_photo != null) ...[
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Image.file(
                      File(_photo!.path),
                      height: 150,
                      width: double.infinity,
                      fit: BoxFit.cover,
                    ),
                  ),
                  Text(
                    'Copia optimizada: ${_photo!.bytes ~/ 1024} KB',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  TextButton.icon(
                    onPressed: () => setState(() => _photo = null),
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('Quitar foto'),
                  ),
                ],
                if (_photoError != null)
                  Text(
                    _photoError!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                const Text(
                  'La foto se compartirá con los nodos NEBULA y podrá '
                  'reenviarse por Wi-Fi Direct durante 24 horas. NEBULA '
                  'prepara una copia JPEG optimizada de hasta 1600 px para '
                  'acelerar el envío; la foto original no se modifica. No es '
                  'privada.',
                  style: TextStyle(fontSize: 12, height: 1.35),
                ),
                if (isPet) ...[
                  const SizedBox(height: 10),
                  TextFormField(
                    key: const Key('missing-pet-breed'),
                    controller: _breedController,
                    maxLength: 35,
                    validator: _requiredField,
                    textCapitalization: TextCapitalization.words,
                    decoration: const InputDecoration(
                      labelText: 'Raza del animal',
                      hintText: 'Labrador, siamés, mestizo…',
                      counterText: '',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ],
                const SizedBox(height: 10),
                TextFormField(
                  key: const Key('missing-last-seen'),
                  controller: _lastSeenController,
                  maxLength: 30,
                  validator: _requiredField,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(
                    labelText: 'Última vez visto: lugar y hora',
                    hintText: 'Parque central, hoy 15:00',
                    counterText: '',
                    border: OutlineInputBorder(),
                  ),
                ),
                if (!isPet) ...[
                  const SizedBox(height: 10),
                  TextFormField(
                    key: const Key('missing-person-clothing'),
                    controller: _clothingController,
                    maxLength: 45,
                    validator: _requiredField,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: const InputDecoration(
                      labelText: 'Vestimenta',
                      hintText: 'Camisa azul, pantalón negro',
                      counterText: '',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ],
                const SizedBox(height: 10),
                TextFormField(
                  key: const Key('missing-characteristics'),
                  controller: _characteristicsController,
                  maxLength: 45,
                  validator: _requiredField,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: InputDecoration(
                    labelText: isPet
                        ? 'Características (color, tamaño, collar...)'
                        : 'Características físicas',
                    counterText: '',
                    border: const OutlineInputBorder(),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          key: const Key('continue-missing-report'),
          onPressed: _submit,
          child: const Text('Revisar reporte'),
        ),
      ],
    );
  }
}

class _IncidentEvidenceSelection {
  const _IncidentEvidenceSelection({this.photo});

  final PhotoAttachment? photo;
}

class _IncidentEvidenceDialog extends StatefulWidget {
  const _IncidentEvidenceDialog();

  @override
  State<_IncidentEvidenceDialog> createState() =>
      _IncidentEvidenceDialogState();
}

class _IncidentEvidenceDialogState extends State<_IncidentEvidenceDialog> {
  PhotoAttachment? _photo;
  bool _pickingPhoto = false;
  String? _photoError;

  Future<void> _pickPhoto() async {
    if (_pickingPhoto) return;
    setState(() {
      _pickingPhoto = true;
      _photoError = null;
    });
    try {
      final photo = await BleNodeService().pickPhoto();
      if (mounted && photo != null) setState(() => _photo = photo);
    } on PlatformException catch (error) {
      if (mounted) {
        setState(
          () => _photoError = error.message ?? 'No se pudo cargar la foto.',
        );
      }
    } finally {
      if (mounted) setState(() => _pickingPhoto = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Evidencia del robo'),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Puedes adjuntar una foto de evidencia (opcional, original '
                'hasta 20 MB). NEBULA prepara una copia JPEG optimizada de '
                'hasta 1600 px para acelerar el envío; la foto original no '
                'se modifica. '
                'Se compartirá con nodos NEBULA cercanos y podrá reenviarse '
                'durante 24 horas; no es privada.',
                style: TextStyle(fontSize: 13, height: 1.4),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                key: const Key('select-robbery-photo'),
                onPressed: _pickingPhoto ? null : _pickPhoto,
                icon: _pickingPhoto
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.add_a_photo_outlined),
                label: Text(_photo == null ? 'Añadir foto' : 'Cambiar foto'),
              ),
              if (_photo != null) ...[
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image.file(
                    File(_photo!.path),
                    height: 150,
                    width: double.infinity,
                    fit: BoxFit.cover,
                  ),
                ),
                Text(
                  'Copia optimizada: ${_photo!.bytes ~/ 1024} KB',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                TextButton.icon(
                  onPressed: () => setState(() => _photo = null),
                  icon: const Icon(Icons.delete_|outline),
                  label: const Text('Quitar foto'),
                ),
              ],
              if (_photoError != null)
                Text(
                  _photoError!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const Key('cancel-robbery-report'),
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          key: const Key('continue-robbery-report'),
          onPressed: _pickingPhoto
              ? null
              : () => Navigator.pop(
                  context,
                  _IncidentEvidenceSelection(photo: _photo),
                ),
          child: const Text('Continuar'),
        ),
      ],
    );
  }
}

class _QuickHelpActionsCard extends StatelessWidget {
  const _QuickHelpActionsCard({
    required this.busy,
    required this.onRequestHelp,
    required this.onReportFire,
    required this.onReportRobbery,
    required this.onReportMissingPerson,
    required this.onReportMissingPet,
  });

  final bool busy;
  final VoidCallback onRequestHelp;
  final VoidCallback onReportFire;
  final VoidCallback onReportRobbery;
  final VoidCallback onReportMissingPerson;
  final VoidCallback onReportMissingPet;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF8F1),
        borderRadius: BorderRadius.circular(17),
        border: Border.all(color: const Color(0xFFF0DFCE)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Ayuda rápida',
            style: TextStyle(
              color: Color(0xFF492F23),
              fontSize: 15,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'Los avisos viajan por Bluetooth LE. Puedes adjuntar fotos a los '
            'reportes de familiares, mascotas y evidencia de robo; se '
            'distribuyen por Wi-Fi Direct, sin Internet, y pueden tardar. '
            'No sustituye emergencias.',
            style: TextStyle(
              color: Color(0xFF796B62),
              fontSize: 11,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 11),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              key: const Key('quick-help-location'),
              onPressed: busy ? null : onRequestHelp,
              icon: const Icon(Icons.my_location_rounded),
              label: Text(
                busy
                    ? 'Obteniendo ubicación…'
                    : 'Enviar mi ubicación y pedir ayuda',
              ),
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFFAE4A35),
                minimumSize: const Size.fromHeight(48),
              ),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              key: const Key('quick-report-fire'),
              onPressed: busy ? null : onReportFire,
              icon: const Icon(Icons.local_fire_department_outlined),
              label: const Text('Reportar incendio en casa'),
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFF9B3B24),
                minimumSize: const Size.fromHeight(46),
              ),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              key: const Key('quick-report-robbery'),
              onPressed: busy ? null : onReportRobbery,
              icon: const Icon(Icons.home_outlined),
              label: const Text('Reportar un robo en casa'),
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFF55425F),
                minimumSize: const Size.fromHeight(46),
              ),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              key: const Key('quick-report-missing-person'),
              onPressed: busy ? null : onReportMissingPerson,
              icon: const Icon(Icons.person_search_rounded),
              label: const Text('Reportar familiar desaparecido'),
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFF594875),
                minimumSize: const Size.fromHeight(46),
              ),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              key: const Key('quick-report-missing-pet'),
              onPressed: busy ? null : onReportMissingPet,
              icon: const Icon(Icons.pets_outlined),
              label: const Text('Reportar mascota desaparecida'),
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFF426B53),
                minimumSize: const Size.fromHeight(46),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MessageCard extends StatelessWidget {
  const _MessageCard({
    required this.message,
    required this.wifiTransferStatus,
    required this.onOpenWifiSettings,
  });

  final LocalMessage message;
  final String? wifiTransferStatus;
  final VoidCallback onOpenWifiSettings;

  @override
  Widget build(BuildContext context) {
    final urgent = message.priority == MessagePriority.urgent;
    final alertStyle = _quickAlertCardStyle(message.text);
    final colors = Theme.of(context).colorScheme;
    final accentColor =
        alertStyle?.accent ??
        (urgent ? const Color(0xFFAE4A35) : const Color(0xFF4E7665));
    return Container(
      key: Key('message-card-${message.id}'),
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: alertStyle?.background ?? colors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color:
              alertStyle?.border ??
              (urgent ? const Color(0xFFF0D2CA) : colors.outlineVariant),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            alertStyle?.icon ??
                (urgent
                    ? Icons.warning_amber_rounded
                    : Icons.chat_bubble_outline),
            color: accentColor,
            size: 20,
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  message.text,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurface,
                    fontSize: 13,
                    height: 1.4,
                  ),
                ),
                if (message.photoId != null) ...[
                  const SizedBox(height: 9),
                  FutureBuilder<String?>(
                    future: BleNodeService().getPhotoPath(message.photoId!),
                    builder: (context, snapshot) {
                      final path = snapshot.data;
                      if (path == null) {
                        final status = wifiTransferStatus;
                        final wifiOff =
                            status?.toLowerCase().contains('activa wi-fi') ??
                            false;
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              wifiOff
                                  ? 'Foto pendiente · activa Wi-Fi para iniciar la transferencia.'
                                  : status ?? 'Foto pendiente · NEBULA buscará nodos cercanos para transferirla.',
                              style: TextStyle(
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                                fontSize: 12,
                                height: 1.35,
                              ),
                            ),
                            if (wifiOff)
                              TextButton.icon(
                                onPressed: onOpenWifiSettings,
                                icon: const Icon(Icons.wifi),
                                label: const Text('Activar Wi-Fi'),
                              ),
                          ],
                        );
                      }
                      return GestureDetector(
                        onTap: () => showDialog<void>(
                          context: context,
                          builder: (context) => Dialog(
                            child: InteractiveViewer(
                              child: Image.file(File(path)),
                            ),
                          ),
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(11),
                          child: Image.file(
                            File(path),
                            height: 180,
                            width: double.infinity,
                            fit: BoxFit.cover,
                          ),
                        ),
                      );
                    },
                  ),
                ],
                const SizedBox(height: 7),
                Text(
                  '${message.senderName ?? 'Remitente sin nombre'} · '
                  '${message.senderLocalTime ?? 'hora no disponible'} '
                  '(hora local del remitente)',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  '${urgent ? 'URGENTE' : 'AVISO'} · '
                  '${message.received ? 'RECIBIDO / REENVIADO' : 'GUARDADO LOCAL'}',
                  style: TextStyle(
                    color: urgent
                        ? accentColor
                        : Theme.of(context).colorScheme.onSurfaceVariant,
                    fontSize: 9,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.5,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _QuickAlertCardStyle {
  const _QuickAlertCardStyle({
    required this.accent,
    required this.background,
    required this.border,
    required this.icon,
  });

  final Color accent;
  final Color background;
  final Color border;
  final IconData icon;
}

_QuickAlertCardStyle? _quickAlertCardStyle(String text) {
  final normalized = text.trimLeft().toUpperCase();
  if (normalized.startsWith('🆘 PIDO AYUDA')) {
    return const _QuickAlertCardStyle(
      accent: Color(0xFFAE4A35),
      background: Color(0xFFFFEFEC),
      border: Color(0xFFDE8A7A),
      icon: Icons.my_location_rounded,
    );
  }
  if (normalized.startsWith('🔥 INCENDIO EN CASA')) {
    return const _QuickAlertCardStyle(
      accent: Color(0xFF9B3B24),
      background: Color(0xFFFFF0E6),
      border: Color(0xFFE7A27C),
      icon: Icons.local_fire_department_outlined,
    );
  }
  if (normalized.startsWith('🚨 ROBO EN CASA')) {
    return const _QuickAlertCardStyle(
      accent: Color(0xFF55425F),
      background: Color(0xFFF2EDF5),
      border: Color(0xFFB9A7C4),
      icon: Icons.home_outlined,
    );
  }
  if (normalized.startsWith('PERSONA DESAPARECIDA')) {
    return const _QuickAlertCardStyle(
      accent: Color(0xFF594875),
      background: Color(0xFFF1EDF8),
      border: Color(0xFFB4A5CD),
      icon: Icons.person_search_rounded,
    );
  }
  if (normalized.startsWith('MASCOTA DESAPARECIDA')) {
    return const _QuickAlertCardStyle(
      accent: Color(0xFF426B53),
      background: Color(0xFFEDF5EE),
      border: Color(0xFF9DBBA2),
      icon: Icons.pets_outlined,
    );
  }
  return null;
}

class ComposeMessageSheet extends StatefulWidget {
  const ComposeMessageSheet({super.key});

  @override
  State<ComposeMessageSheet> createState() => _ComposeMessageSheetState();
}

class _ComposeMessageSheetState extends State<ComposeMessageSheet> {
  final _controller = TextEditingController();
  MessagePriority _priority = MessagePriority.normal;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    Navigator.of(context)
        .pop(LocalMessage.create(text: text, priority: _priority));
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: Container(
        padding: const EdgeInsets.fromLTRB(22, 14, 22, 22),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(25)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 38,
                height: 4,
                decoration: BoxDecoration(
                  color: const Color(0xFFD5DDD8),
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
            const SizedBox(height: 22),
            Text(
              'Nuevo aviso',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                color: const Color(0xFF1B2E27),
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Escribe información breve para tu comunidad.',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 18),
            TextField(
              key: const Key('message-input'),
              controller: _controller,
              autofocus: true,
              minLines: 3,
              maxLines: 5,
              maxLength: 280,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                hintText: '¿Qué necesita saber la comunidad?',
                filled: true,
                fillColor: Theme.of(context).colorScheme.surface,
                alignLabelWithHint: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(15),
                  borderSide: const BorderSide(color: Color(0xFFE1E7E3)),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(15),
                  borderSide: const BorderSide(color: Color(0xFFE1E7E3)),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(15),
                  borderSide: const BorderSide(
                    color: Color(0xFF145B49),
                    width: 1.5,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 5),
            Text(
              'Prioridad',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurface,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 9),
            Wrap(
              spacing: 9,
              children: [
                ChoiceChip(
                  label: const Text('Aviso'),
                  selected: _priority == MessagePriority.normal,
                  onSelected: (_) =>
                      setState(() => _priority = MessagePriority.normal),
                ),
                ChoiceChip(
                  label: const Text('Urgente'),
                  selected: _priority == MessagePriority.urgent,
                  onSelected: (_) =>
                      setState(() => _priority = MessagePriority.urgent),
                ),
              ],
            ),
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                key: const Key('save-message'),
                onPressed: _save,
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(51),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(15),
                  ),
                ),
                child: const Text('Guardar y compartir aviso'),
              ),
            ),
            const SizedBox(height: 9),
            Center(
              child: Text(
                'Se guardará en este teléfono y se intentará compartir si BLE está activo.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 10,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
