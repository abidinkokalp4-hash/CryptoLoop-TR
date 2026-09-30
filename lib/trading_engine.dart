import 'dart:collection';
import 'dart:math' as math;
import 'execution.dart';
import 'models.dart';
export 'models.dart';

class RiskManager {
  double budget(StrategySettings s, double cash,
          {double invested = 0}) =>
      math.max(
          0,
          math.min(math.min(cash * s.capitalPct / 100, s.maxPosition),
              math.min(s.maxCapital - invested, cash)));
  String? entryBlock(StrategySettings s, MarketQuote q, double cash,
      SymbolRules rules, int dailyEntries, bool locked,
      {double invested = 0,
      int openPositions = 0,
      bool stalePositions = false}) {
    if (locked) return 'Günlük zarar sınırı aşıldı. Yeni alımlar kilitli.';
    if (dailyEntries >= s.maxTradesPerDay) {
      return 'Günlük maksimum alım sayısına ulaşıldı.';
    }
    if (stalePositions) {
      return 'Açık pozisyonların güncel fiyatları bekleniyor; yeni alım açılmaz.';
    }
    if (openPositions >= s.maxOpenPositions) {
      return 'Eşzamanlı pozisyon sınırına ulaşıldı.';
    }
    if (s.maxCapital - invested <= 0.000001) {
      return 'Toplam sermaye sınırı dolu.';
    }
    if (q.spreadPct > s.maxSpreadPct) {
      return 'Spread sınırın üzerinde; alım bekletiliyor.';
    }
    final price = q.ask * (1 + s.slippageRate);
    return rules.validateOrder(
        rules.floorQuantity(
            budget(s, cash, invested: invested) / (price * (1 + s.feeRate))),
        price);
  }
}

class CoinState {
  Position? position;
  MarketQuote? quote;
  double lastSellPrice = 0, observedPeak = 0;
  DateTime? lastSellTime, observedSince, lastSampleTime;
  BotState state = BotState.stopped;
  String message = 'Piyasa verisi bekleniyor';
  final Queue<double> window = Queue<double>();
  void clearObservation() {
    window.clear();
    observedSince = lastSampleTime = null;
    observedPeak = 0;
  }

  Map<String, dynamic> toJson() => {
        'position': position?.toJson(),
        'lastSellPrice': lastSellPrice,
        'lastSellTime': lastSellTime?.toIso8601String()
      };
  void restore(Map<String, dynamic> j) {
    position = j['position'] == null
        ? null
        : Position.fromJson((j['position'] as Map).cast<String, dynamic>());
    lastSellPrice = number(j['lastSellPrice']);
    lastSellTime = j['lastSellTime'] == null
        ? null
        : DateTime.parse(j['lastSellTime'] as String);
    clearObservation();
    quote = null;
    state = BotState.stopped;
  }
}

class TradingEngine {
  TradingEngine(
      {this.settings = const StrategySettings(),
      ExecutionAdapter? execution,
      DateTime Function()? clock,
      this.persist,
      this.onChange})
      : execution = execution ?? PaperExecution(),
        clock = clock ?? DateTime.now,
        cashTry = settings.startingBalance;
  StrategySettings settings;
  ExecutionAdapter execution;
  final DateTime Function() clock;
  Future<void> Function()? persist;
  void Function()? onChange;
  final risk = RiskManager();
  double cashTry, realizedPnl = 0, dayStartEquity = 0, dayRealizedStart = 0;
  int dailyEntries = 0, sequence = 0;
  String dayKey = '',
      message = 'Botu başlatın. Piyasa verisi otomatik yüklenir.';
  BotState state = BotState.stopped;
  bool running = false,
      entriesPaused = false,
      riskLocked = false,
      busy = false,
      uncertainOrder = false;
  final Map<String, CoinState> coins = {};
  CoinState coin(String symbol) => coins.putIfAbsent(symbol, CoinState.new);
  Position? get position => coin(settings.symbol).position;
  set position(Position? value) => coin(settings.symbol).position = value;
  MarketQuote? get quote => coin(settings.symbol).quote;
  set quote(MarketQuote? value) => coin(settings.symbol).quote = value;
  double get lastSellPrice => coin(settings.symbol).lastSellPrice;
  set lastSellPrice(double value) =>
      coin(settings.symbol).lastSellPrice = value;
  DateTime? get lastSellTime => coin(settings.symbol).lastSellTime;
  set lastSellTime(DateTime? value) =>
      coin(settings.symbol).lastSellTime = value;
  final List<TradeEvent> events = [];
  Map<String, Position> get positions => {
        for (final entry in coins.entries)
          if (entry.value.position != null) entry.key: entry.value.position!
      };
  MarketQuote? quoteFor(String symbol) => coin(symbol).quote;
  PositionMetrics? metricsFor(String symbol) {
    final c = coin(symbol);
    return c.position == null || c.quote == null
        ? null
        : PositionMetrics(c.position!, c.quote!, settings);
  }

