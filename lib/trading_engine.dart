import 'dart:collection';
import 'dart:math' as math;
import 'execution.dart';
import 'models.dart';
export 'models.dart';

class RiskManager {
  double budget(StrategySettings s, double cash) => math.max(
      0,
      math.min(math.min(cash * s.capitalPct / 100, s.maxPosition),
          math.min(s.maxCapital, cash)));
  String? entryBlock(StrategySettings s, MarketQuote q, double cash,
      SymbolRules rules, int dailyEntries, bool locked) {
    if (locked) return 'Günlük zarar sınırı aşıldı. Yeni alımlar kilitli.';
    if (dailyEntries >= s.maxTradesPerDay) {
      return 'Günlük maksimum alım sayısına ulaşıldı.';
    }
    if (q.spreadPct > s.maxSpreadPct) {
      return 'Spread sınırın üzerinde; alım bekletiliyor.';
    }
    final price = q.ask * (1 + s.slippageRate);
    return rules.validateOrder(
        rules.floorQuantity(budget(s, cash) / (price * (1 + s.feeRate))),
        price);
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
  double cashTry,
      realizedPnl = 0,
      lastSellPrice = 0,
      dayStartEquity = 0,
      dayRealizedStart = 0;
  int dailyEntries = 0, sequence = 0;
  String dayKey = '',
      message = 'Botu başlatın. Piyasa verisi otomatik yüklenir.';
  BotState state = BotState.stopped;
  bool running = false,
      entriesPaused = false,
      riskLocked = false,
      busy = false,
      uncertainOrder = false;
  Position? position;
  MarketQuote? quote;
  DateTime? lastSellTime, observedSince, lastSampleTime;
  final List<TradeEvent> events = [];
  final Queue<double> _window = Queue<double>();
  double _observedPeak = 0;
  bool get isPaper => execution.isPaper;
  PositionMetrics? get metrics => position == null || quote == null
      ? null
      : PositionMetrics(position!, quote!, settings);
  double get markValue =>
      cashTry +
      (position?.quantity ?? 0) * (quote?.last ?? position?.entryPrice ?? 0);
  double get liquidationValue =>
      cashTry +
      (position == null
          ? 0
          : position!.costBasis + (metrics?.netPnl ?? -position!.buyFee));
  double get dailyPnl =>
      dayStartEquity == 0 ? 0 : liquidationValue - dayStartEquity;
  double get reentryLevel =>
      lastSellPrice * (1 - settings.reentryDropPct / 100);
  int get observationCount => _window.length;

  void start() {
    if (uncertainOrder) {
      state = BotState.error;
      message = 'Belirsiz emir uzlaştırılmadan bot başlatılamaz.';
      _notify();
      return;
    }
    running = true;
    entriesPaused = false;
    _clearObservation();
    state = position != null
        ? BotState.holding
        : lastSellPrice > 0
            ? BotState.waitingReentry
            : BotState.waitingEntry;
    message = position != null
        ? 'Mevcut pozisyon izleniyor.'
        : 'Piyasa izleniyor; giriş koşulu ve fiyat teyidi bekleniyor.';
    _notify();
  }

  void pauseEntries() {
    entriesPaused = true;
    if (position == null) state = BotState.paused;
    message =
        'Yeni alımlar durduruldu. Açık pozisyonun risk ve kâr çıkışları izlenir.';
    _notify();
  }

  void resumeEntries() {
    entriesPaused = false;
    if (running) {
      state = riskLocked
          ? BotState.riskLock
          : position != null
              ? BotState.holding
              : lastSellPrice > 0
                  ? BotState.waitingReentry
                  : BotState.waitingEntry;
    }
    message = state.label;
    _clearObservation();
    _notify();
  }

  Future<void> stop({bool emergency = false}) async {
    running = false;
    entriesPaused = true;
    state = BotState.stopped;
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
  void _clearObservation() {
    _window.clear();
    observedSince = null;
    lastSampleTime = null;
    _observedPeak = 0;
  }

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

  bool _signal({required bool reentry}) {
    if (_window.length < settings.windowSize ||
        observedSince == null ||
        clock().difference(observedSince!).inSeconds <
            settings.observationSeconds) {
      return false;
    }
    final v = _window.toList(), p = _window.last;
    final lo = v.reduce(math.min), hi = v.reduce(math.max);
    if (!(p >= lo * (1 + settings.reboundPct / 100) && p > v[v.length - 2])) {
      return false;
    }
    final flat = (hi - lo) / lo * 100 <= settings.flatRangePct;
    if (reentry) {
      if (lastSellTime == null ||
          clock().difference(lastSellTime!).inSeconds <
              settings.cooldownSeconds) {
        return false;
      }
      return p <= reentryLevel || (flat && p <= lastSellPrice);
    }
    return p <= _observedPeak * (1 - settings.entryDropPct / 100) || flat;
  }

  Future<void> onQuote(MarketQuote q, SymbolRules rules) async {
    if (q.symbol != settings.symbol || !q.isFresh(clock())) return;
    quote = q;
    _rollDay();
    _notify();
    if (!running || busy || uncertainOrder) return;
    if (lastSampleTime == null ||
        clock().difference(lastSampleTime!).inMilliseconds >= 1000) {
      observedSince ??= clock();
      lastSampleTime = clock();
      _window.addLast(q.last);
      _observedPeak = math.max(_observedPeak, q.last);
      while (_window.length > settings.windowSize) {
        _window.removeFirst();
      }
    }
    if (position != null) {
      final m = metrics!, stopLoss = m.netPct <= -settings.stopLossPct;
      if (stopLoss || (m.netPnl > 0 && m.netPct >= settings.minNetProfitPct)) {
        await _sell(q, rules, stopLoss ? 'Stop loss' : 'Net kâr hedefi');
      } else {
        state = riskLocked ? BotState.riskLock : BotState.holding;
        message = riskLocked
            ? 'Günlük zarar limiti aşıldı. Pozisyonun çıkış kuralları izleniyor.'
            : 'Pozisyon açık; tüm maliyetlerden sonra net kâr hedefi izleniyor.';
      }
      _notify();
      return;
    }
    final block =
        risk.entryBlock(settings, q, cashTry, rules, dailyEntries, riskLocked);
    if (block != null) {
      state = riskLocked || dailyEntries >= settings.maxTradesPerDay
          ? BotState.riskLock
          : BotState.waitingEntry;
      message = block;
      _notify();
      return;
    }
    if (entriesPaused) {
      state = BotState.paused;
      _notify();
      return;
    }
    final reentry = lastSellPrice > 0;
    state = reentry ? BotState.waitingReentry : BotState.waitingEntry;
    message = reentry
        ? 'Fiyat kovalanmıyor. Geri çekilme/yataylaşma sonrası yükseliş teyidi bekleniyor.'
        : 'Piyasa izleniyor: ${_window.length}/${settings.windowSize} örnek. Giriş ve yükseliş teyidi bekleniyor.';
    if (_signal(reentry: reentry)) await _buy(q, rules);
    _notify();
  }

  String _intent() => 'cl-${clock().microsecondsSinceEpoch}-${++sequence}';
  Future<void> _buy(MarketQuote q, SymbolRules rules) async {
    busy = true;
    state = BotState.buying;
    message = 'Alış emri işleniyor';
    _notify();
    try {
      if (persist != null) await persist!();
      if (!running) return;
      final budget = risk.budget(settings, cashTry);
      final f = await execution.buy(
          quote: q,
          rules: rules,
          settings: settings,
          budget: budget,
          intentId: _intent());
      if (f.buyCost > budget + 0.000001 || f.buyCost > cashTry + 0.000001) {
        throw const ExecutionException(
            'Gerçekleşen emir sermaye sınırını aştı; uzlaştırma gerekli.',
            uncertain: true);
      }
      cashTry -= f.buyCost;
      position = Position(
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
                  lastSellPrice > 0 ? 'Yeniden giriş teyidi' : 'Giriş teyidi',
              spreadCost: f.spreadCost,
              slippageCost: f.slippageCost));
      dailyEntries++;
      state = running ? BotState.holding : BotState.stopped;
      message = running
          ? '${q.symbol.split('_').first} alındı. Net kâr ve risk hedefleri izleniyor.'
          : 'Emir durdurmadan önce gerçekleşti. Pozisyon kaydedildi; bot kapalı.';
      _clearObservation();
      if (persist != null) await persist!();
    } catch (e) {
      _executionError(e);
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<void> _sell(MarketQuote q, SymbolRules rules, String reason) async {
    busy = true;
    state = BotState.selling;
    message = 'Satış emri gönderiliyor';
    _notify();
    try {
      if (persist != null) await persist!();
      if (!running) return;
      final p = position!;
      final f = await execution.sell(
          quote: q,
          rules: rules,
          settings: settings,
          position: p,
          intentId: _intent(),
          stopLoss: reason == 'Stop loss');
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
        position = Position(
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
        position = null;
        lastSellPrice = f.price;
        lastSellTime = clock();
        message =
            'Satış gerçekleşti. Yeni giriş için geri çekilme veya yataylaşma bekleniyor.';
      }
      _rollDay();
      _clearObservation();
      state = !running
          ? BotState.stopped
          : position != null
              ? BotState.holding
              : riskLocked
                  ? BotState.riskLock
                  : BotState.waitingReentry;
      if (persist != null) await persist!();
    } catch (e) {
      _executionError(e);
    } finally {
      busy = false;
      _notify();
    }
  }

  void _executionError(Object e) {
    if (e is ExecutionException) uncertainOrder = uncertainOrder || e.uncertain;
    running = false;
    state = BotState.error;
    message = e.toString();
  }

  Map<String, dynamic> toJson() => {
        'schema': 2,
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
    lastSellPrice = number(j['lastSellPrice']);
    lastSellTime = j['lastSellTime'] == null
        ? null
        : DateTime.parse(j['lastSellTime'] as String);
    position = j['position'] == null
        ? null
        : Position.fromJson((j['position'] as Map).cast<String, dynamic>());
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
