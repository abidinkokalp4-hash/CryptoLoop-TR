import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:cryptoloop_tr/binance_tr_market.dart';
import 'package:cryptoloop_tr/models.dart';

void main() {
  test('official TR symbols and filters, only MAIN TRY spot markets', () async {
    final m = BinanceTrMarket(client: MockClient((r) async {
      expect(r.url.host, 'www.binance.tr');
      expect(r.url.path, '/open/v1/common/symbols');
      return http.Response(
          '{"code":0,"data":{"list":[{"symbol":"BTC_TRY","type":1,"spotTradingEnable":1,"orderTypes":["MARKET"],"filters":[{"filterType":"LOT_SIZE","minQty":"0.00001","maxQty":"5","stepSize":"0.00001"},{"filterType":"NOTIONAL","minNotional":"100"}]}]}}',
          200);
    }));
    await m.loadSymbols();
    final r = m.symbols['BTC_TRY']!;
    expect(r.minNotional, 100);
    expect(r.stepSize, 0.00001);
    await m.close();
  });
  test('429 respects Retry-After and does not spam endpoints', () async {
    var calls = 0;
    final m = BinanceTrMarket(client: MockClient((r) async {
      calls++;
      return http.Response('{}', 429, headers: {'retry-after': '60'});
    }));
    await expectLater(m.loadSymbols(), throwsA(isA<MarketException>()));
    await expectLater(m.loadSymbols(), throwsA(isA<MarketException>()));
    expect(calls, 1);
    await m.close();
  });
  test('451 location restriction is an explicit error, never zero price',
      () async {
    final m = BinanceTrMarket(
        client: MockClient((r) async => http.Response('{}', 451)));
    await expectLater(m.loadSymbols(),
        throwsA(predicate((e) => e.toString().contains('451'))));
    await m.close();
  });
  test('official candle endpoint and array data are parsed', () async {
    final m = BinanceTrMarket(client: MockClient((r) async {
      expect(r.url.host, 'api.binance.me');
      expect(r.url.path, '/api/v1/klines');
      expect(r.url.queryParameters['symbol'], 'BTCTRY');
      return http.Response(
          '{"code":0,"data":[[1000,"100","102","99","101","5"]]}', 200);
    }));
    final candles = await m.candles('BTC_TRY', '1m');
    expect(candles.single.close, 101);
    await m.close();
  });
  test('broken response and negative API code are handled', () async {
    final m = BinanceTrMarket(
        client: MockClient(
            (r) async => http.Response('{"code":-1000,"msg":"error"}', 200)));
    await expectLater(m.loadSymbols(), throwsA(isA<MarketException>()));
    await m.close();
  });
  test('lot and notional limits are validated', () {
    const r = SymbolRules(
        symbol: 'BTC_TRY',
        stepSize: 0.01,
        minQty: 0.01,
        maxQty: 10,
        minNotional: 100);
    expect(r.floorQuantity(0.123), 0.12);
    expect(r.validateOrder(0.01, 100), isNotNull);
    expect(r.validateOrder(1, 100), isNull);
  });
}
