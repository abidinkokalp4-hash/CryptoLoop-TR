import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'execution.dart';
import 'models.dart';

class LivePreflight {
  LivePreflight._(this.data, this.verifiedAt, this.receivedAt, [this._checks]);
  final List<LivePreflight>? _checks;
  List<LivePreflight> get checks => _checks ?? [this];
  List<String> get symbols => checks.map((c) => c.symbol).toList();
  final Map<String, dynamic> data;
  final DateTime verifiedAt, receivedAt;
  Map<String, dynamic> get account => data['account'] as Map<String, dynamic>;
  Map<String, dynamic> get market => data['market'] as Map<String, dynamic>;
  Map<String, dynamic> get reconciliation => _checks == null
      ? data['reconciliation'] as Map<String, dynamic>
      : {
          'safe': checks.every((c) => c.safe),
          'riskLocked':
              checks.any((c) => c.reconciliation['riskLocked'] == true),
          'openOrderCount': checks.fold<int>(
              0,
              (sum, c) =>
                  sum + number(c.reconciliation['openOrderCount']).toInt()),
          'unresolvedIntentCount':
              checks.first.reconciliation['unresolvedIntentCount'],
        };
  Map<String, dynamic> get limits =>
      data['serverLimits'] as Map<String, dynamic>;
  String get symbol => data['symbol'] as String;
  bool get liveEnabled => _checks == null
      ? data['liveEnabled'] == true
      : checks.every((c) => c.liveEnabled);
  bool get safe => reconciliation['safe'] == true;
  double get availableTry => number(account['availableTry']);
  double get feePct => number(account['feePct']);
  double get spreadPct => number(market['spreadPct']);
  bool isFresh(DateTime now) =>
      !now.isBefore(receivedAt) &&
      now.difference(receivedAt) <= const Duration(minutes: 5);

  factory LivePreflight.fromJson(Map<String, dynamic> j, {DateTime? now}) {
    final received = now ?? DateTime.now();
    final verified = DateTime.tryParse(
        j['verifiedAt'] is String ? j['verifiedAt'] as String : '');
    bool validNumber(dynamic v) {
      final n = double.tryParse('$v');
      return n != null && n.isFinite && n >= 0;
    }

    final account = j['account'],
        market = j['market'],
        rec = j['reconciliation'],
        limits = j['serverLimits'];
    if (j['readOnly'] != true ||
        j['keyPermissionsVerified'] != false ||
        j['withdrawalPermissionVerified'] != false ||
        j['symbol'] is! String ||
        !RegExp(r'^[A-Z0-9]+_TRY$').hasMatch(j['symbol'] as String) ||
        j['liveEnabled'] is! bool ||
        j['armed'] is! bool ||
        verified == null ||
        received.difference(verified).abs() > const Duration(seconds: 90) ||
        account is! Map<String, dynamic> ||
        market is! Map<String, dynamic> ||
        rec is! Map<String, dynamic> ||
        limits is! Map<String, dynamic> ||
        !['availableTry', 'feePct'].every((k) => validNumber(account[k])) ||
        account['canTrade'] is! bool ||
        !['bid', 'ask', 'spreadPct'].every((k) => validNumber(market[k])) ||
        number(market['bid']) <= 0 ||
        number(market['ask']) < number(market['bid']) ||
        rec['safe'] is! bool ||
        rec['riskLocked'] is! bool ||
        ![
          'openOrderCount',
          'unresolvedIntentCount',
          'historyCount',
          'tradeCount'
        ].every((k) => validNumber(rec[k]) && number(rec[k]) % 1 == 0) ||
        !['maxCapital', 'maxPosition', 'dailyLossLimit', 'maxTradesPerDay']
            .every((k) => validNumber(limits[k])) ||
        number(limits['maxTradesPerDay']) % 1 != 0) {
      throw const ExecutionException('Hesap kontrol yanıtı doğrulanamadı.');
    }
    final position = rec['position'];
    if (position != null &&
        (position is! Map<String, dynamic> ||
            position['symbol'] != j['symbol'] ||
            !['quantity', 'notional', 'buyFee']
                .every((k) => validNumber(position[k])) ||
            number(position['quantity']) <= 0 ||
            number(position['notional']) <= 0)) {
      throw const ExecutionException(
          'Bot pozisyonu kontrol yanıtı doğrulanamadı.');
    }
    return LivePreflight._(j, verified, received);
  }

