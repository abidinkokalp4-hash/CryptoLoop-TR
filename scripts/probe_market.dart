import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:cryptoloop_tr/binance_tr_market.dart';
import 'package:cryptoloop_tr/models.dart';

Future<void> main() async {
  final m = BinanceTrMarket();
  final messages = <String>[], seen = <String, MarketQuote>{};
  final status = m.status.stream.listen(messages.add);
  var watched = List.of(StrategySettings.defaultWatchlist);
  final ready = Completer<void>();
  final prices = m.quotes.stream.listen((q) {
    if (m.symbols.containsKey(q.symbol)) seen[q.symbol] = q;
    if (!ready.isCompleted &&
        watched.length >= 10 &&
        watched.every((s) => seen[s]?.isFresh(DateTime.now()) == true)) {
      ready.complete();
    }
  });
  final result = ready.future
      .timeout(const Duration(seconds: 25))
      .then((_) => true, onError: (_) => false);
  try {
    await m.loadSymbols();
    final candidates = [
      ...StrategySettings.defaultWatchlist,
      ...(m.symbols.keys.toList()..sort())
    ];
    watched = candidates.where(m.symbols.containsKey).toSet().take(10).toList();
    if (watched.isEmpty) {
      throw const MarketException('İşlem yapılabilir TRY spot çifti yok.');
    }
    await m.connectMany(watched, chartSymbol: watched.first);
  } catch (e) {
    messages.add(e.toString());
  }
  final verified = await result;
  final report = <String, dynamic>{
    'verified': verified,
    'configuredSymbols': watched,
    'verifiedCoinCount': seen.length,
    'quotes': {
      for (final e in seen.entries)
        e.key: {'last': e.value.last, 'bid': e.value.bid, 'ask': e.value.ask}
    },
    if (!verified)
      'reason': 'Bu runner üzerinde 10 coin güncel fiyatı doğrulanamadı.',
    'checkedAt': DateTime.now().toUtc().toIso8601String(),
    'messages': messages,
    'diagnostics': m.diagnostics
  };
  await prices.cancel();
  await status.cancel();
  await m.close();
  await Directory('build/qa').create(recursive: true);
  await File('build/qa/market-probe.json')
      .writeAsString(const JsonEncoder.withIndent('  ').convert(report));
  stdout.writeln(jsonEncode(report));
}