  bool get isPaper => execution.isPaper;
  PositionMetrics? get metrics => metricsFor(settings.symbol);
  double get investedBasis =>
      positions.values.fold(0, (sum, p) => sum + p.costBasis);
  bool get hasStalePositions =>
      positions.keys.any((s) => quoteFor(s)?.isFresh(clock()) != true);
  double get cryptoValue => positions.entries.fold(
      0,
      (sum, e) =>
          sum +
          e.value.quantity * (quoteFor(e.key)?.last ?? e.value.entryPrice));
  double get markValue => cashTry + cryptoValue;
  double get liquidationValue =>
      cashTry +
      positions.entries.fold(
          0,
          (sum, e) =>
              sum +
              e.value.costBasis +
              (metricsFor(e.key)?.netPnl ?? -e.value.buyFee));
  double get dailyPnl =>
      dayStartEquity == 0 ? 0 : liquidationValue - dayStartEquity;
  double reentryLevelFor(String symbol) =>
      coin(symbol).lastSellPrice * (1 - settings.reentryDropPct / 100);
  double get reentryLevel => reentryLevelFor(settings.symbol);
  int get observationCount => coin(settings.symbol).window.length;

  void start() {
    if (uncertainOrder) {
      state = BotState.error;
      message = 'Belirsiz emir uzlaştırılmadan bot başlatılamaz.';
      _notify();
      return;
    }
    running = true;
    entriesPaused = false;
    for (final symbol in settings.symbols) {
      final c = coin(symbol);
      c.clearObservation();
      c.state = c.position != null
          ? BotState.holding
          : c.lastSellPrice > 0
              ? BotState.waitingReentry
              : BotState.waitingEntry;
      c.message = c.state.label;
    }
    state = positions.isNotEmpty
        ? BotState.holding
        : lastSellPrice > 0
            ? BotState.waitingReentry
            : BotState.waitingEntry;
    message = positions.isNotEmpty
        ? '${positions.length} pozisyon izleniyor.'
        : 'Piyasa izleniyor; giriş koşulu ve fiyat teyidi bekleniyor.';
    _notify();
  }

  void pauseEntries() {
    entriesPaused = true;
    if (positions.isEmpty) state = BotState.paused;
    message =
        'Yeni alımlar durduruldu. Açık pozisyonun risk ve kâr çıkışları izlenir.';
    _notify();
  }

  void resumeEntries() {
    entriesPaused = false;
    if (running) {
      state = riskLocked
          ? BotState.riskLock
          : positions.isNotEmpty
              ? BotState.holding
              : lastSellPrice > 0
                  ? BotState.waitingReentry
                  : BotState.waitingEntry;
    }
    message = state.label;
    for (final c in coins.values) {
      c.clearObservation();
    }
    _notify();
  }

  Future<void> stop({bool emergency = false}) async {
    running = false;
    entriesPaused = true;
    state = BotState.stopped;
    for (final c in coins.values) {
      c.state = BotState.stopped;
    }
    message = emergency
        ? 'Acil durdurma: yeni emir gönderilmez. Açık pozisyon satılmadı.'
        : 'Bot tamamen durduruldu. Açık pozisyon korunuyor.';
    _notify();
    try {
      await execution.halt();
    } catch (_) {
      message =
          'Bot durdu; açık emir iptali doğrulanamadı. Borsa hesabını kontrol edin.';
    }
    if (persist != null) await persist!();
    _notify();
  }

  void _notify() => onChange?.call();
  static String istanbulDay(DateTime d) {
    final t = d.toUtc().add(const Duration(hours: 3));
    return '${t.year}-${t.month}-${t.day}';
  }

