import 'dart:io';
import 'package:flutter/services.dart';

/// Keeps the existing paper engine alive; never creates another trading isolate.
class BotBackground {
  BotBackground({bool? enabled, MethodChannel? channel})
      : enabled = enabled ?? Platform.isAndroid,
        channel = channel ?? const MethodChannel('cryptoloop/bot_service');
  final bool enabled;
  final MethodChannel channel;
  bool active = false;
  Future<void>? _stopping;
  Future<void> Function(String reason)? onStop;
  bool Function()? isPaperRunning;

  void init() {
    if (!enabled) return;
    channel.setMethodCallHandler((call) async {
      if (call.method == 'heartbeat') {
        return {'paperRunning': active && (isPaperRunning?.call() ?? false)};
      }
      if (call.method == 'stopRequested' || call.method == 'serviceStopped') {
        active = false;
        await onStop
            ?.call(call.arguments as String? ?? 'Android servisi durdu.');
        return true;
      }
      throw MissingPluginException('Unknown bot service event');
    });
  }

  Future<String?> start() async {
    try {
      await _stopping;
      if (!enabled || active) return null;
      final allowed = await channel.invokeMethod<bool>('requestNotifications');
      if (allowed != true) {
        return 'Paper bot için bildirim izni gerekli. İzin verilmeden bot başlatılmadı.';
      }
      active = await channel.invokeMethod<bool>('start') == true;
      return active
          ? null
          : 'Arka plan servisi başlatılamadı. Bot kapalı kaldı.';
    } on PlatformException catch (e) {
      return 'Arka plan servisi: ${e.message ?? e.code}';
    } on MissingPluginException {
      return 'Android bot servisi bulunamadı. Uygulamayı güncelleyin.';
    }
  }

  Future<void> update(String symbol, String state, String connection) async {
    if (!enabled || !active) return;
    try {
      await channel.invokeMethod<void>('update', {
        'symbol': symbol.replaceAll('_', '/'),
        'state': state,
        'connection': connection,
      });
    } on PlatformException {
      active = false;
      await onStop?.call('Android bot bildirimi güncellenemedi.');
    }
  }

  Future<void> stop() {
    if (_stopping != null) return _stopping!;
    if (!enabled || !active) return Future.value();
    active = false;
    final job = channel.invokeMethod<void>('stop');
    _stopping = job.whenComplete(() => _stopping = null);
    return _stopping!;
  }

  void dispose() {
    if (!enabled) return;
    channel.setMethodCallHandler(null);
  }
}
