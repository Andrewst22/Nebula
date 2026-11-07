# NEBULA — Red Mesh Comunitaria y de Emergencias Offline

[![Flutter](https://img.shields.io/badge/Flutter-3.13+-02569B?style=for-the-badge&logo=flutter&logoColor=white)](https://flutter.dev)
[![Dart](https://img.shields.io/badge/Dart-3.13+-0175C2?style=for-the-badge&logo=dart&logoColor=white)](https://dart.dev)
[![Kotlin](https://img.shields.io/badge/Kotlin-Android%20Native-7F52FF?style=for-the-badge&logo=kotlin&logoColor=white)](https://kotlinlang.org)
[![Offline First](https://img.shields.io/badge/Connectivity-100%25%20Offline-success?style=for-the-badge)](#)
[![License](https://img.shields.io/badge/License-MIT-blue?style=for-the-badge)](#licencia)

> **NEBULA** es una plataforma descentralizada de mensajería comunitaria y auxilio ante catástrofes diseñada para operar **completamente sin Internet, sin datos móviles y sin infraestructura de telecomunicaciones comercial**. 

El proyecto combina **Bluetooth Low Energy (BLE)** para avisos ligeros y **Wi-Fi Direct P2P** para transferencia de fotografías, permitiendo enlazar teléfonos personales y **reutilizar smartphones antiguos** como repetidores fijos permanentes en hogares y puntos comunitarios.

---

## 📑 Tabla de Contenidos

1. [Visión General y Casos de Uso](#-visión-general-y-casos-de-uso)
2. [Arquitectura del Sistema y Protocolos](#-arquitectura-del-sistema-y-protocolos)
   - [Canal de Alertas Ligeras (BLE GATT)](#1-canal-de-alertas-ligeras-ble-gatt)
   - [Canal Multimedia (Wi-Fi Direct P2P)](#2-canal-multimedia-wi-fi-direct-p2p)
3. [Interfaz y Funcionalidades](#-interfaz-y-funcionalidades)
4. [Modos de Operación: Móvil vs. Fijo](#-modos-de-operación-móvil-vs-fijo)
5. [Sensor Sísmico y Alarma de Vibración](#-sensor-sísmico-y-alarma-de-vibración)
6. [Estructura del Proyecto](#-estructura-del-proyecto)
7. [Requisitos y Permisos](#-requisitos-y-permisos)
8. [Instalación y Compilación](#-instalación-y-compilación)
9. [Guía de Pruebas con Dispositivos Reales](#-guía-de-pruebas-con-dispositivos-reales)
10. [Optimización para Teléfonos Antiguos (MIUI / HyperOS / Samsung)](#-optimización-para-teléfonos-antiguos-miui--hyperos--samsung)
11. [Buenas Prácticas de Seguridad de Hardware](#-buenas-prácticas-de-seguridad-de-hardware)
12. [Privacidad y Limitaciones](#-privacidad-y-limitaciones)
13. [Hoja de Ruta (Roadmap)](#-hoja-de-ruta-roadmap)

---

## 🎯 Visión General y Casos de Uso

En situaciones de terremotos, huracanes, inundaciones o cortes masivos de energía, las redes celulares e Internet suelen colapsar en los primeros minutos. NEBULA crea una red ad-hoc local e instantánea para:

- **Vecindarios y Edificios**: Comunicación interna entre casas sin salir a la calle durante disturbios o emergencias climáticas.
- **Búsqueda y Rescate Local**: Difusión de descripciones y fotos de menores, adultos mayores o mascotas extraviadas.
- **Reporte Temprano de Incidentes**: Alertas de conatos de incendio o robos con coordenadas GPS numéricas directas del sensor del teléfono.
- **Aprovechamiento de Basura Electrónica (E-Waste)**: Teléfonos Android antiguos con pantalla rota o batería degradada pueden funcionar como repetidores fijos enchufados a la pared.

---

## 📡 Arquitectura del Sistema y Protocolos

NEBULA implementa una **arquitectura de doble canal asíncrono**:

```text
                     TOPOLOGÍA DE MALLA COMUNITARIA
 
    [Teléfono Personal]
      (Crea Alerta)
            │
            │ BLE (GATT Write):Descubre Vecinos y negocia MTU
            ▼
     [Nodo Fijo Casa A] ────── BLE GATT ──────► [Nodo Fijo Casa B] ──────► [Nodo Vecino C]
     (Guarda, deduplica                         (Guarda y reenvía)          (Recibe notificación)
      y reenvía)                                        │                             ▲
            │                                           │                             │
            └────────── Wi-Fi Direct (P2P) ─────────────┴─────────────────────────────┘
                        (Fotos pesadas: se transfieren secuencialmente vía TCP)
```

### 1. Canal de Alertas Ligeras (BLE GATT)
- **Descubrimiento Activo**: Utiliza `BluetoothLeAdvertiser` (emite el UUID del servicio) y `BluetoothLeScanner` con filtro de servicio.
- **Apodo en Anuncio**: Cada nodo anuncia un apodo de hasta 12 bytes UTF-8 en el `ScanRecord`.
- **Protocolo de Fragmentación de Paquetes**: Supera la restricción del MTU por defecto (23 bytes) fragmentando el payload JSON en bloques binarios con cabecera de 8 bytes:
  ```text
  ┌─────────────────┬─────────────────┬─────────────────┬────────────────────────┐
  │ Transfer ID     │ Sequence Index  │ Total Frames    │ Chunk Payload          │
  │ (4 bytes - Int) │ (2 bytes-Short) │ (2 bytes-Short) │ (Datos variables)      │
  └─────────────────┴─────────────────┴─────────────────┴────────────────────────┘
  |<─────────────── Cabecera: 8 bytes ───────────────>|
  ```
- **Malla Multi-Salto (*Store-and-Forward*)**:
  - Cada mensaje se valida contra el esquema [`LocalMessage`](file:///c:/Users/aesz2/Documents/telefonos viejos/lib/models/local_message.dart).
  - Límite de **8 saltos** (`remainingHops = remainingHops - 1`).
  - Caducidad de **24 horas** (`expiresAt`).
  - Identificador único de 32 caracteres hexadecimales para **deduplicación atómica** en memoria y disco.

### 2. Canal Multimedia (Wi-Fi Direct P2P)
- **Protocolo**: `NEBULA-P2P-2` sobre sockets TCP en el puerto `8988`.
- **Descubrimiento DNS-SD**: Anuncio del servicio `_nebula._tcp` con registro TXT `app="NEBULA"`.
- **Optimización de Imágenes**:
  - Acepta imágenes originales de hasta 20 MB (JPEG, PNG, WebP).
  - Normaliza la orientación EXIF y redimensiona la imagen a un máximo de **1600 px** en su lado mayor.
  - Comprime a **JPEG calidad 82** (máximo 5 MB por archivo transmitido).
  - **Elimina todos los metadatos EXIF** (incluyendo geolocalización de la cámara) antes del envío por seguridad.
- **Validación de Integridad**: Comprobación del hash **SHA-256** en destino antes de confirmar la recepción al emisor y habilitar su posterior propagación.
- **Almacenamiento Temporal**: Capacidad máxima de 10 imágenes o 50 MB por nodo con auto-purga a las 24 horas.

---

## 🖥️ Interfaz y Funcionalidades

```text
  ┌──────────────────────────────────────────┐
  │ 🛰️ NEBULA                     [Tema 🌙]  │
  ├──────────────────────────────────────────┤
  │ ESTADO DE RED: ACTIVO (Nodo Fijo)        │
  │ Nodos vecinos detectados: 3              │
  ├──────────────────────────────────────────┤
  │ ACCIONES RÁPIDAS DE EMERGENCIA           │
  │ [🆘 PIDO AYUDA] [🔥 INCENDIO] [🚨 ROBO]  │
  ├──────────────────────────────────────────┤
  │ REPORTES ESPECIALES                      │
  │ [👤 Familiar Perdido] [🐾 Mascota]       │
  ├──────────────────────────────────────────┤
  │ AVISOS RECIENTES                         │
  │ ┌──────────────────────────────────────┐ │
  │ │ 🆘 URGENTE - Casa Norte              │ │
  │ │ PIDO AYUDA                           │ │
  │ │ GPS: 10.480594, -66.903602           │ │
  │ │ Saltos restantes: 6 | Hace 12 min    │ │
  │ └──────────────────────────────────────┘ │
  └──────────────────────────────────────────┘
```

- **🆘 Pido Ayuda**: Consulta directa al chip GPS nativo (`LocationManager.GPS_PROVIDER`) sin requerir Google Play Services ni conexión de datos.
- **🔥 Incendio en casa**: Alerta con coordenadas GPS y formato destacado para rápida lectura.
- **🚨 Robo en casa**: Alerta con coordenadas GPS y opción de adjuntar fotografía de evidencia (daños, sospechosos, vehículos).
- **👤 Familiar / Mascota Extraviada**: Formulario con nombre, última ubicación vista (escrita manualmente), vestimenta, raza, rasgos particulares y foto.
- **Avisos Generales**: Mensajes comunitarios de texto de hasta 280 caracteres con prioridad Normal o Urgente.

---

## ⚙️ Modos de Operación: Móvil vs. Fijo

| Parámetro | Modo Móvil | Modo Fijo (Repetidor de Hogar) |
| :--- | :--- | :--- |
| **Uso previsto** | Teléfono de bolsillo del vecino. | Dispositivo montado en pared o repisa. |
| **Ciclo de vida** | Sujeto a uso de pantalla. | Servicio en primer plano continuo (`START_STICKY`). |
| **Inicio al reiniciar** | Desactivado. | **Automático** vía `BOOT_COMPLETED`. |
| **Alarma de movimiento** | Inactiva. | **Activable**: Detección de vibración continua. |
| **Gestión de memoria** | Puede ser pausado por el SO. | Notificación persistente para evitar cierre por RAM. |

---

## 🔔 Sensor Sísmico y Alarma de Vibración

El modo fijo incluye un monitor experimental de aceleración ([`BleNodeForegroundService.kt`](file:///c:/Users/aesz2/Documents/telefonos viejos/android/app/src/main/kotlin/org/comunidad/telefonos_mesh/BleNodeForegroundService.kt)):
- **Sensor**: `Sensor.TYPE_LINEAR_ACCELERATION` (mide la fuerza dinámica excluyendo la gravedad terrestre de $9.8\,\text{m/s}^2$).
- **Filtro temporal**: La magnitud resultante ($\sqrt{x^2 + y^2 + z^2}$) debe superar el umbral de calibración de forma continua durante **al menos 2000 milisegundos**.
- **Acción**: Dispara en bucle la alarma sonora predeterminada de Android a volumen audible, activa el motor háptico y muestra una notificación prioritaria con botón directo para silenciar.

---

## 📁 Estructura del Proyecto

```text
telefonos viejos/
├── android/app/src/main/kotlin/org/comunidad/telefonos_mesh/
│   ├── MainActivity.kt               # Puente MethodChannel y EventChannel Flutter <-> Android
│   ├── BleNodeForegroundService.kt   # Servicio Foreground continuo y sensor de aceleración
│   ├── BleNodeController.kt          # Servidor/Cliente GATT, fragmentación, escaneo y reintentos
│   ├── WifiDirectPhotoTransport.kt   # Sockets TCP Wi-Fi Direct y sincronización de fotos
│   ├── NebulaPhotoStore.kt           # Procesamiento de imágenes, eliminación EXIF y SHA-256
│   ├── BleStoredMessageStore.kt      # Almacén nativo persistente para reenvío en segundo plano
│   ├── BootCompletedReceiver.kt      # Receptor para autoarranque tras reiniciar el dispositivo
│   └── AutoStartDiagnostics.kt       # Registro de diagnóstico de reinicio para el usuario
├── lib/
│   ├── main.dart                     # UI Material 3, temas claro/oscuro, estado y diálogos
│   ├── models/
│   │   └── local_message.dart        # Modelo inmutable de mensaje, validaciones JSON y saltos
│   └── services/
│       ├── ble_node_service.dart     # Conector Dart con los canales de plataforma
│       └── local_message_store.dart  # Persistencia reactiva con SharedPreferences
└── test/
    ├── widget_test.dart              # Pruebas de integración visual de alertas y temas
    └── services/                     # Pruebas unitarias de almacenamiento y saltos
```

---

## 🔐 Requisitos y Permisos

- **Sistema Operativo**: Android 6.0 (API 23) en adelante. Optimizado para Android 8.0 hasta Android 14+.
- **Permisos Bluetooth**:
  - Android 12+ (API 31+): `BLUETOOTH_SCAN` (`neverForLocation`), `BLUETOOTH_ADVERTISE`, `BLUETOOTH_CONNECT`.
  - Android 6.0 a 11: `BLUETOOTH`, `BLUETOOTH_ADMIN`, `ACCESS_FINE_LOCATION`.
- **Permisos Wi-Fi Direct**:
  - Android 13+ (API 33+): `NEARBY_WIFI_DEVICES`.
  - Android anteriores: `ACCESS_FINE_LOCATION`, `ACCESS_WIFI_STATE`, `CHANGE_WIFI_STATE`.
- **Otros**: `ACCESS_FINE_LOCATION` (GPS puntual), `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_CONNECTED_DEVICE`, `POST_NOTIFICATIONS`, `VIBRATE`, `RECEIVE_BOOT_COMPLETED`.

---

## 🚀 Instalación y Compilación

1. **Clonar el repositorio**:
   ```powershell
   git clone <url-del-repositorio>
   cd "telefonos viejos"
   ```

2. **Instalar paquetes y dependencias**:
   ```powershell
   flutter pub get
   ```

3. **Ejecutar la suite de pruebas unitarias y de widgets**:
   ```powershell
   flutter test
   ```

4. **Compilar e instalar en un dispositivo conectado por USB**:
   ```powershell
   flutter run
   ```

5. **Generar APK para distribución local**:
   ```powershell
   flutter build apk --debug
   ```

---

## 🧪 Guía de Pruebas con Dispositivos Reales

> **Nota técnica crítica**: Los emuladores estándar de Android Studio **no emulan la transmisión publicitaria BLE (`BluetoothLeAdvertiser`) ni Wi-Fi Direct**. Para validar la red en malla es indispensable utilizar **al menos 2 teléfonos Android físicos**.

### Procedimiento para verificar la retransmisión (3 Teléfonos):

```text
[Teléfono A] <─────── 15-20 metros ───────> [Teléfono B] <─────── 15-20 metros ───────> [Teléfono C]
 (Emisor)                                     (Repetidor)                                 (Destino)
```

1. Coloca el **Teléfono A** y el **Teléfono C** separados por una distancia que les impida detectarse directamente entre sí.
2. Coloca el **Teléfono B** en el punto intermedio.
3. En los 3 teléfonos, pulsa **Activar nodo Bluetooth**.
4. Envía un aviso de emergencia desde **A**:
   - **A** transmite a **B** (`remainingHops = 8`).
   - **B** recibe el paquete, lo guarda en su cola nativa, reduce el contador a `remainingHops = 7` y lo transmite a **C**.
   - **C** emite la notificación sonora y vibratoria con el aviso originado en **A**.

### Comandos útiles de depuración vía ADB:

- **Inspeccionar el registro del motor de red en tiempo real**:
  ```powershell
  adb logcat -s BleNodeController:V BleNodeForegroundService:V WifiDirectPhotoTransport:V
  ```
- **Simular reinicio de Android para probar el autoarranque del nodo fijo**:
  ```powershell
  adb shell am broadcast -a android.intent.action.BOOT_COMPLETED -p org.comunidad.telefonos_mesh
  ```

---

## 🔋 Optimización para Teléfonos Antiguos (MIUI / HyperOS / Samsung)

Muchos fabricantes aplican políticas agresivas de gestión de batería que congelan procesos en segundo plano:

1. **Xiaomi / Redmi / POCO (MIUI / HyperOS)**:
   - Ir a *Ajustes > Aplicaciones > Administrar aplicaciones > NEBULA*.
   - Habilitar **Inicio Automático** (*Autostart*).
   - En *Ahorro de batería*, cambiar de "Ahorro de batería recomendado" a **Sin restricciones**.
2. **Samsung (OneUI)**:
   - Ir a *Ajustes > Cuidado del dispositivo > Batería > Límites de uso en segundo plano*.
   - Añadir **NEBULA** a la lista de **Aplicaciones que nunca se suspenden**.
3. **Comprobación en la App**:
   - Tras reiniciar el teléfono, abre NEBULA y revisa la tarjeta **Diagnóstico de arranque** para confirmar si el receptor del sistema fue invocado con éxito.

---

## ⚡ Buenas Prácticas de Seguridad de Hardware

Si vas a dejar un teléfono antiguo conectado de forma permanente como repetidor:
- ❌ **No retires la batería** a menos que tengas un circuito regulador DC-DC adecuado: muchos teléfonos se apagan por picos de corriente al transmitir por radio.
- ⚠️ **Inspecciona la batería**: Si la batería está hinchada, abultada o deforma la pantalla, **deséchala en un punto de reciclaje de inmediato**. No la cargues.
- 🔌 **Usa cargadores certificados** de 5V / 1A o 2A con cables en buen estado.
- 🌬️ **Ventilación**: Instala el teléfono en un lugar ventilado, lejos de fuentes de calor o radiación solar directa.

---

## 🛡️ Privacidad y Limitaciones

1. **Avisos Públicos**: Los datos se transmiten en texto plano intencionalmente para que cualquier nodo de la red vecinal pueda interpretarlos, validarlos y reenviarlos. No compartas contraseñas ni información confidencial.
2. **Sin Enlace a Centrales de Emergencia**: NEBULA no contacta automáticamente al 911 ni a bomberos; es un canal ciudadano de asistencia mutua.
3. **Reloj del Sistema**: Las fechas y zonas horarias se basan en el reloj del teléfono emisor; relojes mal sincronizados mostrarán desfases horarios.

---

## 🗺️ Hoja de Ruta (Roadmap)

- [ ] **Firma Criptográfica Asimétrica (Ed25519)**: Firmar los avisos con clave privada local para evitar suplantación de identidad sin requerir servidores.
- [ ] **Pasarelas de Largo Alcance (LoRa / ESP32)**: Crear un puente serial USB/Bluetooth con microcontroladores LoRa para enlaces de varios kilómetros.
- [ ] **Soporte iOS**: Implementar el backend nativo en Swift utilizando `CoreBluetooth` y `MultipeerConnectivity`.
- [ ] **Mapas Offline Vectoriales**: Integración de mapas mbtiles locales para visualizar las coordenadas GPS recibidas sobre un mapa sin conexión.

---

## 📄 Licencia

Este proyecto se distribuye bajo la licencia **MIT**. Eres libre de adaptarlo, desplegarlo en tu comunidad y contribuir a su desarrollo.
