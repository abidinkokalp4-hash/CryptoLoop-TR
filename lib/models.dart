import 'dart:math' as math;

double number(dynamic v, [double fallback = 0]) =>
    double.tryParse(v.toString()) ?? fallback;

enum BotState {
  stopped,
  connecting,
  waitingEntry,
  buying,
  holding,
  selling,
  waitingReentry,
  paused,
  riskLock,
  error
}

extension BotStateText on BotState {
  String get label => switch (this) {
        BotState.stopped => 'Bot kapalı',
        BotState.connecting => 'Piyasaya bağlanılıyor',
        BotState.waitingEntry => 'Alım fırsatı bekleniyor',
        BotState.buying => 'Alış emri işleniyor',
        BotState.holding => 'Net kâr hedefi bekleniyor',
        BotState.selling => 'Satış emri işleniyor',
        BotState.waitingReentry => 'Yeniden giriş için teyit bekleniyor',
        BotState.paused => 'Yeni alımlar duraklatıldı',
        BotState.riskLock => 'Risk limiti: yeni alımlar kilitli',
        BotState.error => 'İşlem kontrolü gerekiyor',
      };
}

class StrategySettings {
  // Watch-list candidates, not a promise that an asset is currently tradable.
  // The official symbol catalog must validate every pair before any execution.
  static const defaultWatchlist = [
    'BTC_TRY',
    'ETH_TRY',
    'BNB_TRY',
    'SOL_TRY',
    'XRP_TRY',
    'DOGE_TRY',
    'ADA_TRY',
    'AVAX_TRY',
    'LINK_TRY',
    'DOT_TRY'
  ];
  const StrategySettings(
      {this.symbol = 'BTC_TRY',
      List<String>? symbols,
      this.maxOpenPositions = 10,
      this.startingBalance = 10000,
      this.capitalPct = 20,
      this.maxCapital = 10000,
      this.maxPosition = 2000,
      this.minNetProfitPct = 0.3,
      this.stopLossPct = 2,
      this.reentryDropPct = 0.3,
      this.entryDropPct = 0.25,
      this.reboundPct = 0.05,
      this.feePct = 0.15,
      this.slippagePct = 0.05,
      this.maxSpreadPct = 0.2,
      this.dailyLossLimit = 300,
      this.maxTradesPerDay = 20,
      this.windowSize = 30,
      this.flatRangePct = 0.15,
      this.observationSeconds = 30,
      this.cooldownSeconds = 15})
      : _symbols = symbols;
  final String symbol;
  final List<String>? _symbols;
  List<String> get symbols => List.unmodifiable(_symbols ?? [symbol]);
  final int maxOpenPositions;
  final double startingBalance,
      capitalPct,
      maxCapital,
      maxPosition,
      minNetProfitPct,
      stopLossPct,
      reentryDropPct,
      entryDropPct,
      reboundPct,
      feePct,
      slippagePct,
      maxSpreadPct,
      dailyLossLimit,
      flatRangePct;
  final int maxTradesPerDay, windowSize, observationSeconds, cooldownSeconds;
  double get feeRate => feePct / 100;
  double get slippageRate => slippagePct / 100;
  Map<String, dynamic> toJson() => {
        'symbol': symbol,
        'symbols': symbols,
        'maxOpenPositions': maxOpenPositions,
        'startingBalance': startingBalance,
        'capitalPct': capitalPct,
        'maxCapital': maxCapital,
        'maxPosition': maxPosition,
        'minNetProfitPct': minNetProfitPct,
        'stopLossPct': stopLossPct,
        'reentryDropPct': reentryDropPct,
        'entryDropPct': entryDropPct,
        'reboundPct': reboundPct,
        'feePct': feePct,
        'slippagePct': slippagePct,
        'maxSpreadPct': maxSpreadPct,
        'dailyLossLimit': dailyLossLimit,
        'maxTradesPerDay': maxTradesPerDay,
        'windowSize': windowSize,
        'flatRangePct': flatRangePct,
        'observationSeconds': observationSeconds,
        'cooldownSeconds': cooldownSeconds
      };
  factory StrategySettings.fromJson(Map<String, dynamic> j) {
    final defaults = const StrategySettings().toJson();
    double n(String k) => number(j[k], number(defaults[k]));
    return StrategySettings(
        symbol: j['symbol'] as String? ?? 'BTC_TRY',
        symbols: j['symbols'] == null
            ? null
            : List<String>.from(j['symbols'] as List),
        maxOpenPositions: n('maxOpenPositions').toInt(),
        startingBalance: n('startingBalance'),
        capitalPct: n('capitalPct'),
        maxCapital: n('maxCapital'),
        maxPosition: n('maxPosition'),
        minNetProfitPct: n('minNetProfitPct'),
        stopLossPct: n('stopLossPct'),
        reentryDropPct: n('reentryDropPct'),
        entryDropPct: n('entryDropPct'),
        reboundPct: n('reboundPct'),
        feePct: n('feePct'),
        slippagePct: n('slippagePct'),
        maxSpreadPct: n('maxSpreadPct'),
        dailyLossLimit: n('dailyLossLimit'),
        maxTradesPerDay: n('maxTradesPerDay').toInt(),
        windowSize: n('windowSize').toInt(),
        flatRangePct: n('flatRangePct'),
        observationSeconds: n('observationSeconds').toInt(),
        cooldownSeconds: n('cooldownSeconds').toInt());
  }
  String? validate() {
    if (symbols.isEmpty ||
        symbols.length > 20 ||
        symbols.toSet().length != symbols.length ||
        !symbols.contains(symbol) ||
        symbols.any((s) => !RegExp(r'^[A-Z0-9]+_TRY$').hasMatch(s))) {
      return 'Yalnızca TRY spot çiftleri kullanılabilir.';
    }
    if (maxOpenPositions < 1 || maxOpenPositions > 20) {
      return 'Aynı anda açık pozisyon sınırı 1–20 olmalıdır.';
    }
    if (toJson().values.whereType<num>().any((v) => !v.isFinite || v < 0)) {
      return 'Değerler sonlu ve pozitif olmalıdır.';
    }
    if (startingBalance <= 0 ||
        maxCapital <= 0 ||
        maxPosition <= 0 ||
        maxPosition > maxCapital ||
        capitalPct <= 0 ||
        capitalPct > 100) {
      return 'Pozisyon ve sermaye limitlerini kontrol edin.';
    }
    if (minNetProfitPct <= 0 ||
        stopLossPct <= 0 ||
        stopLossPct >= 100 ||
        dailyLossLimit <= 0 ||
        maxTradesPerDay < 1 ||
        maxTradesPerDay > 1000 ||
        windowSize < 3 ||
        windowSize > 300 ||
        observationSeconds < 1 ||
        reboundPct <= 0 ||
        feePct >= 5 ||
        slippagePct >= 5 ||
        maxSpreadPct <= 0 ||
        maxSpreadPct >= 10 ||
        entryDropPct >= 100 ||
        reentryDropPct >= 100) {
      return 'Strateji veya risk parametresi güvenli aralık dışında.';
    }
    return null;
  }
}

