import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:cryptoloop_tr/trading_engine.dart';
import 'package:cryptoloop_tr/execution.dart';
import 'package:cryptoloop_tr/live_execution.dart';
import 'fixtures/live_preflight.dart';

class MultiHarness {
  MultiHarness(
      {Map<String, dynamic> overrides = const {},
      ExecutionAdapter? execution}) {
    final json =
        const StrategySettings(symbols: StrategySettings.defaultWatchlist)
            .toJson()
          ..addAll({
            'startingBalance': 20000,
            'capitalPct': 100,
            'maxCapital': 10000,
            'maxPosition': 1000,
            'feePct': 0,
            'slippagePct': 0,
            'windowSize': 3,
            'observationSeconds': 2,
            'cooldownSeconds': 0,
            'dailyLossLimit': 1000,
            'maxTradesPerDay': 30
          })
          ..addAll(overrides);
    engine = TradingEngine(
        settings: StrategySettings.fromJson(json),
        clock: () => now,
        execution: execution)
      ..start();
  }
  DateTime now = DateTime.utc(2026, 9, 30, 8);
  late TradingEngine engine;
  Future<void> tick(String symbol, double price) => engine.onQuote(
      MarketQuote(
          symbol: symbol, last: price, bid: price, ask: price, time: now),
      SymbolRules(symbol: symbol, minNotional: 10));
  Future<void> enterAll() async {
    for (final price in [100.0, 99.5, 99.6]) {
      for (final symbol in engine.settings.symbols) {
        await tick(symbol, price);
      }
      now = now.add(const Duration(seconds: 1));
    }
  }
}

class GatedPaper extends PaperExecution {
  final release = Completer<void>();
  int submitted = 0;
  @override
  Future<Fill> buy(
      {required MarketQuote quote,
      required SymbolRules rules,
      required StrategySettings settings,
      required double budget,
      required String intentId}) async {
    submitted++;
    await release.future;
    return super.buy(
        quote: quote,
        rules: rules,
        settings: settings,
        budget: budget,
        intentId: intentId);
  }
}

class FailedLiveExecution extends PaperExecution {
  int halts = 0;
  @override
  bool get isPaper => false;
  @override
  Future<void> halt() async {
    halts++;
  }

  @override
  Future<Fill> buy(
      {required MarketQuote quote,
      required SymbolRules rules,
      required StrategySettings settings,
      required double budget,
      required String intentId}) async {
    throw const ExecutionException('timeout', uncertain: true);
  }
}

class InvalidFillExecution extends PaperExecution {
  @override
  Future<Fill> buy(
          {required MarketQuote quote,
          required SymbolRules rules,
          required StrategySettings settings,
          required double budget,
          required String intentId}) async =>
      Fill(
          orderId: 'invalid-test-only',
          quantity: 1,
          price: double.nan,
          notional: double.nan,
          fee: 0,
          time: quote.time);
}

