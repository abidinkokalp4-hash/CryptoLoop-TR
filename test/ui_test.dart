import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cryptoloop_tr/app_controller.dart';
import 'package:cryptoloop_tr/main.dart';
import 'package:cryptoloop_tr/models.dart';
import 'package:http/http.dart' as http;
import 'fixtures/live_preflight.dart';

Future<AppController> fixture() async {
  SharedPreferences.setMockInitialValues({});
  final c = AppController(offline: true);
  await c.init();
  final now = DateTime.now();
  c.engine.quote = MarketQuote(
      symbol: 'BTC_TRY',
      last: 4097258,
      bid: 4097000,
      ask: 4097600,
      time: now,
      changePct: 1.82);
  c.engine.position = Position(
      symbol: 'BTC_TRY',
      quantity: 0.0005,
      entryPrice: 4050000,
      notional: 2025,
      buyFee: 3.0375,
      openedAt: now,
      orderId: 'P-test');
  c.engine.cashTry = 7971.9625;
  c.engine.dayStartEquity = 10000;
  c.engine.realizedPnl = 42.15;
  c.engine.events.add(TradeEvent(
      side: 'AL',
      symbol: 'BTC_TRY',
      price: 4050000,
      quantity: 0.0005,
      fee: 3.0375,
      time: now,
      orderId: 'P-test'));
  for (var i = 0; i < 70; i++) {
    final p = 4020000.0 + i * 1100 + (i % 6 - 3) * 1800;
    c.candles.add(Candle(now.subtract(Duration(minutes: 70 - i)), p, p + 12000,
        p - 8000, p + (i.isEven ? 6200 : -3200), 5 + i % 5));
  }
  return c;
}

