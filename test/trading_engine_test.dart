import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:cryptoloop_tr/execution.dart';
import 'package:cryptoloop_tr/trading_engine.dart';

class Harness {
  Harness(
      [Map<String, dynamic> overrides = const {}, ExecutionAdapter? adapter]) {
    final j = const StrategySettings().toJson()
      ..addAll({
        'startingBalance': 1000,
        'capitalPct': 100,
        'maxCapital': 1000,
        'maxPosition': 1000,
        'feePct': 0,
        'slippagePct': 0,
        'windowSize': 3,
        'observationSeconds': 2,
        'cooldownSeconds': 0,
        'flatRangePct': 0.15,
        'entryDropPct': 0.25,
        'reboundPct': 0.05,
        'reentryDropPct': 0.3,
        'dailyLossLimit': 100,
      })
      ..addAll(overrides);
    engine = TradingEngine(
        settings: StrategySettings.fromJson(j),
        clock: () => now,
        execution: adapter)
      ..start();
  }
  DateTime now = DateTime.utc(2026, 9, 30, 8);
  late TradingEngine engine;
  SymbolRules rules = const SymbolRules(symbol: 'BTC_TRY', minNotional: 10);
  MarketQuote q(double p, {double? bid, double? ask}) => MarketQuote(
      symbol: 'BTC_TRY', last: p, bid: bid ?? p, ask: ask ?? p, time: now);
  Future<void> tick(double p, {double? bid, double? ask}) async {
    await engine.onQuote(q(p, bid: bid, ask: ask), rules);
    now = now.add(const Duration(seconds: 1));
  }

  Future<void> enter() async {
    await tick(100);
    await tick(99.5);
    await tick(99.6);
  }

  Future<void> sell() async {
    await tick(101);
  }
}

class DelayedExecution extends PaperExecution {
  final gate = Completer<void>();
  int buys = 0;
  @override
  Future<Fill> buy(
      {required MarketQuote quote,
      required SymbolRules rules,
      required StrategySettings settings,
      required double budget,
      required String intentId}) async {
    buys++;
    await gate.future;
    return super.buy(
        quote: quote,
        rules: rules,
        settings: settings,
        budget: budget,
        intentId: intentId);
  }
}

class UncertainExecution extends PaperExecution {
  @override
  Future<Fill> buy(
      {required MarketQuote quote,
      required SymbolRules rules,
      required StrategySettings settings,
      required double budget,
      required String intentId}) async {
    throw const ExecutionException('Emir sonucu bilinmiyor', uncertain: true);
  }
}

