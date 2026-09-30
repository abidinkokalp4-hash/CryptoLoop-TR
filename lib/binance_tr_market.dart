import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';
import 'models.dart';

class MarketException implements Exception {
  const MarketException(this.message, {this.retryAfter = 0});
  final String message;
  final int retryAfter;
  @override
  String toString() => message;
}

// Verified against https://www.binance.tr/apidocs/ on 2026-09-30.
// Type 1 MAIN symbols only. Never substitute global BTC/USDT for BTC/TRY.
class _Tick {
  double last = 0, bid = 0, ask = 0, bidQty = 0, askQty = 0, change = 0;
  DateTime? tradeAt, bookAt;
}

class BinanceTrMarket {
  BinanceTrMarket(
      {http.Client? client, WebSocketChannel Function(Uri)? socketConnector})
      : _http = client ?? http.Client(),
        _socketConnector = socketConnector ?? WebSocketChannel.connect;
  final http.Client _http;
  final WebSocketChannel Function(Uri) _socketConnector;
  final quotes = StreamController<MarketQuote>.broadcast();
  final status = StreamController<String>.broadcast();
  final candleUpdates = StreamController<Candle>.broadcast();
  final Map<String, SymbolRules> symbols = {};
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  Timer? _retry, _watchdog, _poll;
  bool _closed = false, _connecting = false;
  int _attempt = 0, _generation = 0;
  String _symbol = 'BTC_TRY', _interval = '1m';
  List<String> _watched = ['BTC_TRY'];
  final Map<String, _Tick> _ticks = {};
  final Map<String, String> symbolErrors = {};
  final Set<int> _snapshotsRunning = {};
  DateTime? _blockedUntil;
  List<String> get watched => List.unmodifiable(_watched);
  List<String> get _activeSymbols =>
      symbols.isEmpty ? _watched : _watched.where(symbols.containsKey).toList();
  String connectionMessage = 'Piyasaya bağlanılıyor';
  String lastError = '', lastErrorEndpoint = '';
  DateTime? lastErrorAt, lastQuoteAt, nextRetryAt;
  Map<String, dynamic> get diagnostics => {
        'symbol': _symbol,
        'symbols': _watched,
        'symbolErrors': symbolErrors,
        'lastError': lastError,
        'lastErrorEndpoint': lastErrorEndpoint,
        'lastErrorAt': lastErrorAt?.toUtc().toIso8601String(),
        'lastQuoteAt': lastQuoteAt?.toUtc().toIso8601String(),
        'nextRetryAt': nextRetryAt?.toUtc().toIso8601String(),
        'status': connectionMessage,
        'symbolRulesLoaded': symbols.containsKey(_symbol),
      };
  void _state(String text) {
    connectionMessage = text;
    if (!_closed) status.add(text);
  }

  Future<dynamic> _get(Uri uri) async {
    try {
      return await _request(uri);
    } catch (e) {
      lastError = e.toString();
      lastErrorEndpoint = '${uri.host}${uri.path}';
      lastErrorAt = DateTime.now();
      rethrow;
    }
  }

  Future<dynamic> _request(Uri uri) async {
    if (_blockedUntil != null && DateTime.now().isBefore(_blockedUntil!)) {
      throw const MarketException('Borsa hız sınırı: bekleniyor.');
    }
    try {
      final r = await _http.get(uri).timeout(const Duration(seconds: 12));
      if (r.statusCode == 429 || r.statusCode == 418) {
        final seconds = int.tryParse(r.headers['retry-after'] ?? '') ?? 60;
        _blockedUntil =
            DateTime.now().add(Duration(seconds: math.max(1, seconds)));
        throw MarketException(
            'Borsa hız sınırı. $seconds saniye sonra yeniden denenecek.',
            retryAfter: seconds);
      }
      if (r.statusCode == 451) {
        throw const MarketException(
            'Borsa bu ağın bölgesinden erişimi engelliyor (451).',
            retryAfter: 60);
      }
      if (r.statusCode != 200) {
        throw MarketException('Piyasa API hatası: HTTP ${r.statusCode}.');
      }
      final j = jsonDecode(r.body);
      if (j is Map<String, dynamic> && j.containsKey('code')) {
        if (number(j['code']) != 0 || !j.containsKey('data')) {
          throw MarketException('Borsa API yanıtı geçersiz (${j['code']}).');
        }
        return j['data'];
      }
      return j;
    } on TimeoutException {
      throw const MarketException('Piyasa bağlantısı zaman aşımına uğradı.');
    } on http.ClientException {
      throw const MarketException('İnternet bağlantısı kurulamadı.');
    } on FormatException {
      throw const MarketException('Piyasa verisi okunamadı.');
    }
  }