class SymbolRules {
  const SymbolRules(
      {required this.symbol,
      this.type = 1,
      this.minQty = 0,
      this.maxQty = double.infinity,
      this.stepSize = 0,
      this.minNotional = 0,
      this.maxNotional = double.infinity,
      this.tradable = true});
  final String symbol;
  final int type;
  final double minQty, maxQty, stepSize, minNotional, maxNotional;
  final bool tradable;
  double floorQuantity(double qty) => stepSize > 0
      ? double.parse(
          ((qty / stepSize + 1e-9).floor() * stepSize).toStringAsFixed(12))
      : qty;
  factory SymbolRules.fromJson(Map<String, dynamic> j) {
    final fs = (j['filters'] as List? ?? []).cast<Map<String, dynamic>>();
    Map<String, dynamic> f(String t) =>
        fs.firstWhere((f) => f['filterType'] == t, orElse: () => {});
    final lot = f('LOT_SIZE'), market = f('MARKET_LOT_SIZE');
    final notional =
        f('NOTIONAL').isNotEmpty ? f('NOTIONAL') : f('MIN_NOTIONAL');
    final marketMax = number(market['maxQty'], double.infinity);
    return SymbolRules(
        symbol: j['symbol'].toString(),
        type: number(j['type'], 1).toInt(),
        minQty: math.max(number(lot['minQty']), number(market['minQty'])),
        maxQty: math.min(number(lot['maxQty'], double.infinity),
            marketMax == 0 ? double.infinity : marketMax),
        stepSize: number(market['stepSize']) > 0
            ? number(market['stepSize'])
            : number(lot['stepSize']),
        minNotional: number(notional['minNotional']),
        maxNotional: number(notional['maxNotional'], double.infinity),
        tradable: number(j['spotTradingEnable']) == 1 &&
            (j['orderTypes'] as List? ?? []).contains('MARKET'));
  }
  String? validateOrder(double qty, double price) {
    if (!tradable || type != 1) return 'Bu spot çift şu an desteklenmiyor.';
    if (!qty.isFinite || qty <= 0 || qty < minQty || qty > maxQty) {
      return 'Emir miktarı borsa sınırları dışında.';
    }
    if (qty * price < minNotional || qty * price > maxNotional) {
      return 'Minimum/maksimum emir tutarı sağlanmıyor.';
    }
    return null;
  }
}