void main() {
  test('starts stopped, no automatic first-tick purchase', () async {
    final h = Harness();
    expect(TradingEngine().state, BotState.stopped);
    await h.tick(100);
    expect(h.engine.position, isNull);
    expect(h.engine.events, isEmpty);
  });
  test('confirmed pullback opens a position', () async {
    final h = Harness();
    await h.enter();
    expect(h.engine.state, BotState.holding);
    expect(h.engine.events.single.side, 'AL');
  });
  test('no entry while market only rises', () async {
    final h = Harness();
    for (final p in [100.0, 101.0, 102.0, 103.0, 104.0]) {
      await h.tick(p);
    }
    expect(h.engine.events, isEmpty);
  });
  test('flat market without rebound is not a signal', () async {
    final h = Harness();
    for (var i = 0; i < 10; i++) {
      await h.tick(100);
    }
    expect(h.engine.position, isNull);
  });
  test('minimum net profit, including both fees', () async {
    final h = Harness({'feePct': 0.1});
    await h.enter();
    final basis = h.engine.position!.costBasis;
    expect(basis, closeTo(1000, 1e-8));
    await h.tick(99.9);
    expect(h.engine.position, isNotNull);
    await h.tick(100.2);
    expect(h.engine.position, isNull);
    expect(h.engine.realizedPnl, greaterThanOrEqualTo(basis * 0.003));
  });
  test('buy fee is never omitted from realized cost basis', () async {
    final h = Harness({'feePct': 0.1});
    await h.enter();
    final p = h.engine.position!;
    await h.tick(101);
    final expected = p.quantity * 101 * 0.999 - p.notional - p.buyFee;
    expect(h.engine.realizedPnl, closeTo(expected, 1e-8));
    expect(h.engine.cashTry - 1000, closeTo(expected, 1e-8));
  });
  test('sell fee reduces cash proceeds', () async {
    final h = Harness({'feePct': 0.2});
    await h.enter();
    await h.sell();
    final e = h.engine.events.first;
    expect(e.fee, closeTo(e.quantity * e.price * 0.002, 1e-8));
  });
  test('spread executes at ask on buy and bid on sell', () async {
    final h = Harness({'maxSpreadPct': 2});
    await h.tick(100, bid: 99.9, ask: 100.1);
    await h.tick(99.5, bid: 99.4, ask: 99.6);
    await h.tick(99.6, bid: 99.5, ask: 99.7);
    expect(h.engine.position!.entryPrice, 99.7);
    await h.tick(101, bid: 100.9, ask: 101.1);
    expect(h.engine.events.first.price, 100.9);
    expect(h.engine.realizedPnl, lessThan(1000 * (101 / 99.6 - 1)));
  });
  test('slippage executes adversely on both sides without double counting',
      () async {
    final h = Harness({'slippagePct': 0.1});
    await h.enter();
    final p = h.engine.position!;
    expect(p.entryPrice, closeTo(99.6 * 1.001, 1e-8));
    await h.tick(101);
    expect(h.engine.events.first.price, closeTo(101 * 0.999, 1e-8));
    expect(h.engine.realizedPnl,
        closeTo(p.quantity * 101 * 0.999 - p.costBasis, 1e-8));
  });
  test('paper unchanged market loses both fees plus spread/slippage', () async {
    const s = StrategySettings(feePct: 0.1, slippagePct: 0.1);
    final q = Harness().q(100, bid: 99.9, ask: 100.1);
    final a = PaperExecution();
    const r = SymbolRules(symbol: 'BTC_TRY');
    final b = await a.buy(
        quote: q, rules: r, settings: s, budget: 1000, intentId: '1');
    final p = Position(
        symbol: q.symbol,
        quantity: b.quantity,
        entryPrice: b.price,
        notional: b.notional,
        buyFee: b.fee,
        openedAt: q.time,
        orderId: b.orderId);
    final f = await a.sell(
        quote: q, rules: r, settings: s, position: p, intentId: '2');
    expect(f.sellProceeds - p.costBasis, lessThan(-5.9));
    expect(PositionMetrics(p, q, s).netPnl,
        closeTo(f.sellProceeds - p.costBasis, 1e-8));
  });
  test('required sale price is the actual net-profit threshold', () async {
    final h = Harness({'feePct': 0.15, 'slippagePct': 0.05});
    await h.enter();
    final required = h.engine.metrics!.requiredBid;
    await h.tick(required - 0.001);
    expect(h.engine.position, isNotNull);
    await h.tick(required + 0.001);
    expect(h.engine.position, isNull);
  });
  test('stop loss can sell at a net loss', () async {
    final h = Harness();
    await h.enter();
    await h.tick(97);
    expect(h.engine.position, isNull);
    expect(h.engine.realizedPnl, lessThan(0));
    expect(h.engine.events.first.reason, 'Stop loss');
  });
  test('does not chase rising price after sale', () async {
    final h = Harness();
    await h.enter();
    await h.sell();
    for (final p in [102.0, 103.0, 104.0, 104.01, 104.08]) {
      await h.tick(p);
    }
    expect(h.engine.events.length, 2);
    expect(h.engine.state, BotState.waitingReentry);
  });
  test('pullback reentry needs recovery confirmation', () async {
    final h = Harness();
    await h.enter();
    await h.sell();
    await h.tick(100.6);
    await h.tick(100.5);
    expect(h.engine.position, isNull);
    await h.tick(100.6);
    expect(h.engine.position, isNotNull);
  });
  test('consolidation below exit permits confirmed reentry', () async {
    final h = Harness({'reentryDropPct': 1});
    await h.enter();
    await h.sell();
    await h.tick(100.90);
    await h.tick(100.85);
    await h.tick(100.92);
    expect(h.engine.position, isNotNull);
  });
  test('flat recovery above exit does not chase', () async {
    final h = Harness({'reentryDropPct': 1});
    await h.enter();
    await h.sell();
    await h.tick(101.2);
    await h.tick(101.15);
    await h.tick(101.23);
    expect(h.engine.position, isNull);
  });
  test('cooldown blocks immediate reentry', () async {
    final h = Harness({'cooldownSeconds': 20});
    await h.enter();
    await h.sell();
    await h.tick(100);
    await h.tick(99.5);
    await h.tick(99.6);
    expect(h.engine.position, isNull);
  });
  test('daily loss locks new entries, including unrealized losses', () async {
    final h = Harness({'dailyLossLimit': 10, 'stopLossPct': 2});
    await h.enter();
    await h.tick(97);
    expect(h.engine.riskLocked, isTrue);
    await h.tick(96);
    await h.tick(95.5);
    await h.tick(95.6);
    expect(h.engine.events.length, 2);
    expect(h.engine.state, BotState.riskLock);
  });
  test('daily entry count does not block a necessary risk exit', () async {
    final h = Harness({'maxTradesPerDay': 1});
    await h.enter();
    await h.tick(97);
    expect(h.engine.position, isNull);
    await h.tick(96);
    await h.tick(95.5);
    await h.tick(95.6);
    expect(h.engine.events.length, 2);
  });
  test('maximum position and maximum capital include buy fees', () async {
    final h = Harness({'maxCapital': 200, 'maxPosition': 100, 'feePct': 0.15});
    await h.enter();
    expect(h.engine.position!.costBasis, lessThanOrEqualTo(100.000001));
    expect(h.engine.cashTry, greaterThanOrEqualTo(899.999999));
  });
  test('minimum order notional blocks entry', () async {
    final h = Harness({'maxCapital': 5, 'maxPosition': 5});
    await h.enter();
    expect(h.engine.events, isEmpty);
  });
  test('wide spread blocks entry', () async {
    final h = Harness();
    await h.tick(100, bid: 99, ask: 101);
    await h.tick(99.5, bid: 98.5, ask: 100.5);
    await h.tick(99.6, bid: 98.6, ask: 100.6);
    expect(h.engine.position, isNull);
  });
  test('lot rounding never exceeds budget', () async {
    final h = Harness();
    h.rules =
        const SymbolRules(symbol: 'BTC_TRY', minNotional: 10, stepSize: 0.01);
    await h.enter();
    expect(h.engine.position!.quantity, closeTo(10.04, 1e-8));
    expect(h.engine.cashTry, greaterThan(0));
  });
  test('stale or invalid quote never causes trade', () async {
    final h = Harness();
    final old = MarketQuote(
        symbol: 'BTC_TRY',
        last: 99.6,
        bid: 99.6,
        ask: 99.6,
        time: h.now.subtract(const Duration(minutes: 1)));
    await h.engine.onQuote(old, h.rules);
    expect(h.engine.quote, isNull);
    await h.engine.onQuote(h.q(double.nan), h.rules);
    expect(h.engine.quote, isNull);
  });
  test('pause blocks new entries but maintains stop loss', () async {
    final h = Harness();
    await h.enter();
    h.engine.pauseEntries();
    await h.tick(97);
    expect(h.engine.position, isNull);
    await h.tick(96);
    await h.tick(95.5);
    await h.tick(95.6);
    expect(h.engine.events.length, 2);
  });
  test('emergency stops all activity without an unauthorized liquidation',
      () async {
    final h = Harness();
    await h.enter();
    await h.engine.stop(emergency: true);
    await h.tick(50);
    expect(h.engine.position, isNotNull);
    expect(h.engine.events.length, 1);
    expect(h.engine.state, BotState.stopped);
  });
  test('concurrent ticks cannot submit duplicate buys', () async {
    final a = DelayedExecution();
    final h = Harness({}, a);
    await h.tick(100);
    await h.tick(99.5);
    final pending = h.tick(99.6);
    await Future<void>.delayed(Duration.zero);
    await h.tick(99.7);
    expect(a.buys, 1);
    a.gate.complete();
    await pending;
  });
  test('stop during in-flight fill preserves filled position but stays stopped',
      () async {
    final a = DelayedExecution();
    final h = Harness({}, a);
    await h.tick(100);
    await h.tick(99.5);
    final pending = h.tick(99.6);
    await Future<void>.delayed(Duration.zero);
    await h.engine.stop(emergency: true);
    a.gate.complete();
    await pending;
    expect(h.engine.position, isNotNull);
    expect(h.engine.running, isFalse);
    expect(h.engine.state, BotState.stopped);
  });
  test('unknown execution outcome cannot be retried automatically', () async {
    final h = Harness({}, UncertainExecution());
    await h.enter();
    expect(h.engine.uncertainOrder, isTrue);
    h.engine.start();
    expect(h.engine.running, isFalse);
    expect(h.engine.events, isEmpty);
  });
  test('persistence roundtrip preserves cash, basis, history and risk lock',
      () async {
    final h = Harness({'feePct': 0.1});
    await h.enter();
    h.engine.riskLocked = true;
    final e = TradingEngine()..restore(h.engine.toJson());
    expect(e.cashTry, h.engine.cashTry);
    expect(e.position!.costBasis, h.engine.position!.costBasis);
    expect(e.events.length, 1);
    expect(e.riskLocked, isTrue);
    expect(e.running, isFalse);
  });
  test('Istanbul daily reset uses UTC+3 boundary', () {
    expect(TradingEngine.istanbulDay(DateTime.utc(2026, 9, 30, 20, 59)),
        '2026-9-30');
    expect(
        TradingEngine.istanbulDay(DateTime.utc(2026, 9, 30, 21)), '2026-10-1');
  });
  test('invalid dangerous settings are rejected', () {
    expect(const StrategySettings(capitalPct: 101).validate(), isNotNull);
    expect(const StrategySettings(maxCapital: 100, maxPosition: 200).validate(),
        isNotNull);
    expect(const StrategySettings(symbol: 'BTC_USDT').validate(), isNotNull);
  });
}