  Future<void> loadSymbols() async {
    final j =
        await _get(Uri.https('www.binance.tr', '/open/v1/common/symbols'));
    final list = (j as Map<String, dynamic>)['list'] as List;
    symbols.clear();
    for (final item in list) {
      final r = SymbolRules.fromJson((item as Map).cast<String, dynamic>());
      if (r.type == 1 && r.tradable && r.symbol.endsWith('_TRY')) {
        symbols[r.symbol] = r;
      }
    }
    if (symbols.isEmpty) {
      throw const MarketException(
          'Borsa kullanılabilir TRY spot çifti döndürmedi.');
    }
  }

  Future<List<Candle>> candles(String symbol, String interval) async {
    final rows = await _get(Uri.https('api.binance.me', '/api/v1/klines', {
      'symbol': symbol.replaceAll('_', ''),
      'interval': interval,
      'limit': '100'
    }));
    return (rows as List).map((r) => Candle.fromRow(r as List)).toList();
  }

  Future<void> connect(String symbol, {String interval = '1m'}) =>
      connectMany([symbol], chartSymbol: symbol, interval: interval);

  Future<void> connectMany(List<String> watched,
      {required String chartSymbol, String interval = '1m'}) async {
    if (watched.isEmpty ||
        watched.length > 20 ||
        watched.toSet().length != watched.length ||
        !watched.contains(chartSymbol) ||
        watched.any((s) => !RegExp(r'^[A-Z0-9]+_TRY$').hasMatch(s))) {
      throw const MarketException('1–20 farklı TRY spot çifti seçin.');
    }
    _closed = false;
    _watched = List.of(watched);
    _symbol = chartSymbol;
    _interval = interval;
    _generation++;
    _retry?.cancel();
    _poll?.cancel();
    _watchdog?.cancel();
    await _dropSocket();
    _ticks.clear();
    symbolErrors.clear();
    _connecting = false;
    _attempt = 0;
    await _open(_generation);
    _watchdog = Timer.periodic(const Duration(seconds: 5), (_) {
      if (_activeSymbols.any((s) =>
          _ticks[s]?.bookAt == null ||
          DateTime.now().difference(_ticks[s]!.bookAt!).inSeconds > 12)) {
        _state(
            'Bazı coin’lerde güncel emir defteri yok. Yeniden bağlantı bekleniyor.');
        _reconnect(_generation);
      }
    });
    _poll = Timer.periodic(
        const Duration(seconds: 15), (_) => _snapshot(_generation));
  }

  Future<void> selectChart(String symbol, String interval) async {
    if (!_watched.contains(symbol)) {
      throw const MarketException('Grafik çifti izleme listesinde yok.');
    }
    final old = '${_symbol.replaceAll('_', '').toLowerCase()}@kline_$_interval';
    _symbol = symbol;
    _interval = interval;
    if (_channel != null) {
      _channel!.sink.add(jsonEncode({
        'method': 'UNSUBSCRIBE',
        'params': [old],
        'id': 1
      }));
      _channel!.sink.add(jsonEncode({
        'method': 'SUBSCRIBE',
        'params': [
          '${symbol.replaceAll('_', '').toLowerCase()}@kline_$interval'
        ],
        'id': 2
      }));
    }
  }

