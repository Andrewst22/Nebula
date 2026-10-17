# Enlace

Prototipo Flutter de mensajería comunitaria para una red local sin Internet.

## Estado actual

- Selección entre nodo fijo (teléfono en una casa) y nodo móvil (teléfono personal).
- Preferencia de apariencia clara u oscura, guardada en el dispositivo.
- Anuncio BLE y descubrimiento de otros teléfonos Enlace con la app abierta en Android.
- Nombre corto configurable por nodo, persistido para el inicio automático y visible en el anuncio BLE de los vecinos.
- Los avisos incluyen el nombre elegido por quien los creó y la hora local del teléfono emisor, con su zona horaria; esos datos se conservan al reenviar el aviso.
- Opción para borrar todo el historial local de mensajes recibidos y creados.
- Botones de ayuda rápida para pedir ayuda con GPS y reportar incendio o robo en casa.
- Reportes urgentes de familiar o mascota desaparecidos con detalles de identificación (incluida la raza del animal) y GPS.
- Envío de avisos por GATT BLE a los vecinos detectados, con fragmentación según el MTU negociado.
- Reenvío multi-salto de mensajes nuevos, deduplicados por ID y limitados a ocho saltos y 24 horas.
- Persistencia local de mensajes.
- Servicio Android en primer plano con notificación de estado y avisos recibidos.
- Inicio automático tras reiniciar Android, activable explícitamente solo en modo nodo fijo.
- Alarma local experimental opcional: usa el acelerómetro lineal para avisar de vibración sostenida en un nodo fijo.
- Confirmación de almacenamiento/lectura, reintentos durables y cifrado no están implementados.

Los avisos se transmiten y guardan sin cifrar ni autenticar. Cualquier dispositivo que pueda conectarse al servicio BLE puede intentar inyectar avisos. El nombre y la hora corresponden a los datos incluidos por el teléfono que originó el aviso; la hora depende de que su reloj esté bien configurado y no se verifica de forma independiente. Una escritura GATT completada no confirma que el mensaje se haya guardado o leído en el teléfono vecino. La detección tampoco garantiza que la conexión o la retransmisión funcionen con cada modelo. No usar para información sensible ni emergencias reales.

## Probar BLE y retransmisión

Instala la app en dos teléfonos Android con Bluetooth LE. En cada uno, activa Bluetooth, concede los permisos solicitados y pulsa **Activar nodo Bluetooth**. En los teléfonos fijos, activa también **Iniciar al encender Android** y deja la notificación del servicio habilitada. Cuando ambos anuncios sean visibles, envía un aviso en uno; el otro debería guardarlo y mostrar una notificación. Para probar la repetición, activa un tercer teléfono próximo al segundo, pero fuera del alcance del primero.

En **Este dispositivo**, configura el apodo que anunciará ese teléfono. El nombre se guarda también en Android para que el nodo fijo lo conserve al arrancar; el anuncio BLE admite hasta 12 bytes UTF-8, por lo que conviene usar un apodo breve. Es un dato público visible a cualquier teléfono Enlace cercano: no uses nombres completos, direcciones ni otra información personal. Si el teléfono remoto no anuncia nombre, la app muestra un nombre genérico.

Los permisos se solicitan al intentar usar la función que los necesita: permisos Bluetooth al activar el nodo y permiso de ubicación precisa al pulsar pedir ayuda, reportar incendio o reportar robo. No se solicita ubicación al abrir la app. Estos tres botones obtienen coordenadas del proveedor GPS, las incluyen en el aviso y piden confirmación antes de guardar y compartirlo. Los reportes de persona o mascota desaparecida no solicitan ni adjuntan el GPS del teléfono que reporta; incluyen la última ubicación escrita manualmente en el formulario. La ubicación se obtiene por GPS y el aviso se transmite por Bluetooth LE: estas funciones no requieren Wi-Fi ni Internet. El mensaje contiene coordenadas numéricas, no un enlace a un servicio de mapas. El GPS debe estar habilitado; obtener una posición puede tardar hasta 30 segundos y fallar dentro de edificios. Android puede usar asistencia de red para acelerar el primer posicionamiento cuando esté disponible, pero la app no necesita conexión de datos para transmitir el aviso. Las coordenadas y los reportes viajan sin cifrar, pueden retransmitirse por varios nodos y no contactan automáticamente a servicios de emergencia. Úsalos solo para avisos reales y no dependas de la app como único medio para pedir ayuda.

La notificación persistente indica que Android mantiene el servicio en primer plano, pero ningún servicio Android puede impedir que el sistema o las políticas del fabricante lo detengan. Comprueba el permiso de inicio automático y la gestión de batería de MIUI/HyperOS en cada dispositivo. Si un teléfono no aparece, comprueba que admita BLE y publicidad BLE. La disponibilidad y el alcance dependen del dispositivo, Android y las condiciones de radio.

## Alarma experimental de vibración

En **Este dispositivo**, activa **Alarma experimental de vibración** solo en un teléfono fijo colocado de forma estable contra una pared. La función activa el nodo BLE y vigila el acelerómetro mientras el servicio de primer plano esté funcionando. Si registra aceleración lineal superior al umbral interno durante dos segundos continuos, reproduce en bucle el sonido de alarma configurado en Android, vibra y muestra una notificación con acción para silenciar. El volumen depende del ajuste de alarma del teléfono; no se fuerza al máximo. Para que el servicio se reactive tras reiniciar, habilita también **Iniciar al encender Android** y permite el inicio automático del fabricante.

Es un experimento de detección de movimiento, no un detector sísmico calibrado, no predice terremotos ni confirma que esté ocurriendo uno. Golpes, puertas, tráfico, obras o el propio teléfono pueden causar falsas alarmas; un sismo también podría no detectarse. El resultado depende del sensor, del montaje y de las restricciones de Android. Comprueba el teléfono y el entorno; no uses esta función como sistema de seguridad, no esperes que dé tiempo para evacuar y sigue las alertas e instrucciones oficiales. Haz pruebas controladas sin golpear el dispositivo ni poner a nadie en riesgo.

En un Redmi/Xiaomi, además del interruptor de la app, revisa los ajustes del sistema para permitir **Inicio automático** y configura el ahorro de batería de Enlace como **Sin restricciones** (los nombres/menús dependen de la versión de MIUI). Al volver a abrir Enlace después de reiniciar, el panel de nodo fijo muestra el último evento de arranque o error registrado. Si sigue mostrando una fecha antigua, MIUI probablemente bloqueó el receptor; si muestra un error, sigue las instrucciones indicadas. Android puede detener el servicio si el usuario fuerza la detención o el fabricante aplica restricciones agresivas.

No desarmes los teléfonos ni retires pantallas/baterías para instalarlos en una caja sin evaluación de un técnico: puede afectar batería, temperatura, antenas y seguridad eléctrica. Prueba primero el equipo intacto, alimentado de forma segura y con ventilación.

## Ejecutar

Requiere Flutter y Android SDK. Desde la carpeta del proyecto:

```powershell
flutter pub get
flutter test
flutter run
```

Para generar un APK de depuración:

```powershell
flutter build apk --debug
```
