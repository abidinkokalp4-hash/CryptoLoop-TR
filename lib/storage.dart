import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

class AppStore {
  AppStore(this.preferences);
  final SharedPreferences preferences;
  Future<void> _tail = Future.value();
  Map<String, dynamic>? read(String key) {
    final raw = preferences.getString(key);
    if (raw == null) return null;
    try {
      return (jsonDecode(raw) as Map).cast<String, dynamic>();
    } catch (_) {
      throw const FormatException('Kayıt okunamadı. Veriler sıfırlanmadı.');
    }
  }

  Future<void> write(String key, Map<String, dynamic> snapshot) {
    final raw = jsonEncode(snapshot);
    final job = _tail.catchError((_) {}).then((_) async {
      if (!await preferences.setString(key, raw)) {
        throw StateError('Kalıcı kayıt yazılamadı.');
      }
    });
    _tail = job;
    return job;
  }
}