  factory LivePreflight.fromPortfolioJson(Map<String, dynamic> j,
      {DateTime? now}) {
    if (j['symbols'] is! List ||
        j['checks'] is! List ||
        j['readOnly'] != true) {
      throw const ExecutionException(
          'Çok coin kontrolünü destekleyen güncel backend gerekli.');
    }
    final symbols = List<String>.from(j['symbols'] as List);
    final checks = (j['checks'] as List)
        .map((c) => LivePreflight.fromJson((c as Map).cast<String, dynamic>(),
            now: now))
        .toList();
    if (symbols.isEmpty ||
        symbols.length > 20 ||
        symbols.toSet().length != symbols.length ||
        checks.length != symbols.length ||
        !symbols.every((s) => checks.where((c) => c.symbol == s).length == 1) ||
        checks.any((c) =>
            c.availableTry != checks.first.availableTry ||
            c.feePct != checks.first.feePct ||
            ['maxCapital', 'maxPosition', 'dailyLossLimit', 'maxTradesPerDay']
                .any((k) =>
                    number(c.limits[k]) != number(checks.first.limits[k])))) {
      throw const ExecutionException(
          'Çok coin hesap kontrolü eksik veya tutarsız.');
    }
    return LivePreflight._(checks.first.data, checks.first.verifiedAt,
        checks.first.receivedAt, checks);
  }

  String? liveProblem(StrategySettings settings, DateTime now) {
    if (symbols.length != settings.symbols.length ||
        !settings.symbols.every(symbols.contains)) {
      return 'Seçili bütün coin’ler için hesap kontrolünü yeniden çalıştırın.';
    }
    double basis = 0;
    int positions = 0;
    for (final c in checks) {
      final problem = c._singleProblem(settings, now);
      if (problem != null) return '${c.symbol}: $problem';
      final p = c.reconciliation['position'];
      if (p != null) {
        basis += number(p['notional']) + number(p['buyFee']);
        positions++;
      }
    }
    if (basis > settings.maxCapital || positions > settings.maxOpenPositions) {
      return 'Mevcut toplam pozisyonlar sermaye/pozisyon sayısı sınırını aşıyor.';
    }
    return null;
  }

  String? _singleProblem(StrategySettings settings, DateTime now) {
    if (!isFresh(now)) return 'Hesap kontrolünü yeniden çalıştırın.';
    if (!liveEnabled) {
      return 'Hesap bağlantısı okunabilir; sunucuda gerçek emirler kapalı. Önce sunucuda onaylanan limitler yapılandırılmalı.';
    }
    if (!safe ||
        number(reconciliation['openOrderCount']) > 0 ||
        number(reconciliation['unresolvedIntentCount']) > 0) {
      return 'Açık/belirsiz emir veya bakiye uyuşmazlığı var. Önce hesabı uzlaştırın.';
    }
    if (account['canTrade'] != true) {
      return 'Binance TR hesabında işlem yapılamıyor. Hesap durumunu kontrol edin.';
    }
    if (settings.maxCapital > number(limits['maxCapital']) ||
        settings.maxPosition > number(limits['maxPosition']) ||
        settings.dailyLossLimit > number(limits['dailyLossLimit']) ||
        settings.maxTradesPerDay > number(limits['maxTradesPerDay'])) {
      return 'Uygulamadaki sermaye/günlük limitler sunucu sınırlarını aşıyor. Ayarları eşitleyin.';
    }
    final position = reconciliation['position'] as Map<String, dynamic>?;
    if (position != null) {
      final basis = number(position['notional']) + number(position['buyFee']);
      if (basis > settings.maxCapital || basis > settings.maxPosition) {
        return 'Mevcut bot pozisyonu yeni sermaye/pozisyon sınırını aşıyor. Önce hesabı kontrol edin.';
      }
    }
    return null;
  }
}

