import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'binance_tr_market.dart';
import 'execution.dart';
import 'live_execution.dart';
import 'storage.dart';
import 'trading_engine.dart';

class AppController extends ChangeNotifier {
  AppController({BinanceTrMarket? market, this.offline = false})
      : market = market ?? BinanceTrMarket() {
    engine = TradingEngine(onChange: _refresh);
  }
  final BinanceTrMarket market;
  final bool offline;
  late TradingEngine engine;
  AppStore? store;
  BackendClient? backend;
  final secure = const FlutterSecureStorage(
      aOptions: AndroidOptions(encryptedSharedPreferences: true));
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  final List<Candle> candles = [];
  Timer? _saveTimer, _freshness;
  String connection = 'Piyasaya bağlanılıyor',
      chartError = '',
      loadError = '',
      backendUrl = '';
  String interval = '1m';
  bool initialized = false,
      chartLoading = false,
      live = false,
      _disposed = false;
  int _chartGeneration = 0;
  MarketQuote? get quote => engine.quote;
  bool get connected => quote?.isFresh(DateTime.now()) == true;
  List<String> get symbolNames => market.symbols.keys.toList()..sort();
  String get storageKey => live ? 'live-v2' : 'paper-v2';
  void _refresh() {
    if (!_disposed) notifyListeners();
  }

  Future<void> init() async {
    if (initialized) return;
    try {
      store = AppStore(await SharedPreferences.getInstance());
      final saved = store!.read('paper-v2');
      if (saved != null) engine.restore(saved);
      backendUrl = store!.preferences.getString('backend-url') ?? '';
    } catch (e) {
      loadError = e.toString();
    }
    engine.persist = save;
    initialized = true;
    _refresh();
    if (offline) {
      connection = 'Test verisi';
      return;
    }
    _subscriptions.add(market.quotes.stream.listen((q) {
      final rules = market.symbols[q.symbol];
      if (rules == null) {
        engine.quote = q;
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
      await store!.write(storageKey, engine.toJson());
    } catch (_) {
      engine.running = false;
      engine.state = BotState.error;
      loadError = 'Kayıt yazılamadı. Bot durduruldu; işlem verilerini koruyun.';
      _refresh();
      rethrow;
    }
  }

  Future<void> reconnect() async {
    await market.connect(engine.settings.symbol, interval: interval);
    unawaited(loadChart());
  }

  Future<void> loadChart() async {
    final g = ++_chartGeneration;
    chartLoading = true;
    chartError = '';
    _refresh();
    try {
      final data = await market.candles(engine.settings.symbol, interval);
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
    await reconnect();
  }

  Future<String?> start() async {
    if (loadError.isNotEmpty) return loadError;
    if (!connected) {
      return 'Güncel piyasa verisi yok. Bağlantı kurulunca yeniden deneyin.';
    }
    if (market.symbols[engine.settings.symbol] == null) {
      try {
        await market.loadSymbols();
      } catch (e) {
        return e.toString();
      }
    }
    if (live) {
      try {
        await reconcileLive();
        await backend!.arm(engine.settings);
      } catch (e) {
        return e.toString();
      }
    }
    engine.start();
    await save();
    _refresh();
    return null;
  }

  Future<String?> applySettings(StrategySettings s) async {
    if (engine.running || engine.busy) {
      return 'Ayar değiştirmek için botu tamamen durdurun.';
    }
    final problem = s.validate();
    if (problem != null) return problem;
    if (engine.position != null && s.symbol != engine.settings.symbol) {
      return 'Açık pozisyon varken işlem çifti değiştirilemez.';
    }
    if (engine.position != null &&
        (s.maxCapital < engine.position!.costBasis ||
            s.maxPosition < engine.position!.costBasis)) {
      return 'Sermaye limiti açık pozisyon maliyetinin altına indirilemez.';
    }
    final changed = s.symbol != engine.settings.symbol;
    engine.settings = s;
    await save();
    if (changed) {
      engine.quote = null;
      engine.lastSellPrice = 0;
      candles.clear();
      await reconnect();
    }
    _refresh();
    return null;
  }

  Future<String?> resetPaper() async {
    if (live || engine.running || engine.busy) {
      return 'Önce paper modunda botu durdurun.';
    }
    if (engine.position != null) {
      return 'Açık paper pozisyon varken sıfırlama yapılamaz.';
    }
    engine = TradingEngine(
        settings: engine.settings, onChange: _refresh, persist: save);
    await save();
    _refresh();
    return null;
  }

  Future<String?> configureBackend(String url, String token) async {
    try {
      final candidate = BackendClient(baseUrl: url.trim(), token: token.trim());
      final health = await candidate.request('/v1/health');
      if (health['spotOnly'] != true) {
        candidate.close();
        return 'Spot backend doğrulanamadı.';
      }
      backend?.close();
      backend = candidate;
      backendUrl = url.trim();
      await secure.write(key: 'backend-bearer', value: token.trim());
      await store?.preferences.setString('backend-url', backendUrl);
      _refresh();
      return null;
    } catch (e) {
      return e.toString();
    }
  }

  Future<String?> activateLive() async {
    if (engine.running || engine.busy || engine.position != null) {
      return 'Önce botu durdurun ve paper pozisyonu kapatın.';
    }
    try {
      if (backend == null) {
        final token = await secure.read(key: 'backend-bearer');
        if (backendUrl.isEmpty || token == null) {
          return 'Güvenli backend henüz bağlanmadı.';
        }
        backend = BackendClient(baseUrl: backendUrl, token: token);
      }
      await save();
      final s = engine.settings;
      final liveEngine = TradingEngine(
          settings: s,
          execution: BinanceTrExecution(backend!),
          onChange: _refresh);
      final saved = store?.read('live-v2');
      if (saved != null) liveEngine.restore(saved);
      final old = engine;
      engine = liveEngine;
      live = true;
      try {
        await reconcileLive();
        await backend!.arm(engine.settings);
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
    }
  }

  Future<void> reconcileLive() async {
    final j = await backend!.reconcile(engine.settings.symbol);
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
    engine.lastSellPrice = number(j['lastSellPrice']);
    engine.lastSellTime = j['lastSellTime'] == null
        ? null
        : DateTime.parse(j['lastSellTime'] as String);
    engine.position = j['position'] == null
        ? null
        : Position.fromJson((j['position'] as Map).cast<String, dynamic>());
    engine.dayStartEquity = engine.liquidationValue - number(j['dailyPnl']);
    engine.uncertainOrder = false;
    if (j['feePct'] != null) {
      engine.settings = StrategySettings.fromJson(
          engine.settings.toJson()..['feePct'] = number(j['feePct']));
    }
  }

  Future<String?> activatePaper() async {
    if (engine.running || engine.busy) return 'Önce botu durdurun.';
    if (live && engine.position != null) {
      return 'Canlı pozisyon varken mod değiştirilemez.';
    }
    if (live) await engine.stop();
    await save();
    live = false;
    final s = engine.settings;
    engine = TradingEngine(settings: s, onChange: _refresh, persist: save);
    final saved = store?.read('paper-v2');
    if (saved != null) engine.restore(saved);
    candles.clear();
    if (!offline) await reconnect();
    _refresh();
    return null;
  }

  Future<void> background() async {
    if (engine.running) {
      await engine.stop();
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
    for (final s in _subscriptions) {
      unawaited(s.cancel());
    }
    unawaited(market.close());
    backend?.close();
    super.dispose();
  }
}
