import 'package:flutter_test/flutter_test.dart';
import 'package:cryptoloop_tr/binance_tr_market.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
import 'fixtures/market_socket.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cryptoloop_tr/app_controller.dart';
import 'package:cryptoloop_tr/bot_background.dart';
import 'package:cryptoloop_tr/models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppController c;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    c = AppController(
        offline: true, backgroundRunner: BotBackground(enabled: false));
    await c.init();
  });
  tearDown(() async {
    c.dispose();
    await Future<void>.delayed(Duration.zero);
  });
  Position position(String symbol, double cost) => Position(
      symbol: symbol,
      quantity: 1,
      entryPrice: cost,
      notional: cost,
      buyFee: 1,
      openedAt: DateTime.now(),
      orderId: 'P-$symbol');
  test('new install watches ten coins and never starts automatically', () {
    expect(c.engine.settings.symbols, hasLength(10));
    expect(c.engine.settings.maxOpenPositions, 10);
    expect(c.engine.running, isFalse);
    expect(c.live, isFalse);
    expect(c.engine.events, isEmpty);
  });
  test('held nonprimary coin prevents removal, reset and live mode switching',
      () async {
    c.engine.coin('ETH_TRY').position = position('ETH_TRY', 100);
    expect(await c.applySettings(const StrategySettings()),
        contains('çıkarılamaz'));
    expect(await c.resetPaper(), contains('Açık'));
    expect(await c.activateLive(), contains('paper pozisyonu'));
    expect(c.engine.coin('ETH_TRY').position, isNotNull);
    expect(c.live, isFalse);
  });
  test('lower capital checks all positions including their buy fees', () async {
    c.engine.coin('BTC_TRY').position = position('BTC_TRY', 1000);
    c.engine.coin('ETH_TRY').position = position('ETH_TRY', 1000);
    final json = c.engine.settings.toJson()..['maxCapital'] = 2000;
    expect(await c.applySettings(StrategySettings.fromJson(json)),
        contains('altına'));
    expect(c.engine.settings.maxCapital, 10000);
  });
  test(
      'failed initial catalog preserves automatic ten pair selection across restart',
      () async {
    await c.save();
    final socket = FakeSocket(),
        market = BinanceTrMarket(
            socketConnector: (_) => socket,
            client: MockClient((_) async => http.Response('{}', 503)));
    const available = [
      'BTC_TRY',
      'ETH_TRY',
      'LTC_TRY',
      'NEAR_TRY',
      'TRX_TRY',
      'ATOM_TRY',
      'ETC_TRY',
      'BCH_TRY',
      'ALGO_TRY',
      'FIL_TRY'
    ];
    for (final s in available) {
      market.symbols[s] = SymbolRules(symbol: s);
    }
    final restored = AppController(
        offline: true,
        market: market,
        backgroundRunner: BotBackground(enabled: false));
    await restored.init();
    await restored.reconnect();
    expect(restored.engine.settings.symbols.toSet(), available.toSet());
    expect(restored.engine.settings.symbols, hasLength(10));
    expect(restored.engine.cashTry, 10000);
    expect(restored.engine.running, isFalse);
    restored.dispose();
    await Future<void>.delayed(Duration.zero);
    await socket.frames.close();
  });
  test('changing chart is independent of settings and all coin ledger state',
      () async {
    c.engine.coin('BTC_TRY').lastSellPrice = 100;
    c.engine.coin('ETH_TRY').position = position('ETH_TRY', 50);
    final cash = c.engine.cashTry;
    await c.selectSymbol('ETH_TRY');
    expect(c.selectedSymbol, 'ETH_TRY');
    expect(c.engine.settings.symbol, 'BTC_TRY');
    expect(c.engine.coin('BTC_TRY').lastSellPrice, 100);
    expect(c.engine.positions.keys, ['ETH_TRY']);
    expect(c.engine.cashTry, cash);
  });
}
