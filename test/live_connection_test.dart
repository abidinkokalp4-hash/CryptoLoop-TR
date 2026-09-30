import 'dart:async';
import 'dart:convert';
import 'package:cryptoloop_tr/app_controller.dart';
import 'package:cryptoloop_tr/bot_background.dart';
import 'package:cryptoloop_tr/execution.dart';
import 'package:cryptoloop_tr/live_execution.dart';
import 'package:cryptoloop_tr/models.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'fixtures/live_preflight.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('preflight is a signed-backend GET and accepts live disabled', () async {
    final requests = <http.Request>[];
    final backend = readOnlyBackend(requests);
    final result = await backend.preflight('BTC_TRY');
    expect(result.availableTry, 1000);
    expect(result.feePct, .15);
    expect(result.liveEnabled, isFalse);
    expect(result.liveProblem(const StrategySettings(), DateTime.now()),
        contains('kapalı'));
    expect(requests.single.method, 'GET');
    expect(requests.single.url.queryParameters['symbol'], 'BTC_TRY');
    expect(requests.single.body, isEmpty);
    expect(requests.single.followRedirects, isFalse);
    backend.close();
  });
  test('backend redirects are rejected before parsing or forwarding token',
      () async {
    final requests = <http.Request>[];
    final backend = BackendClient(
        baseUrl: 'https://test.example.invalid',
        token: 'test-only-control-token-with-32-characters',
        client: MockClient((request) async {
          requests.add(request);
          return http.Response('', 302,
              headers: {'location': 'https://other.example.invalid'});
        }));
    await expectLater(
        backend.preflight('BTC_TRY'), throwsA(isA<ExecutionException>()));
    expect(requests, hasLength(1));
    expect(requests.single.followRedirects, isFalse);
    backend.close();
  });
  test('malformed, stale and fabricated permission proofs fail closed', () {
    final now = DateTime.utc(2026, 9, 30);
    for (final mutate in <void Function(Map<String, dynamic>)>[
      (j) => j['readOnly'] = false,
      (j) => j['withdrawalPermissionVerified'] = true,
      (j) => j['verifiedAt'] =
          now.subtract(const Duration(minutes: 10)).toIso8601String(),
      (j) => (j['account'] as Map)['availableTry'] = 'NaN',
      (j) => (j['market'] as Map)['ask'] = '99',
    ]) {
      final j = preflightJson(time: now);
      mutate(j);
      expect(() => LivePreflight.fromJson(j, now: now),
          throwsA(isA<ExecutionException>()));
    }
  });
  test('live readiness rejects stale symbol, unsafe orders and higher limits',
      () {
    final now = DateTime.utc(2026, 9, 30);
    final result = LivePreflight.fromJson(
        preflightJson(liveEnabled: true, time: now),
        now: now);
    expect(result.liveProblem(const StrategySettings(), now), isNull);
    expect(
        result.liveProblem(
            const StrategySettings(), now.add(const Duration(minutes: 6))),
        isNotNull);
    expect(result.liveProblem(const StrategySettings(symbol: 'ETH_TRY'), now),
        isNotNull);
    expect(result.liveProblem(const StrategySettings(maxCapital: 10001), now),
        contains('sunucu'));
    expect(result.liveProblem(const StrategySettings(dailyLossLimit: 301), now),
        contains('sunucu'));
    final j = preflightJson(liveEnabled: true, time: now);
    (j['reconciliation'] as Map)['openOrderCount'] = 1;
    expect(
        LivePreflight.fromJson(j, now: now)
            .liveProblem(const StrategySettings(), now),
        isNotNull);
  });
  test('existing position cost including buy fee must fit the reviewed cap',
      () {
    final now = DateTime.utc(2026, 9, 30);
    final j = preflightJson(liveEnabled: true, time: now);
    (j['reconciliation'] as Map)['position'] = {
      'symbol': 'BTC_TRY',
      'quantity': '1',
      'notional': '100',
      'buyFee': '0.15'
    };
    final settings = const StrategySettings(maxCapital: 100, maxPosition: 100);
    expect(LivePreflight.fromJson(j, now: now).liveProblem(settings, now),
        contains('pozisyonu'));
    ((j['reconciliation'] as Map)['position'] as Map)['buyFee'] = '0';
    expect(
        LivePreflight.fromJson(j, now: now).liveProblem(settings, now), isNull);
    ((j['reconciliation'] as Map)['position'] as Map)['buyFee'] = 'NaN';
    expect(() => LivePreflight.fromJson(j, now: now),
        throwsA(isA<ExecutionException>()));
  });
  group('account connection controller', () {
    late AppController c;
    late List<http.Request> requests;
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
      c = AppController(
          offline: true, backgroundRunner: BotBackground(enabled: false));
      await c.init();
      requests = [];
      c.backend = readOnlyBackend(requests);
    });
    tearDown(() async {
      c.dispose();
      await Future<void>.delayed(Duration.zero);
    });
    test('read-only account connection leaves paper ledger and bot untouched',
        () async {
      c.engine.cashTry = 5000;
      await c.save();
      final saved = jsonEncode(c.store!.read('paper-v2'));
      expect(await c.verifyLiveAccount(), isNull);
      expect(c.backendCheck!.availableTry, 1000);
      expect(c.engine.cashTry, 5000);
      expect(c.engine.running, isFalse);
      expect(c.live, isFalse);
      expect(jsonEncode(c.store!.read('paper-v2')), saved);
      expect(requests.every((r) => r.method == 'GET'), isTrue);
      expect(await c.activateLive(), contains('kapalı'));
      expect(c.live, isFalse);
    });
    test('failed check clears previous balance instead of showing old success',
        () async {
      expect(await c.verifyLiveAccount(), isNull);
      c.backend!.close();
      c.backend = BackendClient(
          baseUrl: 'https://test.example.invalid',
          token: 'test-only-control-token-with-32-characters',
          client: MockClient((_) async =>
              http.Response('{"error":"Yetki/IP kontrolü gerekli"}', 403)));
      expect(await c.verifyLiveAccount(), contains('Yetki/IP'));
      expect(c.backendCheck, isNull);
      expect(c.backendCheckError, isNotEmpty);
      expect(c.live, isFalse);
    });
    test('switching to live never arms and keeps freshly reviewed limits',
        () async {
      c.backend!.close();
      c.backend = readOnlyBackend(requests, liveEnabled: true);
      await c.store!.write(
          'live-v2',
          c.engine.toJson()
            ..['settings'] =
                const StrategySettings(maxCapital: 50000).toJson());
      expect(await c.verifyLiveAccount(), isNull);
      expect(await c.activateLive(), isNull);
      expect(c.live, isTrue);
      expect(c.engine.running, isFalse);
      expect(c.engine.settings.maxCapital, 10000);
      expect(requests.every((r) => r.method == 'GET'), isTrue);
    });
    test('a pending account check blocks start and setting changes', () async {
      final response = Completer<http.Response>();
      c.backend!.close();
      c.backend = BackendClient(
          baseUrl: 'https://test.example.invalid',
          token: 'test-only-control-token-with-32-characters',
          client: MockClient((_) => response.future));
      final pending = c.verifyLiveAccount();
      expect(c.checkingBackend, isTrue);
      expect(await c.start(), isNotNull);
      expect(await c.applySettings(const StrategySettings(symbol: 'ETH_TRY')),
          isNotNull);
      response.complete(http.Response(
          jsonEncode(portfolioPreflightJson(c.engine.settings.symbols)), 200));
      expect(await pending, isNull);
      expect(c.checkingBackend, isFalse);
      expect(c.live, isFalse);
    });
  });
}
