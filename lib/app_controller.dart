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
    engine = TradingEngine(onChange: _refresh);
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
  String interval = '1m';
  bool initialized = false,
      chartLoading = false,
      live = false,
      starting = false,
      _disposed = false;
  int _chartGeneration = 0, _controlEpoch = 0;
  MarketQuote? get quote => engine.quote;
  bool get connected => quote?.isFresh(DateTime.now()) == true;
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
        unawaited(backgroundRunner.update(engine.settings.symbol,
            engine.state.label, connected ? 'Piyasa bağlı' : connection));
      });
    }
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
          backendCheck = await backend!.preflight(engine.settings.symbol);
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
    if (live || engine.running || engine.busy || starting || checkingBackend) {
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
    if (live || engine.running || engine.busy || starting || checkingBackend) {
      return 'Backend değiştirmek için önce botu durdurup paper moduna geçin.';
    }
    BackendClient? candidate;
    try {
      candidate = BackendClient(baseUrl: url.trim(), token: token.trim());
      final health = await candidate.request('/v1/health');
      if (health['spotOnly'] != true || health['readOnlyPreflight'] != true) {
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
      backendCheck = await backend!.preflight(engine.settings.symbol);
      if (backendCheck!.symbol != engine.settings.symbol) {
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
        engine.position != null) {
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
      engine = liveEngine;
      live = true;
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
    if (engine.running || engine.busy || starting) return 'Önce botu durdurun.';
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