  Future<void> _open(int generation) async {
    if (_closed || _connecting || generation != _generation) return;
    _connecting = true;
    _state('Piyasaya bağlanılıyor');
    // Bootstrap REST and socket independently so a REST failure does not disable WSS.
    unawaited(_snapshot(generation));
    try {
      if (symbols.isEmpty) {
        try {
          await loadSymbols();
        } catch (e) {
          _state(e.toString());
        }
      }
      if (_closed || generation != _generation) return;
      for (final s in _watched
          .where((s) => symbols.isNotEmpty && !symbols.containsKey(s))) {
        symbolErrors[s] = 'Bu çift resmi katalogda işlem yapılabilir değil.';
      }
      final streams = [
        for (final symbol in _activeSymbols) ...[
          '${symbol.replaceAll('_', '').toLowerCase()}@trade',
          '${symbol.replaceAll('_', '').toLowerCase()}@miniTicker',
          '${symbol.replaceAll('_', '').toLowerCase()}@depth5',
        ],
        '${_symbol.replaceAll('_', '').toLowerCase()}@kline_$_interval'
      ].join('/');
      _channel = _socketConnector(
          Uri.parse('wss://stream-cloud.binance.tr/stream?streams=$streams'));
      await _channel!.ready.timeout(const Duration(seconds: 12));
      _subscription = _channel!.stream.listen(
          (event) => _receive(event, generation),
          onError: (_) => _reconnect(generation),
          onDone: () => _reconnect(generation),
          cancelOnError: true);
    } catch (_) {
      _state('Canlı bağlantı kurulamadı. Otomatik yeniden denenecek.');
      _reconnect(generation);
    } finally {
      _connecting = false;
    }
  }

  void _reconnect(int generation) {
    if (_closed || generation != _generation || (_retry?.isActive ?? false)) {
      return;
    }
    final remaining = _blockedUntil == null
        ? 0
        : _blockedUntil!.difference(DateTime.now()).inSeconds + 1;
    final seconds =
        math.max(remaining, math.min(60, 1 << math.min(_attempt++, 6)));
    nextRetryAt = DateTime.now().add(Duration(seconds: seconds));
    _state('Bağlantı yenileniyor · $seconds sn');
    _retry = Timer(Duration(seconds: seconds), () async {
      if (_closed || generation != _generation) return;
      await _dropSocket();
      if (!_closed && generation == _generation) await _open(generation);
    });
  }

  void _receive(dynamic raw, int generation) {
    if (_closed || generation != _generation) return;
    try {
      final wrapper = jsonDecode(raw as String) as Map<String, dynamic>;
      final j = (wrapper['data'] ?? wrapper) as Map<String, dynamic>;
      final stream = wrapper['stream'] as String?;
      final wireSymbol = stream?.split('@').first.toUpperCase() ??
          j['s']?.toString().toUpperCase();
      final symbol = _watched.cast<String?>().firstWhere(
          (s) => s!.replaceAll('_', '') == wireSymbol,
          orElse: () => null);
      if (j['s'] is String && j['s'].toString().toUpperCase() != wireSymbol) {
        return;
      }
      if (symbol == null) {
        return; // Never attribute an untagged depth frame to the chart coin.
      }
      final t = _ticks.putIfAbsent(symbol, _Tick.new), now = DateTime.now();
      switch (j['e']) {
        case 'trade':
          t.last = number(j['p']);
          t.tradeAt = now;
        case '24hrMiniTicker':
          t.last = number(j['c']);
          t.tradeAt = now;
          final open = number(j['o']);
          t.change = open > 0 ? (t.last / open - 1) * 100 : 0;
        case 'kline':
          final k = (j['k'] as Map).cast<String, dynamic>();
          if (symbol == _symbol && k['i'] == _interval) {
            candleUpdates.add(Candle.fromStream(k));
          }
      }
      if (j['bids'] is List &&
          j['asks'] is List &&
          (j['bids'] as List).isNotEmpty &&
          (j['asks'] as List).isNotEmpty) {
        final b = (j['bids'] as List).first as List,
            a = (j['asks'] as List).first as List;
        t.bid = number(b[0]);
        t.bidQty = number(b[1]);
        t.ask = number(a[0]);
        t.askQty = number(a[1]);
        t.bookAt = now;
      }
      _emit(symbol, t);
    } catch (_) {
      _state('Beklenmeyen piyasa mesajı atlandı; bağlantı izleniyor.');
    }
  }

