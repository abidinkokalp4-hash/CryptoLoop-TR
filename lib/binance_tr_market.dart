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
class BinanceTrMarket {
  BinanceTrMarket({http.Client? client}) : _http = client ?? http.Client();
  final http.Client _http;
  final quotes = StreamController<MarketQuote>.broadcast();
  final status = StreamController<String>.broadcast();
  final candleUpdates = StreamController<Candle>.broadcast();
  final Map<String, SymbolRules> symbols = {};
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  Timer? _retry, _watchdog, _poll;
  bool _closed = false, _connecting = false, _polling = false;
  int _attempt = 0, _generation = 0;
  String _symbol = 'BTC_TRY', _interval = '1m';
  double _last = 0, _bid = 0, _ask = 0, _bidQty = 0, _askQty = 0, _change = 0;
  DateTime? _tradeAt, _bookAt, _blockedUntil;
  String connectionMessage = 'Piyasaya bağlanılıyor';
  String lastError = '', lastErrorEndpoint = '';
  DateTime? lastErrorAt, lastQuoteAt, nextRetryAt;
  Map<String, dynamic> get diagnostics => {
        'symbol': _symbol,
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

  Future<void> connect(String symbol, {String interval = '1m'}) async {
    _closed = false;
    _symbol = symbol;
    _interval = interval;
    _generation++;
    _retry?.cancel();
    _poll?.cancel();
    _watchdog?.cancel();
    await _dropSocket();
    _last = _bid = _ask = _bidQty = _askQty = 0;
    _tradeAt = _bookAt = null;
    _connecting = false;
    _attempt = 0;
    await _open(_generation);
    _watchdog = Timer.periodic(const Duration(seconds: 5), (_) {
      if (_bookAt == null ||
          DateTime.now().difference(_bookAt!).inSeconds > 12) {
        _state(
            'Güncel emir defteri yok. Otomatik yeniden bağlantı bekleniyor.');
        _reconnect(_generation);
      }
    });
    _poll = Timer.periodic(const Duration(seconds: 15), (_) {
      if (_bookAt == null ||
          DateTime.now().difference(_bookAt!).inSeconds > 10) {
        _snapshot(_generation);
      }
    });
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
      final s = _symbol.replaceAll('_', '').toLowerCase();
      final streams = '$s@trade/$s@miniTicker/$s@depth5/$s@kline_$_interval';
      _channel = WebSocketChannel.connect(
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
    final seconds = math.min(60, 1 << math.min(_attempt++, 6));
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
      final now = DateTime.now();
      switch (j['e']) {
        case 'trade':
          _last = number(j['p']);
          _tradeAt = now;
        case '24hrMiniTicker':
          _last = number(j['c']);
          _tradeAt = now;
          final open = number(j['o']);
          _change = open > 0 ? (_last / open - 1) * 100 : 0;
        case 'kline':
          candleUpdates
              .add(Candle.fromStream((j['k'] as Map).cast<String, dynamic>()));
      }
      if (j['bids'] is List &&
          j['asks'] is List &&
          (j['bids'] as List).isNotEmpty &&
          (j['asks'] as List).isNotEmpty) {
        final b = (j['bids'] as List).first as List,
            a = (j['asks'] as List).first as List;
        _bid = number(b[0]);
        _bidQty = number(b[1]);
        _ask = number(a[0]);
        _askQty = number(a[1]);
        _bookAt = now;
      }
      _emit();
    } catch (_) {
      _state('Beklenmeyen piyasa mesajı atlandı; bağlantı izleniyor.');
    }
  }

  Future<void> _snapshot(int generation) async {
    if (_closed || generation != _generation || _polling) return;
    _polling = true;
    try {
      final s = _symbol.replaceAll('_', '');
      final values = await Future.wait([
        _get(Uri.https(
            'api.binance.me', '/api/v3/depth', {'symbol': s, 'limit': '5'})),
        _get(Uri.https('api.binance.me', '/api/v3/aggTrades',
            {'symbol': s, 'limit': '1'})),
      ]);
      if (_closed || generation != _generation) return;
      final book = values[0] as Map, trades = values[1] as List;
      if ((book['bids'] as List).isEmpty ||
          (book['asks'] as List).isEmpty ||
          trades.isEmpty) {
        throw const MarketException('İşlem veya emir defteri verisi eksik.');
      }
      final b = (book['bids'] as List).first as List,
          a = (book['asks'] as List).first as List;
      _bid = number(b[0]);
      _bidQty = number(b[1]);
      _ask = number(a[0]);
      _askQty = number(a[1]);
      _bookAt = DateTime.now();
      _last = number((trades.last as Map)['p']);
      _tradeAt = DateTime.now();
      _emit();
    } catch (e) {
      if (!_closed && generation == _generation) _state(e.toString());
    } finally {
      _polling = false;
    }
  }

  void _emit() {
    if (_closed || _tradeAt == null || _bookAt == null) return;
    final q = MarketQuote(
        symbol: _symbol,
        last: _last,
        bid: _bid,
        ask: _ask,
        time: _bookAt!.isBefore(_tradeAt!) ? _bookAt! : _tradeAt!,
        bidQty: _bidQty,
        askQty: _askQty,
        changePct: _change);
    if (!q.isFresh(DateTime.now())) return;
    _attempt = 0;
    lastQuoteAt = DateTime.now();
    lastError = lastErrorEndpoint = '';
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
