# NEBULA — Red Mesh Comunitaria Offline

[![Flutter](https://img.shields.io/badge/Flutter-3.13+-02569B?logo=flutter&logoColor=white)](https://flutter.dev)
[![Android](https://img.shields.io/badge/Platform-Android%206.0+-3DDC84?logo=android&logoColor=white)](https://developer.android.com)
[![Protocol](https://img.shields.io/badge/Protocol-BLE%20GATT%20%2B%20Wi--Fi%20Direct-orange)](#arquitectura-de-red)
[![License](https://img.shields.io/badge/License-MIT-blue)](#)

**NEBULA** es una aplicación descentralizada de mensajería comunitaria y auxilio en emergencias diseñada para operar **100% fuera de línea (sin Internet, sin datos móviles y sin routers)**. 

Está especialmente concebida para situaciones de catástrofe, apagones prolongados o comunidades aisladas, permitiendo enlazar teléfonos personales y **reutilizar smartphones antiguos** como nodos fijos repetidores.

---

## 📋 Tabla de Contenidos

- [Características Principales](#-características-principales)
- [Arquitectura de Red](#-arquitectura-de-red)
- [Modos de Operación](#-modos-de-operación)
- [Transferencia de Fotos (Wi-Fi Direct)](#-transferencia-de-fotos-wi-fi-direct)
- [Alarma Experimental de Vibración](#-alarma-experimental-de-vibración)
- [Estructura del Proyecto](#-estructura-del-proyecto)
- [Requisitos y Permisos](#-requisitos-y-permisos)
- [Instalación y Compilación](#-instalación-y-compilación)
- [Configuración de Nodos Fijos (MIUI / HyperOS / Samsung)](#-configuración-de-nodos-fijos-miui--hyperos--samsung)
- [Seguridad y Privacidad](#-seguridad-y-privacidad)

---

## ✨ Características Principales

- **Red en Malla Multi-Salto (*Store-and-Forward*)**:
  - Difusión de avisos entre vecinos por Bluetooth Low Energy (BLE).
  - Límite de propagación de hasta **8 saltos** y caducidad automática a las **24 horas**.
  - Deduplicación atómica mediante IDs hexadecimales únicos de 32 caracteres para prevenir tormentas de retransmisión.
  - Cola persistente nativa con reintentos exponenciales cuando se detectan nuevos vecinos.
- **Botones de Asistencia Rápida**:
  - 🆘 **Pido Ayuda**: Obtiene coordenadas del sensor GPS nativo sin conexión y las difunde.
  - 🔥 **Incendio en Casa**: Alerta geolocalizada de evacuación o auxilio.
  - 🚨 **Robo en Casa**: Alerta geolocalizada con opción de adjuntar evidencia fotográfica.
- **Búsqueda de Desaparecidos**:
  - Formularios dedicados para **familiar desaparecido** y **mascota extraviada** (incluyendo vestimenta, raza, rasgos físicos y última ubicación conocida escrita manualmente).
- **Transporte Híbrido Texto/Multimedia**:
  - El texto y las coordenadas viajan instantáneamente por **BLE GATT**.
  - Las fotos viajan en paralelo mediante **Wi-Fi Direct P2P** en sockets TCP dedicados.
- **Persistencia en Segundo Plano**:
  - Servicio Foreground en Android (`START_STICKY`) con notificación de estado para asegurar la retransmisión pasiva.
  - Autoarranque opcional al encender el móvil (`BOOT_COMPLETED`).

---

## 📡 Arquitectura de Red

NEBULA separa los canales de transmisión para maximizar la batería y la velocidad:

```text
                  SIN INTERNET / SIN ROUTERS
 
  [Teléfono Móvil]
   Crea aviso + GPS
          │
          │ BLE: Descubre vecinos y negocia MTU
          ▼
   [Nodo Fijo Casa A] ─── BLE / GATT ───► [Nodo Fijo Casa B] ─── BLE ───► [Nodo Fijo Casa C]
   (Guarda, deduplica                     (Guarda y reenvía)              (Notifica al vecino)
    y reenvía)                                    │                                ▲
          │                                       │                                │
          └────── Wi-Fi Direct (P2P) ─────────────┴────────────────────────────────┘
                  (Fotos pesadas: se transmiten de forma secuencial por sockets TCP)
```

1. **BLE GATT (`BleNodeController.kt`)**: 
   - Anuncio BLE (`BluetoothLeAdvertiser`) y escaneo continuo (`BluetoothLeScanner`).
   - Servidor GATT local con característica de escritura fragmentada en bloques adaptados al MTU negociado.
2. **Wi-Fi Direct P2P (`WifiDirectPhotoTransport.kt`)**:
   - Descubrimiento por servicios DNS-SD (`_nebula._tcp` con marcador `NEBULA`).
   - Negociación de grupos P2P y transferencia directa socket a socket por el puerto `8988`.

---

## 📱 Modos de Operación

La aplicación permite alternar entre dos modos de trabajo:

| Ajuste | Nodo Móvil | Nodo Fijo (Casa / Punto Comunitario) |
| :--- | :--- | :--- |
| **Caso de uso** | Teléfono personal en movimiento. | Teléfono conectado a la corriente en una pared. |
| **Inicio automático** | No | Sí, se ejecuta al reiniciar Android. |
| **Alarma sísmica** | Desactivada | Activable (monitorea acelerómetro lineal). |
| **Segundo plano** | Manual al activar BLE | Permanente con servicio Foreground prioritario. |

---

## 📷 Transferencia de Fotos (Wi-Fi Direct)

Para reportes de personas extraviadas, mascotas o evidencias de robo con foto:
- **Optimización automática**: Admite imágenes de hasta 20 MB (JPEG, PNG, WebP). La app orienta la imagen, reduce la copia transmitida a un máximo de 1600 px y la comprime a JPEG calidad 82 (máximo 5 MB por archivo).
- **Privacidad**: **Se eliminan los metadatos EXIF** (incluyendo geolocalización de la cámara).
- **Integridad**: El archivo se verifica con su hash **SHA-256** antes de confirmar la recepción en disco.
- **Capacidad**: Almacena temporalmente hasta 10 fotos o 50 MB en cola por dispositivo con expiración de 24 horas.

---

## 🔔 Alarma Experimental de Vibración

Pensada para **teléfonos fijos sujetos a un muro**:
- Utiliza el sensor `Sensor.TYPE_LINEAR_ACCELERATION` (aceleración sin gravedad).
- Si registra una oscilación continua superior al umbral por más de **2 segundos continuos**, activa en bucle la alarma sonora de Android, hace vibrar el dispositivo y emite una notificación con botón para silenciar.
- *Nota de seguridad*: Es una prueba experimental para eventos sísmicos o colisiones; no reemplaza sistemas oficiales de alerta temprana.

---

## 📂 Estructura del Proyecto

```text
├── android/
│   └── app/src/main/kotlin/org/comunidad/telefonos_mesh/
│       ├── MainActivity.kt               # Puente MethodChannel y EventChannel con Flutter
│       ├── BleNodeForegroundService.kt   # Servicio persistente y gestor de sensores
│       ├── BleNodeController.kt          # Servidor/Cliente GATT, fragmentación y cola BLE
│       ├── WifiDirectPhotoTransport.kt   # Protocolo P2P Wi-Fi Direct y sockets TCP
│       ├── NebulaPhotoStore.kt           # Procesamiento de fotos, hash SHA-256 y rotación
│       ├── BleStoredMessageStore.kt      # Almacenamiento nativo y deduplicación en segundo plano
│       ├── BootCompletedReceiver.kt      # Receptor de arranque del sistema operativo
│       └── AutoStartDiagnostics.kt       # Registro de diagnóstico de reinicio para el usuario
├── lib/
│   ├── main.dart                         # Interfaz gráfica Flutter (Material 3), temas y estados
│   ├── models/
│   │   └── local_message.dart            # Modelo inmutable, conteo de saltos y validaciones
│   └── services/
│       ├── ble_node_service.dart         # Enlace Dart con los canales de plataforma
│       └── local_message_store.dart      # Persistencia local reactiva con SharedPreferences
└── test/
    ├── widget_test.dart                  # Pruebas de integración visual de alertas
    └── services/                         # Pruebas unitarias de almacenamiento y saltos
```

---

## 🔐 Requisitos y Permisos

Requiere **Android 6.0 (API 23)** o superior (óptimo en Android 8.0 a 14+).

- **Bluetooth**: `BLUETOOTH_SCAN`, `BLUETOOTH_ADVERTISE`, `BLUETOOTH_CONNECT` (Android 12+) o `ACCESS_FINE_LOCATION` (Android antiguo).
- **Wi-Fi Direct**: `NEARBY_WIFI_DEVICES` (Android 13+) o `ACCESS_FINE_LOCATION`.
- **Ubicación GPS**: Requerida puntualmente solo al pulsar botones de SOS o incidente para capturar coordenadas reales.
- **Servicio y Notificaciones**: `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_CONNECTED_DEVICE`, `POST_NOTIFICATIONS`.
- **Arranque**: `RECEIVE_BOOT_COMPLETED`.

---

## 🚀 Instalación y Compilación

Asegúrate de contar con Flutter (Dart 3.13+) y el Android SDK configurados:

```powershell
# 1. Obtener dependencias
flutter pub get

# 2. Ejecutar pruebas unitarias y de widgets
flutter test

# 3. Compilar e instalar en un dispositivo conectado
flutter run

# 4. Generar APK de depuración
flutter build apk --debug
```

> **Importante para pruebas**: El anuncio BLE (`BLE Advertising`) y Wi-Fi Direct requieren hardware real; **no funcionan en emuladores estándar de Android**. Utiliza dos o más dispositivos físicos para verificar la conectividad mesh.

---

## ⚙️ Configuración de Nodos Fijos (MIUI / HyperOS / Samsung)

Para garantizar que un teléfono viejo opere permanentemente como repetidor sin que el sistema suspenda el proceso:
1. Activa **Nodo Fijo** e **Iniciar al encender Android** en la aplicación.
2. En los ajustes de Android del dispositivo:
   - **Inicio Automático / Autostart**: Conceder a NEBULA.
   - **Ahorro de batería**: Configurar en **Sin restricciones** (*No restrictions*).
   - Bloquear la aplicación en la vista de aplicaciones recientes si el fabricante tiene administradores agresivos de RAM.
3. El panel de la aplicación incluye una sección de **Diagnóstico de arranque** que reportará si el sistema ejecutó el servicio correctamente tras reiniciar.

---

## ⚠️ Seguridad y Privacidad

- **Transmisión Abierta**: Los avisos y fotos viajan **sin cifrado** para que cualquier teléfono comunitario pueda recibirlos, validarlos y retransmitirlos de inmediato. No uses NEBULA para compartir secretos, contraseñas ni datos sensibles.
- **Datos Públicos**: El apodo de nodo configurado y las coordenadas de auxilio son visibles para todos los teléfonos dentro del alcance de radio.
- **Responsabilidad en Emergencias**: NEBULA no enlaza automáticamente con centrales 911 ni cuerpos de bomberos; es una red de apoyo mutuo comunitario. Utilízala con prudencia.