  Future<void> _snapshot(int generation) async {
    if (_closed ||
        generation != _generation ||
        _snapshotsRunning.contains(generation)) {
      return;
    }
    _snapshotsRunning.add(generation);
    try {
      // At most two REST requests concurrently; WSS remains the primary feed.
      for (final symbol in _activeSymbols) {
        if (_closed || generation != _generation) return;
        final current = _ticks[symbol];
        if (current?.bookAt != null &&
            current?.tradeAt != null &&
            DateTime.now().difference(current!.bookAt!).inSeconds <= 8 &&
            DateTime.now().difference(current.tradeAt!).inSeconds <= 8) {
          continue;
        }
        if (_blockedUntil != null && DateTime.now().isBefore(_blockedUntil!)) {
          break;
        }
        try {
          final s = symbol.replaceAll('_', '');
          final values = await Future.wait([
            _get(Uri.https('api.binance.me', '/api/v3/depth',
                {'symbol': s, 'limit': '5'})),
            _get(Uri.https('api.binance.me', '/api/v3/aggTrades',
                {'symbol': s, 'limit': '1'})),
          ]);
          if (_closed || generation != _generation) return;
          final book = values[0] as Map, trades = values[1] as List;
          if ((book['bids'] as List).isEmpty ||
              (book['asks'] as List).isEmpty ||
              trades.isEmpty) {
            throw const MarketException(
                'İşlem veya emir defteri verisi eksik.');
          }
          final b = (book['bids'] as List).first as List,
              a = (book['asks'] as List).first as List;
          final t = _ticks.putIfAbsent(symbol, _Tick.new);
          t.bid = number(b[0]);
          t.bidQty = number(b[1]);
          t.ask = number(a[0]);
          t.askQty = number(a[1]);
          t.bookAt = t.tradeAt = DateTime.now();
          t.last = number((trades.last as Map)['p']);
          _emit(symbol, t);
        } catch (e) {
          if (_closed || generation != _generation) return;
          symbolErrors[symbol] = e.toString();
          _state('$symbol: $e');
          if (e is MarketException && e.retryAfter > 0) {
            _blockedUntil = DateTime.now().add(Duration(seconds: e.retryAfter));
            break;
          }
        }
      }
    } finally {
      _snapshotsRunning.remove(generation);
    }
  }

  void _emit(String symbol, _Tick t) {
    if (_closed || t.tradeAt == null || t.bookAt == null) return;
    final q = MarketQuote(
        symbol: symbol,
        last: t.last,
        bid: t.bid,
        ask: t.ask,
        time: t.bookAt!.isBefore(t.tradeAt!) ? t.bookAt! : t.tradeAt!,
        bidQty: t.bidQty,
        askQty: t.askQty,
        changePct: t.change);
    if (!q.isFresh(DateTime.now())) return;
    _attempt = 0;
    lastQuoteAt = DateTime.now();
    symbolErrors.remove(symbol);
    if (symbol == _symbol) {
      lastError = lastErrorEndpoint = '';
    }
    nextRetryAt = null;
    _state('Canlı piyasa bağlı');
    quotes.add(q);
  }

  Future<void> _dropSocket() async {
    final sub = _subscription, channel = _channel;
    _subscription = null;
    _channel = null;
    try {
      await sub?.cancel().timeout(const Duration(seconds: 2));
    } catch (_) {}
    try {
      await channel?.sink.close().timeout(const Duration(seconds: 2));
    } catch (_) {}
  }

  Future<void> close() async {
    _closed = true;
    _generation++;
    _retry?.cancel();
    _poll?.cancel();
    _watchdog?.cancel();
    await _dropSocket();
    _http.close();
    await quotes.close();
    await status.close();
    await candleUpdates.close();
  }
}
