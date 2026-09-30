import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'fixtures/market_socket.dart';
import 'package:cryptoloop_tr/binance_tr_market.dart';
import 'package:cryptoloop_tr/models.dart';

void main() {
  test(
      'ten official combined streams route trade and untagged depth by stream name',
      () async {
    final socket = FakeSocket();
    late Uri subscribed;
    final market = BinanceTrMarket(
        socketConnector: (uri) {
          subscribed = uri;
          return socket;
        },
        client: MockClient((r) async => http.Response('{}', 503)));
    for (final s in StrategySettings.defaultWatchlist) {
      market.symbols[s] = SymbolRules(symbol: s);
    }
    final received = <MarketQuote>[];
    final subscription = market.quotes.stream.listen(received.add);
    await market.connectMany(StrategySettings.defaultWatchlist,
        chartSymbol: 'BTC_TRY');
    final streams = subscribed.queryParameters['streams']!.split('/');
    expect(subscribed.host, 'stream-cloud.binance.tr');
    expect(streams, hasLength(31));
    for (final s in StrategySettings.defaultWatchlist) {
      final wire = s.replaceAll('_', '');
      expect(streams, contains('${wire.toLowerCase()}@depth5'));
      final value = (StrategySettings.defaultWatchlist.indexOf(s) + 1) * 100;
      socket.send(wire, {'e': 'trade', 's': wire, 'p': '$value'}, 'trade');
      socket.send(
          wire,
          {
            'bids': [
              ['$value', '100']
            ],
            'asks': [
              ['${value + 1}', '100']
            ]
          },
          'depth5');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(received.map((q) => q.symbol).toSet(),
        StrategySettings.defaultWatchlist.toSet());
    for (final q in received) {
      expect(q.last,
          (StrategySettings.defaultWatchlist.indexOf(q.symbol) + 1) * 100);
      expect(q.ask, q.last + 1);
    }
    final count = received.length;
    socket.frames.add(jsonEncode({
      'bids': [
        ['9000', '100']
      ],
      'asks': [
        ['9001', '100']
      ]
    }));
    socket.send('FAKETRY', {'e': 'trade', 's': 'FAKETRY', 'p': '1'}, 'trade');
    socket.send('BTCTRY', {'e': 'trade', 's': 'ETHTRY', 'p': '1'}, 'trade');
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(received.length, count);
    await subscription.cancel();
    await market.close();
    await socket.frames.close();
  });
  test(
      'chart switch changes only kline subscription, no quote reconnect or new symbols',
      () async {
    final socket = FakeSocket();
    var connections = 0;
    final market = BinanceTrMarket(
        socketConnector: (uri) {
          connections++;
          return socket;
        },
        client: MockClient((r) async => http.Response('{}', 503)));
    for (final s in ['BTC_TRY', 'ETH_TRY']) {
      market.symbols[s] = SymbolRules(symbol: s);
    }
    await market.connectMany(['BTC_TRY', 'ETH_TRY'], chartSymbol: 'BTC_TRY');
    await market.selectChart('ETH_TRY', '1h');
    expect(connections, 1);
    expect(market.watched, ['BTC_TRY', 'ETH_TRY']);
    final requests = socket.sink.messages
        .map((m) => jsonDecode(m as String) as Map)
        .toList();
    expect(requests[0]['method'], 'UNSUBSCRIBE');
    expect(requests[1]['params'], ['ethtry@kline_1h']);
    await expectLater(
        market.selectChart('SOL_TRY', '1m'), throwsA(isA<MarketException>()));
    await market.close();
    await socket.frames.close();
  });
  test(
      'portfolio REST fallback honors shared rate limit before visiting ten pairs',
      () async {
    final socket = FakeSocket();
    var requests = 0;
    final market = BinanceTrMarket(
        socketConnector: (_) => socket,
        client: MockClient((r) async {
          requests++;
          return http.Response('{}', 429, headers: {'retry-after': '60'});
        }));
    for (final s in StrategySettings.defaultWatchlist) {
      market.symbols[s] = SymbolRules(symbol: s);
    }
    await market.connectMany(StrategySettings.defaultWatchlist,
        chartSymbol: 'BTC_TRY');
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(requests, lessThanOrEqualTo(2));
    expect(market.diagnostics['lastError'], contains('hız sınırı'));
    await market.close();
    await socket.frames.close();
  });
}
