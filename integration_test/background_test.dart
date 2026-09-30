import 'package:cryptoloop_tr/app_controller.dart';
import 'package:cryptoloop_tr/main.dart';
import 'package:cryptoloop_tr/models.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

// Compiled only into the test APK. No Binance keys, network or live orders.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const native = MethodChannel('cryptoloop/bot_service');
  testWidgets(
      'native paper service runs in background and notification stops it',
      (tester) async {
    final c = AppController(offline: true);
    await c.init();
    await c.resetPaper();
    const rules = SymbolRules(symbol: 'BTC_TRY', minNotional: 10);
    c.market.symbols['BTC_TRY'] = rules;
    c.engine.quote = MarketQuote(
        symbol: 'BTC_TRY', last: 100, bid: 100, ask: 100, time: DateTime.now());
    c.engine.position = Position(
        symbol: 'BTC_TRY',
        quantity: 1,
        entryPrice: 100,
        notional: 100,
        buyFee: 0.15,
        openedAt: DateTime.now(),
        orderId: 'P-device-test');
    await tester.pumpWidget(CryptoLoopApp(controller: c));
    await tester.pumpAndSettle();
    expect(await c.start(), isNull);
    final status = await native.invokeMapMethod<String, dynamic>('status');
    expect(status!['running'], isTrue);
    expect(status['wakeLock'], isTrue);
    expect(c.live, isFalse);
    expect(await native.invokeMethod<bool>('testBackground'), isTrue);
    // A real timer and execution continue after Activity.onStop; no widget pumps.
    await Future<void>.delayed(const Duration(seconds: 2));
    expect(c.engine.running, isTrue);
    await c.engine.onQuote(
        MarketQuote(
            symbol: 'BTC_TRY',
            last: 102,
            bid: 102,
            ask: 102,
            time: DateTime.now()),
        rules);
    expect(c.engine.position, isNull);
    expect(c.engine.events.single.side, 'SAT');
    expect(c.engine.events.single.paper, isTrue);
    expect(c.engine.events.single.pnl, greaterThan(0));
    await native.invokeMethod<bool>('testNotificationStop');
    for (var i = 0; i < 30 && c.engine.running; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(c.engine.running, isFalse);
    await c.save();
    expect(c.store!.read('paper-v2')!['events'], hasLength(1));
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(
        (await native.invokeMapMethod<String, dynamic>('status'))!['running'],
        isFalse);
    c.dispose();
  });
}
