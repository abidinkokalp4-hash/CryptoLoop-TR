import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:cryptoloop_tr/binance_tr_market.dart';

Future<void> main() async {
  final m = BinanceTrMarket();
  final messages = <String>[];
  final status = m.status.stream.listen(messages.add);
  final ready = m.quotes.stream.first.timeout(const Duration(seconds: 25));
  // Register the timeout handler before opening the connection.
  final result = ready.then(
      (q) => <String, dynamic>{
            'verified': true,
            'symbol': q.symbol,
            'price': q.last,
            'bid': q.bid,
            'ask': q.ask,
            'spreadPct': q.spreadPct
          },
      onError: (_) => <String, dynamic>{
            'verified': false,
            'reason': 'Bu runner üzerinde güncel fiyat alınamadı.'
          });
  await m.connect('BTC_TRY');
  final report = await result;
  report['checkedAt'] = DateTime.now().toUtc().toIso8601String();
  report['messages'] = messages;
  await status.cancel();
  await m.close();
  await Directory('build/qa').create(recursive: true);
  await File('build/qa/market-probe.json')
      .writeAsString(const JsonEncoder.withIndent('  ').convert(report));
  stdout.writeln(jsonEncode(report));
}
