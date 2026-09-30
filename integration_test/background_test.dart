import 'package:cryptoloop_tr/app_controller.dart';
import 'package:cryptoloop_tr/main.dart';
import 'package:cryptoloop_tr/models.dart';
import 'package:flutter/foundation.dart';
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
    for (final symbol in StrategySettings.defaultWatchlist) {
      c.market.symbols[symbol] = SymbolRules(symbol: symbol, minNotional: 10);
      c.engine.coin(symbol).quote = MarketQuote(
          symbol: symbol, last: 100, bid: 100, ask: 100, time: DateTime.now());
      c.engine.coin(symbol).position = Position(
          symbol: symbol,
          quantity: 1,
          entryPrice: 100,
          notional: 100,
          buyFee: 0.15,
          openedAt: DateTime.now(),
          orderId: 'P-device-$symbol');
    }
    c.engine.cashTry = 8998.5;
    expect(c.engine.positions, hasLength(10));
    await tester.pumpWidget(CryptoLoopApp(controller: c));
    await tester.pumpAndSettle();
    expect(await c.start(), isNull);
    final status = await native.invokeMapMethod<String, dynamic>('status');
    expect(status!['running'], isTrue);
    expect(status['wakeLock'], isTrue);
    // The host runner locks the emulator on this marker, before the sale.
    debugPrint('CRYPTOLOOP_PAPER_SERVICE_READY');
    expect(c.live, isFalse);
    expect(await native.invokeMethod<bool>('testBackground'), isTrue);
    // A real timer and execution continue after Activity.onStop; no widget pumps.
    await Future<void>.delayed(const Duration(seconds: 2));
    expect(
        (await native
            .invokeMapMethod<String, dynamic>('status'))!['screenInteractive'],
        isFalse);
    expect(c.engine.running, isTrue);
    for (final symbol in StrategySettings.defaultWatchlist) {
      await c.engine.onQuote(
          MarketQuote(
              symbol: symbol,
              last: 102,
              bid: 102,
              ask: 102,
              time: DateTime.now()),
          c.market.symbols[symbol]!);
    }
    expect(c.engine.positions, isEmpty);
    expect(c.engine.events, hasLength(10));
    expect(
        c.engine.events.every((t) => t.side == 'SAT' && t.paper && t.pnl > 0),
        isTrue);
    debugPrint('CRYPTOLOOP_TEN_COIN_PAPER_EXITS_VERIFIED');
    await native.invokeMethod<bool>('testNotificationStop');
    for (var i = 0; i < 30 && c.engine.running; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(c.engine.running, isFalse);
    await c.save();
    expect(c.store!.read('paper-v2')!['events'], hasLength(10));
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(
        (await native.invokeMapMethod<String, dynamic>('status'))!['running'],
        isFalse);
    c.dispose();
  });
}