  void _rollDay() {
    final today = istanbulDay(clock());
    if (today != dayKey) {
      dayKey = today;
      dayStartEquity = liquidationValue;
      dayRealizedStart = realizedPnl;
      dailyEntries = 0;
      riskLocked = false;
    }
    if (dailyPnl <= -settings.dailyLossLimit ||
        realizedPnl - dayRealizedStart <= -settings.dailyLossLimit) {
      riskLocked = true;
    }
  }

  bool _signal(CoinState c, {required bool reentry}) {
    if (c.window.length < settings.windowSize ||
        c.observedSince == null ||
        clock().difference(c.observedSince!).inSeconds <
            settings.observationSeconds) {
      return false;
    }
    final v = c.window.toList(), p = c.window.last;
    final lo = v.reduce(math.min), hi = v.reduce(math.max);
    if (!(p >= lo * (1 + settings.reboundPct / 100) && p > v[v.length - 2])) {
      return false;
    }
    final flat = (hi - lo) / lo * 100 <= settings.flatRangePct;
    if (reentry) {
      if (c.lastSellTime == null ||
          clock().difference(c.lastSellTime!).inSeconds <
              settings.cooldownSeconds) {
        return false;
      }
      return p <= reentryLevelFor(c.quote!.symbol) ||
          (flat && p <= c.lastSellPrice);
    }
    return p <= c.observedPeak * (1 - settings.entryDropPct / 100) || flat;
  }

  Future<void> onQuote(MarketQuote q, SymbolRules rules) async {
    if (!settings.symbols.contains(q.symbol) ||
        rules.symbol != q.symbol ||
        !q.isFresh(clock())) {
      return;
    }
    final c = coin(q.symbol);
    c.quote = q;
    _rollDay();
    _notify();
    if (!running || busy || uncertainOrder) return;
    if (c.lastSampleTime == null ||
        clock().difference(c.lastSampleTime!).inMilliseconds >= 1000) {
      c.observedSince ??= clock();
      c.lastSampleTime = clock();
      c.window.addLast(q.last);
      c.observedPeak = math.max(c.observedPeak, q.last);
      while (c.window.length > settings.windowSize) {
        c.window.removeFirst();
      }
    }
    if (c.position != null) {
      final m = metricsFor(q.symbol)!,
          stopLoss = m.netPct <= -settings.stopLossPct;
      if (stopLoss || (m.netPnl > 0 && m.netPct >= settings.minNetProfitPct)) {
        await _sell(q, rules, c, stopLoss ? 'Stop loss' : 'Net kâr hedefi');
      } else {
        c.state = BotState.holding;
        c.message = 'Pozisyon açık; net kâr ve stop loss izleniyor.';
      }
    } else {
      final block = risk.entryBlock(
          settings, q, cashTry, rules, dailyEntries, riskLocked,
          invested: investedBasis,
          openPositions: positions.length,
          stalePositions: hasStalePositions);
      if (block != null) {
        c.state = riskLocked || dailyEntries >= settings.maxTradesPerDay
            ? BotState.riskLock
            : BotState.waitingEntry;
        c.message = block;
      } else if (entriesPaused) {
        c.state = BotState.paused;
        c.message = c.state.label;
      } else {
        final reentry = c.lastSellPrice > 0;
        c.state = reentry ? BotState.waitingReentry : BotState.waitingEntry;
        c.message = reentry
            ? 'Geri çekilme/yataylaşma ve yükseliş teyidi bekleniyor.'
            : 'Giriş teyidi bekleniyor: ${c.window.length}/${settings.windowSize} örnek.';
        if (_signal(c, reentry: reentry)) await _buy(q, rules, c);
      }
    }
    if (running && !busy) {
      state = riskLocked
          ? BotState.riskLock
          : positions.isNotEmpty
              ? BotState.holding
              : entriesPaused
                  ? BotState.paused
                  : c.state;
      message = '${q.symbol.split('_').first}: ${c.message}';
    }
    _notify();
  }

