import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'binance_tr_market.dart';
import 'bot_background.dart';
import 'execution.dart';
import 'live_execution.dart';
import 'storage.dart';
import 'trading_engine.dart';

class AppController extends ChangeNotifier {
  AppController(
      {BinanceTrMarket? market,
      BotBackground? backgroundRunner,
      this.offline = false})
      : market = market ?? BinanceTrMarket(),
        backgroundRunner = backgroundRunner ?? BotBackground() {
    engine = TradingEngine(
        settings:
            const StrategySettings(symbols: StrategySettings.defaultWatchlist),
        onChange: _refresh);
  }
  final BinanceTrMarket market;
  final bool offline;
  final BotBackground backgroundRunner;
  late TradingEngine engine;
  AppStore? store;
  BackendClient? backend;
  LivePreflight? backendCheck;
  String backendCheckError = '';
  bool checkingBackend = false;
  final secure = const FlutterSecureStorage(
      aOptions: AndroidOptions(encryptedSharedPreferences: true));
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  final List<Candle> candles = [];
  Timer? _saveTimer, _freshness, _notificationTimer;
  String connection = 'Piyasaya bağlanılıyor',
      chartError = '',
      loadError = '',
      backendUrl = '',
      backgroundError = '';
  String interval = '1m', selectedSymbol = 'BTC_TRY';
  bool _seedWatchlist = true;
  bool initialized = false,
      chartLoading = false,
      live = false,
      starting = false,
      _disposed = false;
  int _chartGeneration = 0, _controlEpoch = 0;
  MarketQuote? get quote => engine.quoteFor(selectedSymbol);
  int get connectedCount => engine.settings.symbols
      .where((s) => engine.quoteFor(s)?.isFresh(DateTime.now()) == true)
      .length;
  bool get connected => connectedCount > 0;
  bool get chartConnected => quote?.isFresh(DateTime.now()) == true;
  List<String> get symbolNames => market.symbols.keys.toList()..sort();
  String get storageKey => live ? 'live-v2' : 'paper-v2';
  void _refresh() {
    if (!engine.running && !starting && backgroundRunner.active) {
      unawaited(backgroundRunner.stop().catchError((Object e) {
        backgroundError = 'Android servisi durdurulamadı: $e';
      }));
    } else if (engine.running &&
        !live &&
        backgroundRunner.active &&
        !(_notificationTimer?.isActive ?? false)) {
      _notificationTimer = Timer(const Duration(seconds: 1), () {
        unawaited(backgroundRunner.update(
            '${engine.settings.symbols.length} coin · ${engine.positions.length} pozisyon',
            engine.state.label,
            connected ? 'Piyasa bağlı' : connection));
      });
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> init() async {
    if (initialized) return;
    try {
      store = AppStore(await SharedPreferences.getInstance());
      final saved = store!.read('paper-v2');
      if (saved != null) {
        engine.restore(saved);
        _seedWatchlist = saved['seedWatchlistPending'] == true ||
            (saved['settings'] as Map)['symbols'] == null;
      }
      selectedSymbol = engine.settings.symbol;
      backendUrl = store!.preferences.getString('backend-url') ?? '';
    } catch (e) {
      loadError = e.toString();
    }
    engine.persist = save;
    backgroundRunner.isPaperRunning = () => !live && engine.running;
    backgroundRunner.onStop = (reason) async {
      if (!engine.running && !starting) return;
      await stop(emergency: true);
      engine.message = reason;
      await save();
      _refresh();
    };
    backgroundRunner.init();
    initialized = true;
    _refresh();
    if (offline) {
      connection = 'Test verisi';
      return;
    }
    _subscriptions.add(market.quotes.stream.listen((q) {
      final rules = market.symbols[q.symbol];
      if (rules == null) {
        engine.coin(q.symbol).message =
            'Sembol kuralları doğrulanmadan işlem yapılmaz.';
        connection = 'Fiyat bağlı; sembol kuralları bekleniyor.';
        _refresh();
        return;
      }
      unawaited(engine.onQuote(q, rules));
    }));
    _subscriptions.add(market.status.stream.listen((s) {
      connection = s;
      _refresh();
    }));
    _subscriptions.add(market.candleUpdates.stream.listen((c) {
      final i = candles.indexWhere((x) => x.time == c.time);
      if (i >= 0) {
        candles[i] = c;
      } else {
        candles.add(c);
        candles.sort((a, b) => a.time.compareTo(b.time));
      }
      if (candles.length > 150) candles.removeAt(0);
      chartError = '';
      _refresh();
    }));
    _saveTimer = Timer.periodic(const Duration(seconds: 15),
        (_) => unawaited(save().catchError((_) {})));
    _freshness = Timer.periodic(const Duration(seconds: 2), (_) => _refresh());
    unawaited(reconnect());
  }

  Future<void> save() async {
    if (store == null || loadError.isNotEmpty) return;
    try {
      await store!.write(storageKey,
          engine.toJson()..['seedWatchlistPending'] = !live && _seedWatchlist);
    } catch (_) {
      engine.running = false;
      engine.state = BotState.error;
      loadError = 'Kayıt yazılamadı. Bot durduruldu; işlem verilerini koruyun.';
      _refresh();
      rethrow;
    }
  }

  Future<void> reconnect() async {
    if (market.symbols.isEmpty) {
      try {
        await market.loadSymbols();
      } catch (e) {
        connection = e.toString();
      }
    }
    if (_seedWatchlist &&
        !live &&
        !engine.running &&
        market.symbols.isNotEmpty) {
      final required = {...engine.positions.keys};
      final candidates = [
        ...engine.settings.symbols,
        ...StrategySettings.defaultWatchlist,
        ...symbolNames
      ];
      final chosen = <String>[...required];
      for (final s in candidates) {
        if (market.symbols.containsKey(s) &&
            !chosen.contains(s) &&
            chosen.length < 10) {
          chosen.add(s);
        }
      }
      if (chosen.isNotEmpty) {
        final primary = chosen.contains(engine.settings.symbol)
            ? engine.settings.symbol
            : chosen.first;
        engine.settings = StrategySettings.fromJson(engine.settings.toJson()
          ..['symbols'] = chosen
          ..['symbol'] = primary);
        selectedSymbol = primary;
        _seedWatchlist = false;
        await save();
      }
    }
    await market.connectMany(engine.settings.symbols,
        chartSymbol: selectedSymbol, interval: interval);
    unawaited(loadChart());
  }

  Future<void> loadChart() async {
    final g = ++_chartGeneration;
    chartLoading = true;
    chartError = '';
    _refresh();
    try {
      final data = await market.candles(selectedSymbol, interval);
      if (g != _chartGeneration || _disposed) return;
      candles.clear();
      candles.addAll(data);
    } catch (e) {
      if (g == _chartGeneration) chartError = e.toString();
    } finally {
      if (g == _chartGeneration) {
        chartLoading = false;
        _refresh();
      }
    }
  }

  Future<void> setInterval(String value) async {
    if (interval == value) return;
    interval = value;
    candles.clear();
    await market.selectChart(selectedSymbol, interval);
    await loadChart();
  }

  Future<void> selectSymbol(String symbol) async {
    if (!engine.settings.symbols.contains(symbol) || selectedSymbol == symbol) {
      return;
    }
    selectedSymbol = symbol;
    candles.clear();
    ++_chartGeneration;
    _refresh();
    if (!offline) {
      await market.selectChart(symbol, interval);
      await loadChart();
    }
  }

  Future<String?> start() async {
    if (starting || engine.running || checkingBackend) {
      return 'Bot zaten çalışıyor veya başlatılıyor.';
    }
    if (loadError.isNotEmpty) return loadError;
    if (!connected) {
      return 'Güncel piyasa verisi yok. Bağlantı kurulunca yeniden deneyin.';
    }
    starting = true;
    final epoch = ++_controlEpoch;
    _refresh();
    try {
      if (market.symbols[engine.settings.symbol] == null) {
        try {
          await market.loadSymbols();
        } catch (e) {
          return e.toString();
        }
      }
      if (live) {
        try {
          backendCheck = null;
          backendCheckError = '';
          backendCheck =
              await backend!.preflightPortfolio(engine.settings.symbols);
          final problem =
              backendCheck!.liveProblem(engine.settings, DateTime.now());
          if (problem != null) return problem;
          if (epoch != _controlEpoch) {
            return 'Başlatma iptal edildi; bot kapalı kaldı.';
          }
          await reconcileLive();
          if (epoch != _controlEpoch) {
            return 'Başlatma iptal edildi; bot kapalı kaldı.';
          }
          await backend!.arm(engine.settings);
        } catch (e) {
          backendCheckError = e.toString();
          return e.toString();
        }
      } else {
        backgroundError = await backgroundRunner.start() ?? '';
        if (backgroundError.isNotEmpty) return backgroundError;
      }
      if (epoch != _controlEpoch || _disposed || !connected) {
        if (live) await engine.stop(emergency: true);
        await backgroundRunner.stop();
        return 'Başlatma iptal edildi veya fiyat eskidi. Bot kapalı kaldı.';
      }
      engine.start();
      await save();
      _refresh();
      return engine.running ? null : engine.message;
    } finally {
      starting = false;
      _refresh();
    }
  }

  Future<void> stop({bool emergency = false}) async {
    ++_controlEpoch;
    await engine.stop(emergency: emergency);
    await backgroundRunner.stop();
    _refresh();
  }

  Future<String?> applySettings(StrategySettings s) async {
    if (engine.running || engine.busy || starting || checkingBackend) {
      return 'Ayar değiştirmek için botu tamamen durdurun.';
    }
    final problem = s.validate();
    if (problem != null) return problem;
    if (engine.positions.keys.any((symbol) => !s.symbols.contains(symbol))) {
      return 'Açık pozisyonu olan coin izleme listesinden çıkarılamaz.';
    }
    if (s.maxCapital + 0.000001 < engine.investedBasis ||
        engine.positions.values
            .any((p) => s.maxPosition + 0.000001 < p.costBasis) ||
        s.maxOpenPositions < engine.positions.length) {
      return 'Sermaye/pozisyon limiti mevcut pozisyonların altına indirilemez.';
    }
    if (market.symbols.isNotEmpty &&
        s.symbols.any((symbol) => !market.symbols.containsKey(symbol))) {
      return 'Yalnızca resmi katalogda açık TRY spot çiftleri seçilebilir.';
    }
    final changed = !listEquals(s.symbols, engine.settings.symbols);
    engine.settings = s;
    _seedWatchlist = false;
    backendCheck = null;
    if (!s.symbols.contains(selectedSymbol)) selectedSymbol = s.symbol;
    await save();
    if (changed && !offline) {
      candles.clear();
      await reconnect();
    }
    _refresh();
    return null;
  }

  Future<String?> resetPaper() async {
    if (live || engine.running || engine.busy || starting || checkingBackend) {
      return 'Önce paper modunda botu durdurun.';
    }
    if (engine.positions.isNotEmpty) {
      return 'Açık paper pozisyon varken sıfırlama yapılamaz.';
    }
    engine = TradingEngine(
        settings: engine.settings, onChange: _refresh, persist: save);
    await save();
    _refresh();
    return null;
  }

  Future<String?> configureBackend(String url, String token) async {
    if (live || engine.running || engine.busy || starting || checkingBackend) {
      return 'Backend değiştirmek için önce botu durdurup paper moduna geçin.';
    }
    BackendClient? candidate;
    try {
      candidate = BackendClient(baseUrl: url.trim(), token: token.trim());
      final health = await candidate.request('/v1/health');
      if (health['spotOnly'] != true ||
          health['readOnlyPreflight'] != true ||
          (engine.settings.symbols.length > 1 &&
              health['multiSymbol'] != true)) {
        return 'Emir göndermeyen hesap kontrolü destekleyen spot backend gerekli. Sunucuyu güncelleyin.';
      }
      await secure.write(key: 'backend-bearer', value: token.trim());
      await store?.preferences.setString('backend-url', url.trim());
      backend?.close();
      backend = candidate;
      backendUrl = url.trim();
      backendCheck = null;
      backendCheckError = '';
      _refresh();
      return null;
    } catch (e) {
      return e.toString();
    } finally {
      if (!identical(backend, candidate)) candidate?.close();
    }
  }

  Future<void> _loadBackend() async {
    if (backend != null) return;
    final token = await secure.read(key: 'backend-bearer');
    if (backendUrl.isEmpty || token == null) {
      throw const ExecutionException('Güvenli backend henüz bağlanmadı.');
    }
    backend = BackendClient(baseUrl: backendUrl, token: token);
  }

  Future<String?> verifyLiveAccount() async {
    if (engine.running || engine.busy || starting || checkingBackend) {
      return 'Hesap kontrolü için önce botu durdurun.';
    }
    checkingBackend = true;
    backendCheck = null;
    backendCheckError = '';
    _refresh();
    try {
      await _loadBackend();
      backendCheck = await backend!.preflightPortfolio(engine.settings.symbols);
      if (!setEquals(
          backendCheck!.symbols.toSet(), engine.settings.symbols.toSet())) {
        backendCheck = null;
        throw const ExecutionException(
            'Hesap kontrolü işlem çiftiyle uyuşmuyor.');
      }
      return null;
    } catch (e) {
      backendCheckError = e.toString();
      return backendCheckError;
    } finally {
      checkingBackend = false;
      _refresh();
    }
  }

  Future<String?> activateLive() async {
    if (engine.running ||
        engine.busy ||
        starting ||
        checkingBackend ||
        engine.positions.isNotEmpty) {
      return 'Önce botu durdurun ve paper pozisyonu kapatın.';
    }
    starting = true;
    final epoch = ++_controlEpoch;
    try {
      await _loadBackend();
      if (backendCheck == null) {
        return 'Önce emir göndermeyen hesap kontrolünü çalıştırın.';
      }
      final problem =
          backendCheck!.liveProblem(engine.settings, DateTime.now());
      if (problem != null) return problem;
      await save();
      final s = engine.settings;
      final liveEngine = TradingEngine(
          settings: s,
          execution: BinanceTrExecution(backend!),
          onChange: _refresh);
      final saved = store?.read('live-v2');
      if (saved != null) liveEngine.restore(saved);
      liveEngine.settings =
          s; // Use the limits just reviewed, never cached limits.
      final old = engine;
      for (final symbol in s.symbols) {
        liveEngine.coin(symbol).quote = old.quoteFor(symbol);
      }
      engine = liveEngine;
      live = true;
      _seedWatchlist = false;
      try {
        await reconcileLive();
        if (epoch != _controlEpoch) {
          throw const ExecutionException('Canlı moda geçiş iptal edildi.');
        }
      } catch (e) {
        engine = old;
        live = false;
        rethrow;
      }
      engine.persist = save;
      await save();
      _refresh();
      return null;
    } catch (e) {
      return e.toString();
    } finally {
      starting = false;
      _refresh();
    }
  }

  Future<void> reconcileLive() async {
    final j = await backend!.reconcilePortfolio(engine.settings.symbols);
    if (j['safe'] != true) {
      throw const ExecutionException(
          'Hesapta belirsiz/açık emir var. Backend uzlaştırması gerekli.');
    }
    engine.cashTry = number(j['availableTry']);
    engine.realizedPnl = number(j['realizedPnl']);
    engine.dailyEntries = number(j['dailyEntries']).toInt();
    engine.riskLocked = j['riskLocked'] == true;
    engine.dayKey = TradingEngine.istanbulDay(DateTime.now());
    engine.dayRealizedStart = engine.realizedPnl - number(j['dailyPnl']);
    if (j['events'] is List) {
      engine.events.clear();
      engine.events.addAll((j['events'] as List)
          .map((v) => TradeEvent.fromJson((v as Map).cast<String, dynamic>())));
    }
    final states = j['coins'] is Map
        ? (j['coins'] as Map).cast<String, dynamic>()
        : {engine.settings.symbol: j};
    final positions = <String, Position?>{};
    for (final symbol in engine.settings.symbols) {
      if (states[symbol] is! Map) {
        throw const ExecutionException('Eksik coin uzlaştırması.');
      }
      final data = (states[symbol] as Map).cast<String, dynamic>();
      final p = data['position'] == null
          ? null
          : Position.fromJson(
              (data['position'] as Map).cast<String, dynamic>());
      if (p != null &&
          (p.symbol != symbol ||
              p.quantity <= 0 ||
              !p.quantity.isFinite ||
              p.costBasis <= 0 ||
              !p.costBasis.isFinite)) {
        throw const ExecutionException('Coin pozisyonu uzlaştırılamadı.');
      }
      positions[symbol] = p;
    }
    for (final c in engine.coins.values) {
      c.position = null;
    }
    for (final symbol in engine.settings.symbols) {
      final data = states[symbol] as Map, c = engine.coin(symbol);
      c.position = positions[symbol];
      c.lastSellPrice = number(data['lastSellPrice']);
      c.lastSellTime = data['lastSellTime'] == null
          ? null
          : DateTime.parse(data['lastSellTime'] as String);
    }
    engine.dayStartEquity = engine.liquidationValue - number(j['dailyPnl']);
    engine.uncertainOrder = false;
    if (j['feePct'] != null) {
      engine.settings = StrategySettings.fromJson(
          engine.settings.toJson()..['feePct'] = number(j['feePct']));
    }
  }

  Future<String?> activatePaper() async {
    if (engine.running || engine.busy || starting) return 'Önce botu durdurun.';
    if (live && engine.positions.isNotEmpty) {
      return 'Canlı pozisyon varken mod değiştirilemez.';
    }
    if (live) await engine.stop();
    await save();
    live = false;
    final s = engine.settings;
    engine = TradingEngine(settings: s, onChange: _refresh, persist: save);
    final saved = store?.read('paper-v2');
    if (saved != null) {
      engine.restore(saved);
      _seedWatchlist = saved['seedWatchlistPending'] == true ||
          (saved['settings'] as Map)['symbols'] == null;
    }
    selectedSymbol = engine.settings.symbol;
    candles.clear();
    if (!offline) await reconnect();
    _refresh();
    return null;
  }

  Future<void> background() async {
    if (!live && engine.running && backgroundRunner.active) {
      await save();
      return;
    }
    ++_controlEpoch;
    if (engine.running || starting) {
      await stop();
      engine.message =
          'Uygulama arka plana geçti; bot güvenli şekilde durdu. Devam etmek için başlatın.';
    }
    await save();
    _refresh();
  }

  @override
  void dispose() {
    _disposed = true;
    _saveTimer?.cancel();
    _freshness?.cancel();
    _notificationTimer?.cancel();
    unawaited(stop().whenComplete(backgroundRunner.dispose));
    for (final s in _subscriptions) {
      unawaited(s.cancel());
    }
    unawaited(market.close());
    backend?.close();
    super.dispose();
  }
}