void main() {
  test('ten positions share one cash balance, capital limit and entry counter',
      () async {
    final h = MultiHarness();
    await h.enterAll();
    expect(h.engine.positions, hasLength(10));
    expect(h.engine.dailyEntries, 10);
    expect(h.engine.cashTry, closeTo(10000, 1e-6));
    expect(h.engine.investedBasis, closeTo(10000, 1e-6));
    expect(h.engine.events.where((t) => t.side == 'AL'), hasLength(10));
    expect(h.engine.markValue, closeTo(20000, 1e-6));
  });
  test('fee included aggregate exposure never exceeds shared capital',
      () async {
    final h = MultiHarness(
        overrides: {'maxCapital': 1500, 'feePct': 0.15, 'slippagePct': 0.05});
    await h.enterAll();
    expect(h.engine.positions, hasLength(2));
    expect(h.engine.investedBasis, lessThanOrEqualTo(1500.000001));
    expect(h.engine.investedBasis, closeTo(1500, 1e-6));
    expect(h.engine.positions.values.every((p) => p.buyFee > 0), isTrue);
  });
  test('maximum open positions is shared across every coin', () async {
    final h = MultiHarness(overrides: {'maxOpenPositions': 3});
    await h.enterAll();
    expect(h.engine.positions, hasLength(3));
    expect(h.engine.dailyEntries, 3);
  });
  test('daily entries are global rather than per coin', () async {
    final h = MultiHarness(overrides: {'maxTradesPerDay': 2});
    await h.enterAll();
    expect(h.engine.positions, hasLength(2));
    expect(h.engine.dailyEntries, 2);
  });
  test('a quote only revalues and exits its own coin', () async {
    final h = MultiHarness();
    await h.enterAll();
    final eth = h.engine.coin('ETH_TRY').position!;
    await h.tick('BTC_TRY', 102);
    expect(h.engine.coin('BTC_TRY').position, isNull);
    expect(h.engine.coin('ETH_TRY').position, same(eth));
    expect(h.engine.positions, hasLength(9));
    expect(h.engine.events.first.symbol, 'BTC_TRY');
    expect(h.engine.coin('ETH_TRY').lastSellPrice, 0);
  });
  test('stop loss closes affected coin while leaving others managed', () async {
    final h = MultiHarness();
    await h.enterAll();
    await h.tick('ETH_TRY', 95);
    expect(h.engine.coin('ETH_TRY').position, isNull);
    expect(h.engine.coin('BTC_TRY').position, isNotNull);
    expect(h.engine.events.first.reason, 'Stop loss');
    expect(h.engine.events.first.pnl, lessThan(0));
  });
  test('daily loss in one coin blocks new entries in all other coins',
      () async {
    final h = MultiHarness(overrides: {
      'maxOpenPositions': 1,
      'dailyLossLimit': 10,
      'stopLossPct': 50
    });
    await h.enterAll();
    h.engine.settings = StrategySettings.fromJson(
        h.engine.settings.toJson()..['maxOpenPositions'] = 10);
    await h.tick('BTC_TRY', 95);
    for (final p in [100.0, 99.5, 99.6]) {
      await h.tick('ETH_TRY', p);
      h.now = h.now.add(const Duration(seconds: 1));
    }
    expect(h.engine.riskLocked, isTrue);
    expect(h.engine.positions.keys, ['BTC_TRY']);
  });
  test('stale held coin blocks another purchase but not a fresh risk exit',
      () async {
    final h = MultiHarness(overrides: {'maxOpenPositions': 1});
    await h.enterAll();
    h.engine.settings = StrategySettings.fromJson(
        h.engine.settings.toJson()..['maxOpenPositions'] = 10);
    h.now = h.now.add(const Duration(seconds: 30));
    for (final p in [100.0, 99.5, 99.6]) {
      await h.tick('ETH_TRY', p);
      h.now = h.now.add(const Duration(seconds: 1));
    }
    expect(h.engine.coin('ETH_TRY').position, isNull);
    expect(h.engine.coin('ETH_TRY').message, contains('güncel'));
    await h.tick('BTC_TRY', 95);
    expect(h.engine.coin('BTC_TRY').position, isNull);
  });
  test('sold coin will not chase while another coin independently remains held',
      () async {
    final h = MultiHarness();
    await h.enterAll();
    await h.tick('BTC_TRY', 102);
    for (final p in [103.0, 104.0, 105.0, 106.0]) {
      await h.tick('BTC_TRY', p);
      h.now = h.now.add(const Duration(seconds: 1));
    }
    expect(h.engine.coin('BTC_TRY').position, isNull);
    expect(h.engine.coin('ETH_TRY').position, isNotNull);
    expect(h.engine.coin('BTC_TRY').lastSellPrice, 102);
    expect(h.engine.coin('ETH_TRY').lastSellPrice, 0);
  });
  test('reentry history and quotes survive selecting a different chart',
      () async {
    final h = MultiHarness();
    await h.enterAll();
    await h.tick('BTC_TRY', 102);
    h.engine.settings = StrategySettings.fromJson(
        h.engine.settings.toJson()..['symbol'] = 'ETH_TRY');
    expect(h.engine.position!.symbol, 'ETH_TRY');
    expect(h.engine.coin('BTC_TRY').lastSellPrice, 102);
    expect(h.engine.quoteFor('BTC_TRY')!.last, 102);
  });
  test(
      'multi ledger round trip preserves all positions without duplicated cash',
      () async {
    final h = MultiHarness(overrides: {'feePct': 0.15});
    await h.enterAll();
    final restored = TradingEngine()
      ..restore(
          jsonDecode(jsonEncode(h.engine.toJson())) as Map<String, dynamic>);
    expect(restored.positions, hasLength(10));
    expect(restored.cashTry, h.engine.cashTry);
    expect(restored.investedBasis, closeTo(h.engine.investedBasis, 1e-6));
    expect(restored.dailyEntries, 10);
    expect(restored.running, isFalse);
    expect(restored.events, hasLength(10));
  });
  test(
      'old single coin snapshot migrates without resetting balance or buy fees',
      () async {
    final h = MultiHarness(overrides: {
      'symbols': ['BTC_TRY']
    });
    await h.enterAll();
    final old = h.engine.toJson()
      ..remove('coins')
      ..['schema'] = 2;
    (old['settings'] as Map).remove('symbols');
    final restored = TradingEngine()..restore(old);
    expect(restored.positions, hasLength(1));
    expect(restored.position!.costBasis, h.engine.position!.costBasis);
    expect(restored.cashTry, h.engine.cashTry);
    expect(restored.events, hasLength(1));
  });
  test('emergency stops all coins and preserves ten open positions', () async {
    final h = MultiHarness();
    await h.enterAll();
    await h.engine.stop(emergency: true);
    for (final s in h.engine.settings.symbols) {
      await h.tick(s, 110);
    }
    expect(h.engine.positions, hasLength(10));
    expect(h.engine.events, hasLength(10));
    expect(h.engine.running, isFalse);
  });
  test(
      'simultaneous coin signals serialize execution and share remaining capital',
      () async {
    final adapter = GatedPaper(),
        h = MultiHarness(overrides: {
          'symbols': ['BTC_TRY', 'ETH_TRY'],
          'maxCapital': 1500
        }, execution: adapter);
    for (final p in [100.0, 99.5]) {
      await h.tick('BTC_TRY', p);
      await h.tick('ETH_TRY', p);
      h.now = h.now.add(const Duration(seconds: 1));
    }
    final pending = h.tick('BTC_TRY', 99.6);
    await Future<void>.delayed(Duration.zero);
    await h.tick('ETH_TRY', 99.6);
    expect(adapter.submitted, 1);
    adapter.release.complete();
    await pending;
    h.now = h.now.add(const Duration(seconds: 1));
    await h.tick('ETH_TRY', 99.7);
    expect(h.engine.positions, hasLength(2));
    expect(h.engine.investedBasis, closeTo(1500, 1e-6));
  });
  test('multi preflight requires all pairs and checks aggregate existing basis',
      () {
    final now = DateTime.now(),
        settings = const StrategySettings(
            symbols: ['BTC_TRY', 'ETH_TRY'],
            maxCapital: 1000,
            maxPosition: 1000);
    final json =
        portfolioPreflightJson(settings.symbols, liveEnabled: true, time: now);
    for (final c in json['checks'] as List) {
      (c['reconciliation'] as Map)['position'] = {
        'symbol': c['symbol'],
        'quantity': '1',
        'notional': '600',
        'buyFee': '1'
      };
    }
    final check = LivePreflight.fromPortfolioJson(json, now: now);
    expect(check.availableTry, 1000);
    expect(check.liveProblem(settings, now), contains('toplam'));
    expect(check.liveProblem(const StrategySettings(), now), contains('bütün'));
    (json['checks'] as List).removeLast();
    expect(() => LivePreflight.fromPortfolioJson(json, now: now),
        throwsA(isA<ExecutionException>()));
  });
  test('uncertain live fill disarms execution for the whole portfolio',
      () async {
    final adapter = FailedLiveExecution(), h = MultiHarness(execution: adapter);
    await h.enterAll();
    expect(h.engine.running, isFalse);
    expect(h.engine.uncertainOrder, isTrue);
    expect(adapter.halts, 1);
    expect(h.engine.events, isEmpty);
    expect(h.engine.positions, isEmpty);
  });
  test('nonfinite fill never corrupts shared cash or creates a position',
      () async {
    final h = MultiHarness(execution: InvalidFillExecution());
    await h.enterAll();
    expect(h.engine.cashTry, 20000);
    expect(h.engine.uncertainOrder, isTrue);
    expect(h.engine.positions, isEmpty);
  });
  test('duplicate and non TRY selections and zero position limit are invalid',
      () {
    for (final settings in [
      const StrategySettings(symbols: ['BTC_TRY', 'BTC_TRY']),
      const StrategySettings(symbols: ['BTC_TRY', 'ETH_USDT']),
      const StrategySettings(maxOpenPositions: 0)
    ]) {
      expect(settings.validate(), isNotNull);
    }
  });
}