  String _intent() => 'cl-${clock().microsecondsSinceEpoch}-${++sequence}';
  Future<void> _buy(MarketQuote q, SymbolRules rules, CoinState c) async {
    busy = true;
    c.state = state = BotState.buying;
    message = 'Alış emri işleniyor';
    _notify();
    try {
      if (persist != null) await persist!();
      if (!running || !q.isFresh(clock())) return;
      final block = risk.entryBlock(
          settings, q, cashTry, rules, dailyEntries, riskLocked,
          invested: investedBasis,
          openPositions: positions.length,
          stalePositions: hasStalePositions);
      if (block != null || entriesPaused) {
        c.message = block ?? 'Yeni alımlar duraklatıldı.';
        return;
      }
      final budget = risk.budget(settings, cashTry, invested: investedBasis);
      final f = await execution.buy(
          quote: q,
          rules: rules,
          settings: settings,
          budget: budget,
          intentId: _intent());
      if ([f.quantity, f.price, f.notional, f.fee]
              .any((v) => !v.isFinite || v < 0) ||
          f.quantity <= 0 ||
          f.price <= 0 ||
          f.notional <= 0 ||
          f.buyCost > budget + 0.000001 ||
          f.buyCost > cashTry + 0.000001) {
        throw const ExecutionException(
            'Gerçekleşen emir sermaye sınırını aştı; uzlaştırma gerekli.',
            uncertain: true);
      }
      cashTry -= f.buyCost;
      c.position = Position(
          symbol: q.symbol,
          quantity: f.quantity,
          entryPrice: f.price,
          notional: f.notional,
          buyFee: f.fee,
          openedAt: f.time,
          orderId: f.orderId,
          spreadCost: f.spreadCost,
          slippageCost: f.slippageCost);
      events.insert(
          0,
          TradeEvent(
              side: 'AL',
              symbol: q.symbol,
              price: f.price,
              quantity: f.quantity,
              fee: f.fee,
              time: f.time,
              orderId: f.orderId,
              paper: f.paper,
              reason:
                  c.lastSellPrice > 0 ? 'Yeniden giriş teyidi' : 'Giriş teyidi',
              spreadCost: f.spreadCost,
              slippageCost: f.slippageCost));
      dailyEntries++;
      c.state = state = running ? BotState.holding : BotState.stopped;
      message = running
          ? '${q.symbol.split('_').first} alındı. Net kâr ve risk hedefleri izleniyor.'
          : 'Emir durdurmadan önce gerçekleşti. Pozisyon kaydedildi; bot kapalı.';
      c.message = message;
      c.clearObservation();
      if (persist != null) await persist!();
    } catch (e) {
      await _executionError(e);
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<void> _sell(
      MarketQuote q, SymbolRules rules, CoinState c, String reason) async {
    busy = true;
    c.state = state = BotState.selling;
    message = 'Satış emri gönderiliyor';
    _notify();
    try {
      if (persist != null) await persist!();
      if (!running || !q.isFresh(clock())) return;
      final p = c.position!;
      final f = await execution.sell(
          quote: q,
          rules: rules,
          settings: settings,
          position: p,
          intentId: _intent(),
          stopLoss: reason == 'Stop loss');
      if ([f.quantity, f.price, f.notional, f.fee]
              .any((v) => !v.isFinite || v < 0) ||
          f.notional <= 0 ||
          f.price <= 0 ||
          f.fee > f.notional ||
          f.quantity <= 0 ||
          f.quantity > p.quantity + 1e-12) {
        throw const ExecutionException('Satış miktarı pozisyon ile uyuşmuyor.',
            uncertain: true);
      }
      final ratio = math.min(1.0, f.quantity / p.quantity),
          basis = p.costBasis * ratio;
      final pnl = f.sellProceeds - basis;
      cashTry += f.sellProceeds;
      realizedPnl += pnl;
      events.insert(
          0,
          TradeEvent(
              side: 'SAT',
              symbol: q.symbol,
              price: f.price,
              quantity: f.quantity,
              fee: f.fee,
              time: f.time,
              orderId: f.orderId,
              paper: f.paper,
              grossPnl: f.notional - p.notional * ratio,
              pnl: pnl,
              reason: reason,
              spreadCost: f.spreadCost,
              slippageCost: f.slippageCost));
      final remaining = p.quantity - f.quantity;
      if (remaining > 1e-12) {
        c.position = Position(
            symbol: p.symbol,
            quantity: remaining,
            entryPrice: p.entryPrice,
            notional: p.notional * (1 - ratio),
            buyFee: p.buyFee * (1 - ratio),
            openedAt: p.openedAt,
            orderId: p.orderId,
            spreadCost: p.spreadCost * (1 - ratio),
            slippageCost: p.slippageCost * (1 - ratio));
        message = 'Kısmi satış; kalan pozisyon izleniyor.';
      } else {
        c.position = null;
        c.lastSellPrice = f.price;
        c.lastSellTime = clock();
        message =
            'Satış gerçekleşti. Yeni giriş için geri çekilme veya yataylaşma bekleniyor.';
      }
      _rollDay();
      c.message = message;
      c.clearObservation();
      c.state = state = !running
          ? BotState.stopped
          : c.position != null
              ? BotState.holding
              : riskLocked
                  ? BotState.riskLock
                  : BotState.waitingReentry;
      if (persist != null) await persist!();
    } catch (e) {
      await _executionError(e);
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<void> _executionError(Object e) async {
    if (e is ExecutionException) uncertainOrder = uncertainOrder || e.uncertain;
    running = false;
    state = BotState.error;
    message = e.toString();
    _notify();
    if (!isPaper) {
      try {
        await execution.halt();
      } catch (_) {
        message = '$e · Sunucu durdurması doğrulanamadı; hesabı kontrol edin.';
      }
    }
  }

  Map<String, dynamic> toJson() => {
        'schema': 3,
        'coins': {for (final e in coins.entries) e.key: e.value.toJson()},
        'settings': settings.toJson(),
        'cashTry': cashTry,
        'realizedPnl': realizedPnl,
        'lastSellPrice': lastSellPrice,
        'lastSellTime': lastSellTime?.toIso8601String(),
        'position': position?.toJson(),
        'events': events.map((e) => e.toJson()).toList(),
        'dayKey': dayKey,
        'dayStartEquity': dayStartEquity,
        'dayRealizedStart': dayRealizedStart,
        'dailyEntries': dailyEntries,
        'riskLocked': riskLocked,
        'sequence': sequence,
        'uncertainOrder': uncertainOrder || (!isPaper && busy)
      };
  void restore(Map<String, dynamic> j) {
    settings = StrategySettings.fromJson(
        (j['settings'] as Map).cast<String, dynamic>());
    if (settings.validate() != null) {
      throw const FormatException('Geçersiz kayıtlı ayarlar');
    }
    cashTry = number(j['cashTry'], settings.startingBalance);
    realizedPnl = number(j['realizedPnl']);
    coins.clear();
    if (j['coins'] is Map) {
      for (final e in (j['coins'] as Map).entries) {
        final symbol = e.key as String;
        if (!RegExp(r'^[A-Z0-9]+_TRY$').hasMatch(symbol)) {
          throw const FormatException('Geçersiz kayıtlı çift');
        }
        coin(symbol).restore((e.value as Map).cast<String, dynamic>());
        final p = coin(symbol).position;
        if (p != null &&
            (p.symbol != symbol ||
                !settings.symbols.contains(symbol) ||
                p.quantity <= 0 ||
                !p.quantity.isFinite ||
                !p.costBasis.isFinite ||
                p.costBasis <= 0)) {
          throw const FormatException('Kayıtlı pozisyon doğrulanamadı');
        }
      }
    } else {
      coin(settings.symbol)
          .restore(j); // v2 single-coin ledger migration, cash counted once.
    }
    events.clear();
    events.addAll((j['events'] as List? ?? [])
        .map((e) => TradeEvent.fromJson((e as Map).cast<String, dynamic>())));
    dayKey = j['dayKey'] as String? ?? '';
    dayStartEquity = number(j['dayStartEquity']);
    dayRealizedStart = number(j['dayRealizedStart']);
    dailyEntries = number(j['dailyEntries']).toInt();
    riskLocked = j['riskLocked'] == true;
    sequence = number(j['sequence']).toInt();
    uncertainOrder = j['uncertainOrder'] == true;
    running = false;
    state = uncertainOrder ? BotState.error : BotState.stopped;
    message = uncertainOrder
        ? 'Önceki emrin durumu belirsiz. Hesap uzlaştırması gerekli.'
        : 'Kayıtlar geri yüklendi. Devam etmek için botu başlatın.';
  }
}