void main() {
  setUpAll(() async {
    var dir = Directory(Platform.resolvedExecutable).parent;
    Directory? fonts;
    for (var i = 0; i < 8; i++) {
      final candidate =
          Directory('${dir.path}/bin/cache/artifacts/material_fonts');
      if (candidate.existsSync()) {
        fonts = candidate;
        break;
      }
      dir = dir.parent;
    }
    final root = Platform.environment['FLUTTER_ROOT'];
    fonts ??= root == null
        ? null
        : Directory('$root/bin/cache/artifacts/material_fonts');
    if (fonts == null || !fonts.existsSync()) {
      throw StateError('SDK font assets missing');
    }
    final roboto = FontLoader('Roboto');
    for (final file in ['Roboto-Regular.ttf', 'Roboto-Bold.ttf']) {
      roboto.addFont(File('${fonts.path}/$file')
          .readAsBytes()
          .then((b) => ByteData.sublistView(b)));
    }
    await roboto.load();
    final icons = FontLoader('MaterialIcons')
      ..addFont(File('${fonts.path}/MaterialIcons-Regular.otf')
          .readAsBytes()
          .then((b) => ByteData.sublistView(b)));
    await icons.load();
  });
  testWidgets(
      'premium dashboard and all navigation screens render on small phone',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(393, 852));
    final c = await fixture();
    await tester.pumpWidget(CryptoLoopApp(controller: c));
    await tester.pumpAndSettle();
    expect(find.text('Portföyüm'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('İşlemler'));
    await tester.pumpAndSettle();
    expect(find.text('İşlem geçmişi'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Ayarlar'));
    await tester.pumpAndSettle();
    expect(find.text('Bot ayarları'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Canlı'));
    await tester.pumpAndSettle();
    expect(find.text('Gerçek spot işlem'), findsOneWidget);
    expect(c.live, isFalse);
    await tester.tap(find.text('Vazgeç'));
    await tester.pumpAndSettle();
    expect(c.live, isFalse);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
    await tester.binding.setSurfaceSize(null);
  });
  testWidgets(
      'ten coin carousel selects chart without changing positions or capital',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(393, 852));
    final c = await fixture();
    c.engine.coin('ETH_TRY').quote = MarketQuote(
        symbol: 'ETH_TRY',
        last: 100,
        bid: 99.9,
        ask: 100.1,
        time: DateTime.now());
    await tester.pumpWidget(CryptoLoopApp(controller: c));
    await tester.pumpAndSettle();
    final eth = find.byKey(const ValueKey('watch-ETH_TRY'));
    await tester.ensureVisible(eth);
    await tester.tap(eth);
    await tester.pumpAndSettle();
    expect(c.selectedSymbol, 'ETH_TRY');
    expect(c.engine.settings.symbol, 'BTC_TRY');
    expect(c.engine.position!.orderId, 'P-test');
    expect(c.engine.settings.symbols, hasLength(10));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
    await tester.binding.setSurfaceSize(null);
  });
  testWidgets(
      'coin picker supports ten catalog validated pairs on a small phone',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(393, 852));
    final c = await fixture();
    for (final s in [
      ...StrategySettings.defaultWatchlist,
      'NEAR_TRY',
      'LTC_TRY'
    ]) {
      c.market.symbols[s] = SymbolRules(symbol: s);
    }
    await tester.pumpWidget(CryptoLoopApp(controller: c));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ayarlar'));
    await tester.pumpAndSettle();
    final picker = find.byKey(const ValueKey('choose-coins'));
    await tester.ensureVisible(picker);
    await tester.pumpAndSettle();
    await tester.tap(picker);
    await tester.pumpAndSettle();
    expect(find.text('İzlenecek coin’ler · 10/20'), findsOneWidget);
    await tester.tap(find.text('10 coin seç'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Listeyi kullan'));
    await tester.pumpAndSettle();
    expect(find.text('10 coin seçili · En fazla 20 TRY spot çift'),
        findsOneWidget);
    expect(c.engine.settings.symbols, hasLength(10));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
    await tester.binding.setSurfaceSize(null);
  });
  testWidgets('portfolio screenshot for visual QA', (tester) async {
    await tester.binding.setSurfaceSize(const Size(412, 915));
    final c = await fixture();
    const key = ValueKey('capture');
    await tester.pumpWidget(
        RepaintBoundary(key: key, child: CryptoLoopApp(controller: c)));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final boundary =
        tester.renderObject<RenderRepaintBoundary>(find.byKey(key));
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await Directory('build/qa').create(recursive: true);
      await File('build/qa/portfolio.png')
          .writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
    await tester.pumpWidget(const SizedBox());
    c.dispose();
    await tester.binding.setSurfaceSize(null);
  });
  testWidgets('read-only connection shows account without activating live',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(393, 852));
    final c = await fixture();
    final requests = <http.Request>[];
    c.backend = readOnlyBackend(requests);
    await tester.pumpWidget(CryptoLoopApp(controller: c));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ayarlar'));
    await tester.pumpAndSettle();
    final button = find.byKey(const ValueKey('verify-live-account'));
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(find.text('Hesap doğrulandı · Salt okuma'), findsOneWidget);
    expect(c.backendCheck!.availableTry, 1000);
    expect(c.live, isFalse);
    expect(c.engine.running, isFalse);
    expect(requests.every((r) => r.method == 'GET'), isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
    await tester.binding.setSurfaceSize(null);
  });
  testWidgets('account setup screenshot and disabled live approval',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(412, 915));
    final c = await fixture();
    c.backend = readOnlyBackend([]);
    const key = ValueKey('live-setup-capture');
    await tester.pumpWidget(
        RepaintBoundary(key: key, child: CryptoLoopApp(controller: c)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ayarlar'));
    await tester.pumpAndSettle();
    final button = find.byKey(const ValueKey('verify-live-account'));
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Binance TR hesap bağlantısı'));
    await tester.pumpAndSettle();
    final boundary =
        tester.renderObject<RenderRepaintBoundary>(find.byKey(key));
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await Directory('build/qa').create(recursive: true);
      await File('build/qa/live-setup.png')
          .writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
    await tester.drag(find.byType(ListView), const Offset(0, 1000));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Canlı'));
    await tester.tap(find.text('Canlı'));
    await tester.pumpAndSettle();
    expect(find.text('Gerçek spot işlem'), findsOneWidget);
    final approval = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Canlı modu aç'));
    expect(approval.onPressed, isNull);
    expect(find.textContaining('Ekran kilitlenince bot durur'), findsOneWidget);
    expect(c.live, isFalse);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Vazgeç'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    c.dispose();
    await tester.binding.setSurfaceSize(null);
  });
}
