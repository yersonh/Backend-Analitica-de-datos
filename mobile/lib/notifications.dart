// Notificaciones del sistema para el supervisor: avisan de episodios de fatiga
// de cualquier conductor aunque la app esté en segundo plano o con la pantalla
// bloqueada. No usa servicios externos (Firebase): mientras el supervisor tiene
// la sesión abierta corre un servicio en primer plano ("vigilando la flota")
// para que Android no congele la app y la flota siga consultando al servidor.

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Color;
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class Notifier {
  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _ready = false;
  static int _nextId = 1;

  static const _channel = AndroidNotificationDetails(
    'sidfam_alertas',
    'Alertas de fatiga',
    channelDescription: 'Episodios de fatiga y advertencias de sensor de los conductores',
    importance: Importance.max,
    priority: Priority.high,
    category: AndroidNotificationCategory.alarm,
    color: Color(0xFFE0607E),
    ticker: 'SIDFAM',
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
      notificationDetails: const NotificationDetails(
        android: _channel,
        iOS: DarwinNotificationDetails(presentSound: true, interruptionLevel: InterruptionLevel.timeSensitive),
      ),
    );
  }

  /// Supervisor con sesión abierta: mantiene viva la app en segundo plano.
  static Future<void> startWatching() async {
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      if (await FlutterForegroundTask.isRunningService) return;
      await FlutterForegroundTask.startService(
        // Android 14+ detiene el servicio si no se declara su tipo al iniciarlo
        serviceTypes: [ForegroundServiceTypes.dataSync],
        notificationIcon: const NotificationIcon(metaDataName: 'co.sidfam.NOTIFICATION_ICON'),
        notificationTitle: 'SIDFAM · vigilando la flota',
        notificationText: 'Te avisará si un conductor muestra signos de fatiga',
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