class MarketQuote {
  const MarketQuote(
      {required this.symbol,
      required this.last,
      required this.bid,
      required this.ask,
      required this.time,
      this.bidQty = double.infinity,
      this.askQty = double.infinity,
      this.changePct = 0});
  final String symbol;
  final double last, bid, ask, bidQty, askQty, changePct;
  final DateTime time;
  double get mid => (bid + ask) / 2;
  double get spreadPct => mid > 0 ? (ask - bid) / mid * 100 : 0;
  bool isFresh(DateTime now) =>
      last.isFinite &&
      bid.isFinite &&
      ask.isFinite &&
      last > 0 &&
      bid > 0 &&
      ask >= bid &&
      bidQty > 0 &&
      askQty > 0 &&
      now.difference(time).inSeconds >= -2 &&
      now.difference(time).inSeconds <= 10;
}

class Candle {
  const Candle(
      this.time, this.open, this.high, this.low, this.close, this.volume);
  final DateTime time;
  final double open, high, low, close, volume;
  factory Candle.fromRow(List<dynamic> r) => Candle(
      DateTime.fromMillisecondsSinceEpoch(number(r[0]).toInt(), isUtc: true),
      number(r[1]),
      number(r[2]),
      number(r[3]),
      number(r[4]),
      number(r[5]));
  factory Candle.fromStream(Map<String, dynamic> j) => Candle(
      DateTime.fromMillisecondsSinceEpoch(number(j['t']).toInt(), isUtc: true),
      number(j['o']),
      number(j['h']),
      number(j['l']),
      number(j['c']),
      number(j['v']));
}

class Fill {
  const Fill(
      {required this.orderId,
      required this.quantity,
      required this.price,
      required this.notional,
      required this.fee,
      required this.time,
      this.spreadCost = 0,
      this.slippageCost = 0,
      this.paper = true});
  final String orderId;
  final double quantity, price, notional, fee, spreadCost, slippageCost;
  final DateTime time;
  final bool paper;
  double get buyCost => notional + fee;
  double get sellProceeds => notional - fee;
  factory Fill.fromJson(Map<String, dynamic> j) => Fill(
      orderId: j['orderId'].toString(),
      quantity: number(j['quantity']),
      price: number(j['price']),
      notional: number(j['notional']),
      fee: number(j['fee']),
      time: DateTime.parse(j['time'] as String),
      paper: false);
}

