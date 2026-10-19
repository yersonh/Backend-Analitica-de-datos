// Notificaciones del sistema: avisan de somnolencia (conductor) y de episodios
// de cualquier conductor (supervisor) aunque la app esté en segundo plano o con
// la pantalla bloqueada. No usa servicios externos (Firebase): mientras hay una
// sesión abierta corre un servicio en primer plano para que Android no congele
// la app y siga consultando al servidor.

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Color;
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class Notifier {
  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _ready = false;
  static int _nextId = 1;

  // Canal nuevo (Android no deja cambiar la vibración de un canal ya creado):
  // suena y vibra fuerte aunque la pantalla esté bloqueada.
  static final _channel = AndroidNotificationDetails(
    'sidfam_somnolencia',
    'Alertas de somnolencia',
    channelDescription: 'Somnolencia detectada, episodios de fatiga y advertencias de sensor',
    importance: Importance.max,
    priority: Priority.high,
    category: AndroidNotificationCategory.alarm,
    color: const Color(0xFFE0607E),
    ticker: 'SIDFAM',
    enableVibration: true,
    vibrationPattern: Int64List.fromList([0, 900, 300, 900, 300, 900]),
  );

  static Future<void> init() async {
    if (_ready || kIsWeb) return;
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'sidfam_vigilancia',
        channelName: 'Vigilancia de la flota',
        channelDescription: 'Aviso fijo mientras SIDFAM vigila a los conductores en segundo plano',
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(showNotification: false),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        allowWakeLock: true,
        allowWifiLock: true,
        // Ojo: stopWithTask aquí detiene el servicio apenas la app deja de verse.
        // "Parar al cerrar la app del todo" va en el manifiesto (android:stopWithTask).
        allowAutoRestart: false,
      ),
    );
    try {
      await _plugin.initialize(
        settings: const InitializationSettings(
          // ícono monocromo: res/drawable/ic_stat_sidfam.xml
          android: AndroidInitializationSettings('ic_stat_sidfam'),
          iOS: DarwinInitializationSettings(
            requestAlertPermission: false,
            requestBadgePermission: false,
            requestSoundPermission: false,
          ),
        ),
      );
      _ready = true;
    } catch (e) {
      debugPrint('Notificaciones no disponibles: $e');
    }
  }

  /// Android 13+ e iOS piden permiso explícito; se pide al entrar un supervisor.
  static Future<void> requestPermission() async {
    if (!_ready) return;
    await _plugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();
    await _plugin.resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>()?.requestPermissions(
      alert: true,
      sound: true,
      badge: false,
    );
  }

  static Future<void> show(String title, String body) async {
    if (!_ready) return;
    await _plugin.show(
      id: _nextId++,
      title: title,
      body: body,
      notificationDetails: NotificationDetails(
        android: _channel,
        iOS: const DarwinNotificationDetails(presentSound: true, interruptionLevel: InterruptionLevel.timeSensitive),
      ),
    );
  }

  /// Con sesión abierta (supervisor o conductor): mantiene viva la app en
  /// segundo plano para poder avisar de somnolencia con la pantalla bloqueada.
  static Future<void> startWatching({
    String title = 'SIDFAM · vigilando la flota',
    String text = 'Te avisará si un conductor muestra signos de fatiga',
  }) async {
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      if (await FlutterForegroundTask.isRunningService) return;
      await FlutterForegroundTask.startService(
        // Android 14+ detiene el servicio si no se declara su tipo al iniciarlo
        serviceTypes: [ForegroundServiceTypes.dataSync],
        notificationIcon: const NotificationIcon(metaDataName: 'co.sidfam.NOTIFICATION_ICON'),
        notificationTitle: title,
        notificationText: text,
      );
    } catch (e) {
      debugPrint('No se pudo iniciar la vigilancia en segundo plano: $e');
    }
  }

  static Future<void> stopWatching() async {
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      if (await FlutterForegroundTask.isRunningService) await FlutterForegroundTask.stopService();
    } catch (_) {}
  }
}
