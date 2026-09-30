import 'dart:async';
import 'package:cryptoloop_tr/app_controller.dart';
import 'package:cryptoloop_tr/bot_background.dart';
import 'package:cryptoloop_tr/models.dart';
import 'package:cryptoloop_tr/live_execution.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'fixtures/live_preflight.dart';

const channel = MethodChannel('cryptoloop/bot_service');

class DeferredBackend extends BackendClient {
  DeferredBackend()
      : super(
            baseUrl: 'https://example.invalid',
            token: 'test-only-token-with-32-characters');
  final armed = Completer<void>(), release = Completer<void>();
  int halts = 0;
  @override
  Future<Map<String, dynamic>> request(String path,
      {Map<String, dynamic>? body}) async {
    if (path != '/v1/halt') throw StateError('Unexpected backend operation');
    halts++;
    return {};
  }

  @override
  Future<Map<String, dynamic>> reconcile(String symbol) async =>
      {'safe': true, 'availableTry': 10000};
  @override
  Future<LivePreflight> preflight(String symbol) async =>
      LivePreflight.fromJson(preflightJson(liveEnabled: true));
  @override
  Future<void> arm(StrategySettings settings) async {
    armed.complete();
    await release.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late List<String> calls;
  late BotBackground runner;
  late AppController c;
  Future<void> Function(MethodCall)? beforeCall;
  bool permission = true, service = true;

  setUp(() async {
    calls = [];
    permission = service = true;
    beforeCall = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      await beforeCall?.call(call);
      if (call.method == 'requestNotifications') return permission;
      if (call.method == 'start') return service;
      return null;
    });
    SharedPreferences.setMockInitialValues({});
    runner = BotBackground(enabled: true);
    c = AppController(offline: true, backgroundRunner: runner);
    await c.init();
    c.market.symbols['BTC_TRY'] = const SymbolRules(symbol: 'BTC_TRY');
    c.engine.quote = MarketQuote(
        symbol: 'BTC_TRY', last: 100, bid: 100, ask: 100, time: DateTime.now());
  });
  tearDown(() async {
    await c.stop();
    c.dispose();
    await Future<void>.delayed(Duration.zero);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });
  test('paper survives background, one engine and balance are retained',
      () async {
    final e = c.engine;
    expect(await c.start(), isNull);
    expect(runner.active, isTrue);
    await c.background();
    expect(c.engine, same(e));
    expect(e.running, isTrue);
    expect(e.cashTry, 10000);
    expect(calls.where((v) => v == 'start'), hasLength(1));
    expect(await c.start(), isNotNull);
    expect(calls.where((v) => v == 'start'), hasLength(1));
  });
  test('notification permission refusal cannot start the engine', () async {
    permission = false;
    expect(await c.start(), contains('bildirim izni'));
    expect(c.engine.running, isFalse);
    expect(calls, isNot(contains('start')));
  });
  test('native foreground service failure cannot start the engine', () async {
    service = false;
    expect(await c.start(), contains('başlatılamadı'));
    expect(c.engine.running, isFalse);
    expect(runner.active, isFalse);
  });
  test('emergency while service starts cancels pending start', () async {
    final entered = Completer<void>(), release = Completer<void>();
    beforeCall = (call) async {
      if (call.method == 'start') {
        entered.complete();
        await release.future;
      }
    };
    final pending = c.start();
    await entered.future;
    await c.stop(emergency: true);
    release.complete();
    expect(await pending, contains('iptal'));
    expect(c.engine.running, isFalse);
    expect(runner.active, isFalse);
    expect(calls, contains('stop'));
  });
  test('native stop action halts strategy and persists paper position',
      () async {
    c.engine.position = Position(
        symbol: 'BTC_TRY',
        quantity: 1,
        entryPrice: 100,
        notional: 100,
        buyFee: 0.15,
        openedAt: DateTime.now(),
        orderId: 'P-background');
    await c.start();
    // Same callback used by the native notification action and service shutdown.
    await runner.onStop!('Bildirimden acil durdurma');
    expect(c.engine.running, isFalse);
    expect(c.engine.position?.orderId, 'P-background');
    expect(c.store!.read('paper-v2')!['position'], isNotNull);
    expect(c.engine.events, isEmpty);
  });
  test('live mode still stops on background and never starts paper service',
      () async {
    c.live = true;
    c.engine.start();
    await c.background();
    expect(c.engine.running, isFalse);
    expect(calls, isNot(contains('start')));
  });
  test('process restore retains position but never restarts bot', () async {
    await c.start();
    c.engine.position = Position(
        symbol: 'BTC_TRY',
        quantity: 1,
        entryPrice: 100,
        notional: 100,
        buyFee: 0.15,
        openedAt: DateTime.now(),
        orderId: 'P-restart');
    await c.save();
    await c.stop();
    final restored = AppController(
        offline: true, backgroundRunner: BotBackground(enabled: false));
    await restored.init();
    expect(restored.engine.position?.orderId, 'P-restart');
    expect(restored.engine.running, isFalse);
    expect(restored.live, isFalse);
    restored.dispose();
  });
  test('live start cancelled during arm is halted again after acknowledgement',
      () async {
    final backend = DeferredBackend();
    c.backend = backend;
    c.live = true;
    c.engine.execution = BinanceTrExecution(backend);
    final pending = c.start();
    await backend.armed.future;
    await c.background();
    backend.release.complete();
    expect(await pending, contains('iptal'));
    expect(c.engine.running, isFalse);
    expect(backend.halts, 2);
  });
}