class Position {
  const Position(
      {required this.symbol,
      required this.quantity,
      required this.entryPrice,
      required this.notional,
      required this.buyFee,
      required this.openedAt,
      required this.orderId,
      this.spreadCost = 0,
      this.slippageCost = 0});
  final String symbol, orderId;
  final double quantity, entryPrice, notional, buyFee, spreadCost, slippageCost;
  final DateTime openedAt;
  double get costBasis => notional + buyFee;
  Map<String, dynamic> toJson() => {
        'symbol': symbol,
        'quantity': quantity,
        'entryPrice': entryPrice,
        'notional': notional,
        'buyFee': buyFee,
        'openedAt': openedAt.toIso8601String(),
        'orderId': orderId,
        'spreadCost': spreadCost,
        'slippageCost': slippageCost
      };
  factory Position.fromJson(Map<String, dynamic> j) => Position(
      symbol: j['symbol'] as String,
      quantity: number(j['quantity']),
      entryPrice: number(j['entryPrice']),
      notional: number(j['notional']),
      buyFee: number(j['buyFee']),
      openedAt: DateTime.parse(j['openedAt'] as String),
      orderId: j['orderId'].toString(),
      spreadCost: number(j['spreadCost']),
      slippageCost: number(j['slippageCost']));
}

class PositionMetrics {
  PositionMetrics(Position p, MarketQuote q, StrategySettings s) {
    value = p.quantity * q.last;
    grossPnl = p.quantity * q.bid - p.notional;
    sellPrice = q.bid * (1 - s.slippageRate);
    sellFee = p.quantity * sellPrice * s.feeRate;
    spreadCost = p.spreadCost + p.quantity * (q.mid - q.bid);
    slippageCost = p.slippageCost + p.quantity * (q.bid - sellPrice);
    totalFees = p.buyFee + sellFee;
    // Executable prices already include spread/slippage; subtracting again would double count.
    netPnl = p.quantity * sellPrice - sellFee - p.costBasis;
    netPct = netPnl / p.costBasis * 100;
    totalCosts = totalFees + spreadCost + slippageCost;
    requiredBid = p.costBasis *
        (1 + s.minNetProfitPct / 100) /
        (p.quantity * (1 - s.slippageRate) * (1 - s.feeRate));
  }
  late final double value,
      grossPnl,
      sellPrice,
      sellFee,
      spreadCost,
      slippageCost,
      totalFees,
      netPnl,
      netPct,
      totalCosts,
      requiredBid;
}

class TradeEvent {
  const TradeEvent(
      {required this.side,
      required this.symbol,
      required this.price,
      required this.quantity,
      required this.fee,
      required this.time,
      required this.orderId,
      this.grossPnl = 0,
      this.pnl = 0,
      this.spreadCost = 0,
      this.slippageCost = 0,
      this.paper = true,
      this.reason = ''});
  final String side, symbol, orderId, reason;
  final double price, quantity, fee, grossPnl, pnl, spreadCost, slippageCost;
  final DateTime time;
  final bool paper;
  Map<String, dynamic> toJson() => {
        'side': side,
        'symbol': symbol,
        'price': price,
        'quantity': quantity,
        'fee': fee,
        'time': time.toIso8601String(),
        'orderId': orderId,
        'grossPnl': grossPnl,
        'pnl': pnl,
        'spreadCost': spreadCost,
        'slippageCost': slippageCost,
        'paper': paper,
        'reason': reason
      };
  factory TradeEvent.fromJson(Map<String, dynamic> j) => TradeEvent(
      side: j['side'] as String,
      symbol: j['symbol'] as String,
      price: number(j['price']),
      quantity: number(j['quantity']),
      fee: number(j['fee']),
      time: DateTime.parse(j['time'] as String),
      orderId: j['orderId'].toString(),
      grossPnl: number(j['grossPnl']),
      pnl: number(j['pnl']),
      spreadCost: number(j['spreadCost']),
      slippageCost: number(j['slippageCost']),
      paper: j['paper'] != false,
      reason: j['reason'] as String? ?? '');
}