class BackendClient {
  BackendClient(
      {required this.baseUrl, required this.token, http.Client? client})
      : _http = client ?? http.Client() {
    final uri = Uri.parse(baseUrl);
    if (uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw const ExecutionException(
          'Backend adresi geçerli bir HTTPS adresi olmalı.');
    }
    if (token.length < 32) {
      throw const ExecutionException(
          'Backend erişim anahtarı en az 32 karakter olmalı.');
    }
  }
  final String baseUrl, token;
  final http.Client _http;
  Future<Map<String, dynamic>> request(String path,
      {Map<String, dynamic>? body}) async {
    final uri = Uri.parse('${baseUrl.replaceAll(RegExp(r'/+$'), '')}$path');
    try {
      final headers = {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json'
      };
      final request = http.Request(body == null ? 'GET' : 'POST', uri)
        ..followRedirects = false
        ..headers.addAll(headers);
      if (body != null) request.body = jsonEncode(body);
      final response = await _http
          .send(request)
          .then(http.Response.fromStream)
          .timeout(const Duration(seconds: 45));
      if (response.statusCode >= 300 && response.statusCode < 400) {
        throw ExecutionException(
            'Sunucu yönlendirmesi engellendi. Doğrudan HTTPS adresini kullanın.',
            uncertain: body != null);
      }
      final j = jsonDecode(response.body) as Map<String, dynamic>;
      if (response.statusCode != 200) {
        throw ExecutionException(
            j['error'] as String? ?? 'Backend hatası (${response.statusCode}).',
            uncertain: body != null &&
                (j['uncertain'] == true || response.statusCode >= 500));
      }
      return j;
    } on TimeoutException {
      throw ExecutionException(
          body == null
              ? 'Sunucu zaman aşımı. Hesap kontrolü tamamlanmadı.'
              : 'Backend zaman aşımı. Emir durumu uzlaştırılmalı.',
          uncertain: body != null);
    } on http.ClientException {
      throw ExecutionException(
          body == null
              ? 'Sunucuya bağlanılamadı. Hesap kontrolü tamamlanmadı.'
              : 'Backend bağlantısı kesildi. Emir durumu uzlaştırılmalı.',
          uncertain: body != null);
    } on FormatException {
      throw ExecutionException('Backend yanıtı doğrulanamadı.',
          uncertain: body != null);
    } on TypeError {
      throw ExecutionException('Backend yanıtı doğrulanamadı.',
          uncertain: body != null);
    }
  }

  Future<Map<String, dynamic>> reconcile(String symbol) =>
      request('/v1/reconcile?symbol=$symbol');
  Future<LivePreflight> preflight(String symbol) async =>
      LivePreflight.fromJson(await request('/v1/preflight?symbol=$symbol'));
  Future<LivePreflight> preflightPortfolio(List<String> symbols) async =>
      symbols.length == 1
          ? await preflight(symbols.single)
          : LivePreflight.fromPortfolioJson(
              await request('/v1/preflight?symbols=${symbols.join(',')}'));
  Future<Map<String, dynamic>> reconcilePortfolio(List<String> symbols) =>
      symbols.length == 1
          ? reconcile(symbols.single)
          : request('/v1/reconcile?symbols=${symbols.join(',')}');
  Future<void> arm(StrategySettings settings) async {
    await request('/v1/arm', body: {
      'confirmation': 'CANLI SPOT ISLEM ONAYI',
      'settings': settings.toJson()
    });
  }

  void close() => _http.close();
}

class BinanceTrExecution implements ExecutionAdapter {
  BinanceTrExecution(this.backend);
  final BackendClient backend;
  @override
  bool get isPaper => false;
  @override
  Future<Fill> buy(
      {required MarketQuote quote,
      required SymbolRules rules,
      required StrategySettings settings,
      required double budget,
      required String intentId}) async {
    final j = await backend.request('/v1/execute', body: {
      'intentId': intentId,
      'symbol': quote.symbol,
      'side': 'BUY',
      'budget': budget
    });
    return Fill.fromJson((j['fill'] as Map).cast<String, dynamic>());
  }

  @override
  Future<Fill> sell(
      {required MarketQuote quote,
      required SymbolRules rules,
      required StrategySettings settings,
      required Position position,
      required String intentId,
      bool stopLoss = false}) async {
    final j = await backend.request('/v1/execute', body: {
      'intentId': intentId,
      'symbol': quote.symbol,
      'side': 'SELL',
      'quantity': position.quantity,
      'stopLoss': stopLoss
    });
    return Fill.fromJson((j['fill'] as Map).cast<String, dynamic>());
  }

  @override
  Future<void> halt() async {
    await backend.request('/v1/halt', body: {});
  }
}
