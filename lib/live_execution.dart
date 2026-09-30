import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'execution.dart';
import 'models.dart';

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
      final response = await (body == null
              ? _http.get(uri, headers: headers)
              : _http.post(uri, headers: headers, body: jsonEncode(body)))
          .timeout(const Duration(seconds: 45));
      final j = jsonDecode(response.body) as Map<String, dynamic>;
      if (response.statusCode != 200) {
        throw ExecutionException(
            j['error'] as String? ?? 'Backend hatası (${response.statusCode}).',
            uncertain: j['uncertain'] == true || response.statusCode >= 500);
      }
      return j;
    } on TimeoutException {
      throw const ExecutionException(
          'Backend zaman aşımı. Emir durumu uzlaştırılmalı.',
          uncertain: true);
    } on http.ClientException {
      throw const ExecutionException(
          'Backend bağlantısı kesildi. Emir durumu uzlaştırılmalı.',
          uncertain: true);
    } on FormatException {
      throw const ExecutionException('Backend yanıtı doğrulanamadı.',
          uncertain: true);
    }
  }

  Future<Map<String, dynamic>> reconcile(String symbol) =>
      request('/v1/reconcile?symbol=$symbol');
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
