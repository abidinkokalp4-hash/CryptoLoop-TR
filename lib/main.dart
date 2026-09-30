import 'dart:async';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'app_controller.dart';
import 'models.dart';
import 'price_chart.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const CryptoLoopApp());
}

const background = Color(0xFF080E19);
const surface = Color(0xFF111B2B);
const border = Color(0xFF243247);
String money(double v, {bool signed = false}) =>
    '${signed && v > 0 ? '+' : ''}${NumberFormat('#,##0.00', 'tr_TR').format(v)} TL';
String pct(double v) => '${v > 0 ? '+' : ''}${v.toStringAsFixed(2)}%';
Color pnlColor(double v) => v < 0 ? loss : mint;

class CryptoLoopApp extends StatelessWidget {
  const CryptoLoopApp({super.key, this.controller});
  final AppController? controller;
  @override
  Widget build(BuildContext context) => MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'CryptoLoop TR',
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        fontFamily: 'Roboto',
        scaffoldBackgroundColor: background,
        colorScheme: const ColorScheme.dark(
            primary: mint,
            secondary: Color(0xFF67A5FF),
            surface: surface,
            error: loss),
        appBarTheme: const AppBarTheme(
            backgroundColor: background, surfaceTintColor: Colors.transparent),
        inputDecorationTheme: InputDecorationTheme(
            filled: true,
            fillColor: background,
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: border)),
            enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: border)),
            contentPadding: const EdgeInsets.all(14)),
        navigationBarTheme: const NavigationBarThemeData(
            backgroundColor: Color(0xFF0E1725),
            indicatorColor: Color(0xFF214237)),
        filledButtonTheme: FilledButtonThemeData(
            style: FilledButton.styleFrom(
                minimumSize: const Size(0, 48),
                textStyle: const TextStyle(
                    fontFamily: 'Roboto', fontWeight: FontWeight.w700),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)))),
      ),
      home: AppShell(controller: controller));
}

class AppShell extends StatefulWidget {
  const AppShell({super.key, this.controller});
  final AppController? controller;
  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> with WidgetsBindingObserver {
  late final AppController c;
  int page = 0;
  @override
  void initState() {
    super.initState();
    c = widget.controller ?? AppController();
    c.addListener(_update);
    WidgetsBinding.instance.addObserver(this);
    unawaited(c.init());
  }

  void _update() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(c.background());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    c.removeListener(_update);
    if (widget.controller == null) c.dispose();
    super.dispose();
  }

  void feedback(String? message) {
    if (mounted && message != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> start() async {
    if (c.live &&
        !await confirm(context, 'Canlı botu başlat',
            'Binance TR hesabınıza gerçek spot emirler gönderilecek. Sermaye sınırı: ${money(c.engine.settings.maxCapital)}. Bu strateji kâr garantisi vermez.',
            danger: true)) {
      return;
    }
    feedback(await c.start());
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
            toolbarHeight: 72,
            titleSpacing: 20,
            title: Row(children: [
              Container(
                  width: 39,
                  height: 39,
                  decoration: BoxDecoration(
                      color: mint.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(12)),
                  child: const Icon(Icons.all_inclusive_rounded,
                      color: mint, size: 25)),
              const SizedBox(width: 11),
              const Expanded(
                  child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('CryptoLoop TR',
                                style: TextStyle(
                                    fontSize: 19,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: -0.5)),
                            Text('SPOT İŞLEM ASİSTANI',
                                style: TextStyle(
                                    fontSize: 9,
                                    color: muted,
                                    letterSpacing: 1.7))
                          ]))),
            ]),
            actions: [
              Padding(
                  padding: const EdgeInsets.only(right: 20),
                  child: BadgePill(
                      c.live ? 'CANLI' : 'PAPER', c.live ? loss : mint))
            ]),
        body: !c.initialized
            ? const Center(child: CircularProgressIndicator())
            : IndexedStack(index: page, children: [
                Dashboard(c: c, onStart: start, onMessage: feedback),
                TradesPage(c: c),
                SettingsPage(c: c, onMessage: feedback)
              ]),
        bottomNavigationBar: NavigationBar(
            height: 68,
            selectedIndex: page,
            onDestinationSelected: (i) => setState(() => page = i),
            destinations: const [
              NavigationDestination(
                  icon: Icon(Icons.grid_view_rounded), label: 'Portföy'),
              NavigationDestination(
                  icon: Icon(Icons.swap_horiz_rounded), label: 'İşlemler'),
              NavigationDestination(
                  icon: Icon(Icons.tune_rounded), label: 'Ayarlar')
            ]),
      );
}

class BadgePill extends StatelessWidget {
  const BadgePill(this.text, this.color, {super.key});
  final String text;
  final Color color;
  @override
  Widget build(BuildContext context) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(7),
          border: Border.all(color: color.withValues(alpha: 0.3))),
      child: Text(text,
          style: TextStyle(
              color: color,
              fontWeight: FontWeight.w700,
              fontSize: 10,
              letterSpacing: 0.6)));
}

class Panel extends StatelessWidget {
  const Panel(
      {super.key, required this.child, this.padding = 18, this.gradient});
  final Widget child;
  final double padding;
  final Gradient? gradient;
  @override
  Widget build(BuildContext context) => Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 16),
      padding: EdgeInsets.all(padding),
      decoration: BoxDecoration(
          color: surface,
          gradient: gradient,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: border)),
      child: child);
}

class ValuePair extends StatelessWidget {
  const ValuePair(this.label, this.value,
      {super.key, this.color, this.large = false});
  final String label, value;
  final Color? color;
  final bool large;
  @override
  Widget build(BuildContext context) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: const TextStyle(color: muted, fontSize: 11)),
        const SizedBox(height: 5),
        Text(value,
            style: TextStyle(
                fontSize: large ? 18 : 13,
                fontWeight: FontWeight.w700,
                color: color),
            maxLines: 2),
      ]);
}

class Dashboard extends StatelessWidget {
  const Dashboard(
      {super.key,
      required this.c,
      required this.onStart,
      required this.onMessage});
  final AppController c;
  final VoidCallback onStart;
  final void Function(String?) onMessage;
  @override
  Widget build(BuildContext context) {
    final e = c.engine, q = c.quote, m = e.metrics;
    final today = e.dailyPnl;
    return RefreshIndicator(
        onRefresh: c.reconnect,
        child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
            children: [
              Row(children: [
                Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: c.connected ? mint : loss)),
                const SizedBox(width: 7),
                Expanded(
                    child: Text(
                        c.connected ? 'Piyasa bağlı' : 'Bağlantı bekleniyor',
                        style: const TextStyle(fontSize: 11, color: muted))),
                Icon(Icons.smart_toy_outlined,
                    size: 14, color: e.running ? mint : muted),
                const SizedBox(width: 5),
                Text(e.running ? 'Bot açık' : 'Bot kapalı',
                    style: TextStyle(
                        fontSize: 11, color: e.running ? mint : muted))
              ]),
              const SizedBox(height: 19),
              const Row(children: [
                Text('Portföyüm',
                    style: TextStyle(
                        fontSize: 27,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.8)),
                Spacer(),
                Text('TRY', style: TextStyle(color: muted, fontSize: 12))
              ]),
              const SizedBox(height: 15),
              if (!c.connected)
                Panel(
                    padding: 14,
                    child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Icon(Icons.wifi_off_rounded,
                              size: 18, color: loss),
                          const SizedBox(width: 10),
                          Expanded(
                              child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                const Text('Canlı veri bekleniyor',
                                    style: TextStyle(
                                        fontWeight: FontWeight.w700,
                                        fontSize: 12)),
                                const SizedBox(height: 4),
                                Text(c.connection,
                                    style: const TextStyle(
                                        fontSize: 11, color: muted)),
                                if (c.market.lastError.isNotEmpty)
                                  Text(c.market.lastError,
                                      style: const TextStyle(
                                          fontSize: 11, color: loss)),
                                if (c.market.lastErrorEndpoint.isNotEmpty)
                                  Text(c.market.lastErrorEndpoint,
                                      style: const TextStyle(
                                          fontSize: 10, color: muted)),
                                const Text(
                                    'Güncel veri gelmeden yeni emir açılmaz.',
                                    style:
                                        TextStyle(fontSize: 11, color: muted))
                              ])),
                          IconButton(
                              tooltip: 'Yeniden bağlan',
                              onPressed: c.reconnect,
                              icon: const Icon(Icons.refresh, size: 19)),
                        ])),
              if (c.loadError.isNotEmpty)
                Panel(
                    child:
                        Text(c.loadError, style: const TextStyle(color: loss))),
              Panel(
                  gradient: const LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        Color(0xFF183849),
                        Color(0xFF14263D),
                        Color(0xFF111B2B)
                      ]),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(children: [
                          const Text('TOPLAM PORTFÖY',
                              style: TextStyle(
                                  color: muted,
                                  fontSize: 10,
                                  letterSpacing: 1.4)),
                          const Spacer(),
                          Icon(Icons.account_balance_wallet_outlined,
                              color: mint.withValues(alpha: 0.8), size: 20)
                        ]),
                        const SizedBox(height: 12),
                        Text(money(e.markValue),
                            style: const TextStyle(
                                fontSize: 29,
                                fontWeight: FontWeight.w800,
                                letterSpacing: -1)),
                        const SizedBox(height: 10),
                        Row(children: [
                          BadgePill(
                              money(today, signed: true), pnlColor(today)),
                          const SizedBox(width: 8),
                          const Text('Bugünkü K/Z',
                              style: TextStyle(color: muted, fontSize: 11))
                        ]),
                        const Padding(
                            padding: EdgeInsets.symmetric(vertical: 16),
                            child: Divider(color: border, height: 1)),
                        Row(children: [
                          Expanded(
                              child: ValuePair(
                                  'Kullanılabilir TL', money(e.cashTry))),
                          Expanded(
                              child: ValuePair(
                                  'Kripto değeri',
                                  money((e.position?.quantity ?? 0) *
                                      (q?.last ??
                                          e.position?.entryPrice ??
                                          0))))
                        ]),
                        const SizedBox(height: 14),
                        ValuePair('Toplam gerçekleşen K/Z',
                            money(e.realizedPnl, signed: true),
                            color: pnlColor(e.realizedPnl)),
                      ])),
              Panel(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Row(children: [
                      Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                              color: const Color(0xFFF8AE36)
                                  .withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(10)),
                          child: const Icon(Icons.currency_bitcoin_rounded,
                              color: Color(0xFFF8AE36), size: 26)),
                      const SizedBox(width: 11),
                      Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(e.settings.symbol.replaceAll('_', ' / '),
                                style: const TextStyle(
                                    fontWeight: FontWeight.w800, fontSize: 15)),
                            const Text('Binance TR · Spot',
                                style: TextStyle(fontSize: 10, color: muted))
                          ]),
                      const Spacer(),
                      if (q != null)
                        BadgePill(pct(q.changePct), pnlColor(q.changePct)),
                    ]),
                    const SizedBox(height: 15),
                    Text(q == null ? 'Fiyat yükleniyor…' : money(q.last),
                        style: const TextStyle(
                            fontSize: 25,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -0.6)),
                    const SizedBox(height: 3),
                    Text(
                        q == null
                            ? 'Resmi piyasa bağlantısı bekleniyor'
                            : '24 saatlik değişim · ${c.connected ? 'canlı' : 'son bilinen veri'}',
                        style: const TextStyle(color: muted, fontSize: 10)),
                    const SizedBox(height: 18),
                    SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(children: [
                          for (final period in const [
                            ('1dk', '1m'),
                            ('1sa', '1h'),
                            ('4sa', '4h'),
                            ('1g', '1d'),
                            ('1hf', '1w'),
                            ('1ay', '1M')
                          ])
                            Padding(
                                padding: const EdgeInsets.only(right: 6),
                                child: ChoiceChip(
                                    label: Text(period.$1,
                                        style: const TextStyle(fontSize: 11)),
                                    selected: c.interval == period.$2,
                                    showCheckmark: false,
                                    onSelected: (_) => c.setInterval(period.$2),
                                    visualDensity: VisualDensity.compact)),
                        ])),
                    if (c.chartLoading)
                      const Padding(
                          padding: EdgeInsets.only(top: 12),
                          child: LinearProgressIndicator(minHeight: 2)),
                    if (c.chartError.isNotEmpty && c.candles.isEmpty)
                      SizedBox(
                          height: 200,
                          child: Center(
                              child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                const Icon(Icons.show_chart, color: muted),
                                const SizedBox(height: 10),
                                Text(c.chartError,
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(
                                        color: muted, fontSize: 11)),
                                TextButton(
                                    onPressed: c.loadChart,
                                    child: const Text('Grafiği yeniden yükle'))
                              ])))
                    else
                      PriceChart(
                          candles: c.candles,
                          trades: e.events
                              .where((t) => t.symbol == e.settings.symbol)
                              .toList()),
                    const SizedBox(height: 16),
                    const Divider(color: border, height: 1),
                    const SizedBox(height: 14),
                    Row(children: [
                      Expanded(
                          child: ValuePair('Alış (bid)',
                              q == null ? 'Veri bekleniyor' : money(q.bid),
                              color: mint)),
                      Expanded(
                          child: ValuePair('Satış (ask)',
                              q == null ? 'Veri bekleniyor' : money(q.ask),
                              color: loss)),
                      ValuePair(
                          'Spread',
                          q == null
                              ? '—'
                              : '${q.spreadPct.toStringAsFixed(3)}%')
                    ]),
                  ])),
              Panel(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Row(children: [
                      const Icon(Icons.auto_awesome, color: mint, size: 20),
                      const SizedBox(width: 9),
                      const Text('Bot kontrolü',
                          style: TextStyle(
                              fontWeight: FontWeight.w800, fontSize: 16)),
                      const Spacer(),
                      BadgePill(e.running ? 'AKTİF' : 'KAPALI',
                          e.running ? mint : muted)
                    ]),
                    const SizedBox(height: 15),
                    Text(e.state.label,
                        style: const TextStyle(
                            fontWeight: FontWeight.w700, fontSize: 14)),
                    const SizedBox(height: 7),
                    Text(e.message,
                        style: const TextStyle(
                            color: muted, fontSize: 12, height: 1.5)),
                    if (m != null) ...[
                      const SizedBox(height: 15),
                      ValuePair('Satış için gereken minimum bid',
                          money(m.requiredBid),
                          color: mint)
                    ],
                    if (e.lastSellPrice > 0 && e.position == null) ...[
                      const SizedBox(height: 15),
                      ValuePair('Yeniden alım için izlenen seviye',
                          money(e.reentryLevel))
                    ],
                    const SizedBox(height: 17),
                    Row(children: [
                      Expanded(
                          child: ValuePair('Günlük alım',
                              '${e.dailyEntries} / ${e.settings.maxTradesPerDay}')),
                      Expanded(
                          child: ValuePair('Sermaye üst sınırı',
                              money(e.settings.maxCapital)))
                    ]),
                    const SizedBox(height: 17),
                    FilledButton.icon(
                        onPressed: e.busy
                            ? null
                            : e.running || c.starting
                                ? () => c.stop()
                                : onStart,
                        icon: Icon(e.running || c.starting
                            ? Icons.stop_rounded
                            : Icons.play_arrow_rounded),
                        label: Text(c.starting
                            ? 'Başlatmayı iptal et'
                            : e.running
                                ? 'Botu tamamen durdur'
                                : 'Botu başlat'),
                        style: FilledButton.styleFrom(
                            minimumSize: const Size(double.infinity, 48))),
                    if (e.running || c.starting) ...[
                      const SizedBox(height: 8),
                      Row(children: [
                        Expanded(
                            child: OutlinedButton(
                                onPressed: c.starting
                                    ? null
                                    : () {
                                        if (e.entriesPaused) {
                                          e.resumeEntries();
                                        } else {
                                          e.pauseEntries();
                                        }
                                        unawaited(c.save());
                                      },
                                child: Text(
                                    e.entriesPaused
                                        ? 'Alımlara devam'
                                        : 'Yeni alımları durdur',
                                    style: const TextStyle(fontSize: 11)))),
                        const SizedBox(width: 8),
                        OutlinedButton(
                            onPressed: () => c.stop(emergency: true),
                            style:
                                OutlinedButton.styleFrom(foregroundColor: loss),
                            child: const Text('ACİL DURDUR',
                                style: TextStyle(fontSize: 11)))
                      ])
                    ],
                    const SizedBox(height: 12),
                    Text(
                        c.live
                            ? 'Canlı bot arka plana geçince durur. Pozisyon kendiliğinden satılmaz; stop loss telefon çalışırken izlenir.'
                            : c.backgroundRunner.enabled
                                ? 'Paper bot ekran kilitliyken bildirimle çalışır. Bildirimden durdurabilirsiniz. Android zorla durdurursa otomatik yeniden başlamaz.'
                                : 'Bot uygulama açıkken çalışır; pozisyon kendiliğinden satılmaz.',
                        style: const TextStyle(
                            color: muted, fontSize: 10, height: 1.4)),
                    if (c.backgroundError.isNotEmpty)
                      Text(c.backgroundError,
                          style: const TextStyle(color: loss, fontSize: 11)),
                  ])),
              if (e.position != null)
                PositionCard(position: e.position!, quote: q, metrics: m),
              Row(children: [
                const Text('Son işlemler',
                    style:
                        TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
                const Spacer(),
                Text('${e.events.length} kayıt',
                    style: const TextStyle(color: muted, fontSize: 11))
              ]),
              const SizedBox(height: 12),
              if (e.events.isEmpty)
                const Panel(
                    child: Text(
                        'Henüz işlem yok. Bot uygun giriş koşulunu bekler.',
                        style: TextStyle(color: muted, fontSize: 12)))
              else
                for (final t in e.events.take(3)) TradeTile(trade: t),
            ]));
  }
}

class PositionCard extends StatelessWidget {
  const PositionCard(
      {super.key, required this.position, this.quote, this.metrics});
  final Position position;
  final MarketQuote? quote;
  final PositionMetrics? metrics;
  @override
  Widget build(BuildContext context) => Panel(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Text('Açık pozisyon',
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
          const Spacer(),
          BadgePill(position.symbol.split('_').first, mint)
        ]),
        const SizedBox(height: 17),
        Row(children: [
          Expanded(
              child: ValuePair('Miktar',
                  '${position.quantity.toStringAsFixed(8)} ${position.symbol.split('_').first}')),
          Expanded(
              child: ValuePair('Ortalama alış', money(position.entryPrice)))
        ]),
        const SizedBox(height: 15),
        Row(children: [
          Expanded(
              child: ValuePair('Anlık fiyat',
                  quote == null ? 'Veri bekleniyor' : money(quote!.last))),
          Expanded(
              child: ValuePair('Pozisyon değeri',
                  money(metrics?.value ?? position.notional)))
        ]),
        const SizedBox(height: 15),
        Row(children: [
          Expanded(
              child: ValuePair(
                  'Brüt K/Z', money(metrics?.grossPnl ?? 0, signed: true))),
          Expanded(child: ValuePair('Alış komisyonu', money(position.buyFee)))
        ]),
        const SizedBox(height: 15),
        Row(children: [
          Expanded(
              child: ValuePair(
                  'Tahmini satış komisyonu', money(metrics?.sellFee ?? 0))),
          Expanded(
              child: ValuePair(
                  'Spread + slippage',
                  money((metrics?.spreadCost ?? 0) +
                      (metrics?.slippageCost ?? 0))))
        ]),
        const SizedBox(height: 15),
        ValuePair('Tahmini toplam işlem maliyeti',
            money(metrics?.totalCosts ?? position.buyFee)),
        const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Divider(color: border, height: 1)),
        Row(children: [
          Expanded(
              child: ValuePair(
                  'NET K/Z', money(metrics?.netPnl ?? 0, signed: true),
                  color: pnlColor(metrics?.netPnl ?? 0), large: true)),
          BadgePill(pct(metrics?.netPct ?? 0), pnlColor(metrics?.netPnl ?? 0))
        ]),
      ]));
}

class TradeTile extends StatelessWidget {
  const TradeTile({super.key, required this.trade});
  final TradeEvent trade;
  @override
  Widget build(BuildContext context) => Panel(
      padding: 14,
      child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () => showModalBottomSheet<void>(
              context: context,
              isScrollControlled: true,
              showDragHandle: true,
              builder: (_) => SafeArea(
                  child: SingleChildScrollView(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                                '${trade.side} · ${trade.symbol.replaceAll('_', '/')}',
                                style: const TextStyle(
                                    fontSize: 22, fontWeight: FontWeight.w800)),
                            const SizedBox(height: 20),
                            for (final row in [
                              (
                                'Tarih / saat (TSİ)',
                                DateFormat('dd.MM.yyyy HH:mm:ss').format(trade
                                    .time
                                    .toUtc()
                                    .add(const Duration(hours: 3)))
                              ),
                              ('Fiyat', money(trade.price)),
                              ('Miktar', trade.quantity.toStringAsFixed(8)),
                              ('Komisyon', money(trade.fee)),
                              (
                                'Brüt sonuç',
                                trade.side == 'SAT'
                                    ? money(trade.grossPnl, signed: true)
                                    : 'Alış'
                              ),
                              (
                                'NET K/Z',
                                trade.side == 'SAT'
                                    ? money(trade.pnl, signed: true)
                                    : 'Pozisyon açıldı'
                              ),
                              ('Spread etkisi', money(trade.spreadCost)),
                              ('Slippage etkisi', money(trade.slippageCost)),
                              ('Mod', trade.paper ? 'Paper' : 'Canlı spot'),
                              ('Neden', trade.reason),
                              ('Emir ID', trade.orderId)
                            ])
                              Padding(
                                  padding: const EdgeInsets.only(bottom: 15),
                                  child: Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Expanded(
                                            child: Text(row.$1,
                                                style: const TextStyle(
                                                    color: muted,
                                                    fontSize: 12))),
                                        const SizedBox(width: 12),
                                        Expanded(
                                            child: SelectableText(row.$2,
                                                textAlign: TextAlign.right,
                                                style: const TextStyle(
                                                    fontSize: 12)))
                                      ])),
                          ])))),
          child: Row(children: [
            Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                    color: (trade.side == 'AL' ? mint : loss)
                        .withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(10)),
                child: Icon(
                    trade.side == 'AL' ? Icons.south_west : Icons.north_east,
                    size: 18,
                    color: trade.side == 'AL' ? mint : loss)),
            const SizedBox(width: 10),
            Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Text('${trade.side} · ${trade.symbol.split('_').first}',
                      style: const TextStyle(
                          fontWeight: FontWeight.w700, fontSize: 13)),
                  const SizedBox(height: 4),
                  Text(
                      DateFormat('dd.MM · HH:mm').format(
                          trade.time.toUtc().add(const Duration(hours: 3))),
                      style: const TextStyle(color: muted, fontSize: 10))
                ])),
            Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text(
                  trade.side == 'SAT'
                      ? money(trade.pnl, signed: true)
                      : money(trade.quantity * trade.price),
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: trade.side == 'SAT'
                          ? pnlColor(trade.pnl)
                          : Colors.white)),
              const SizedBox(height: 4),
              Text(trade.paper ? 'PAPER' : 'CANLI',
                  style: const TextStyle(color: muted, fontSize: 9))
            ]),
            const SizedBox(width: 4),
            const Icon(Icons.chevron_right, size: 16, color: muted),
          ])));
}

class TradesPage extends StatefulWidget {
  const TradesPage({super.key, required this.c});
  final AppController c;
  @override
  State<TradesPage> createState() => _TradesPageState();
}

class _TradesPageState extends State<TradesPage> {
  String filter = 'Tümü';
  @override
  Widget build(BuildContext context) {
    final all = widget.c.engine.events;
    final list = all
        .where((t) => switch (filter) {
              'AL' => t.side == 'AL',
              'SAT' => t.side == 'SAT',
              'Kârlı' => t.side == 'SAT' && t.pnl > 0,
              'Zararlı' => t.side == 'SAT' && t.pnl < 0,
              _ => true
            })
        .toList();
    return ListView(padding: const EdgeInsets.all(20), children: [
      const Text('İşlem geçmişi',
          style: TextStyle(fontSize: 27, fontWeight: FontWeight.w800)),
      const SizedBox(height: 8),
      const Text('Her emir, her maliyet, net sonuç.',
          style: TextStyle(color: muted, fontSize: 12)),
      const SizedBox(height: 20),
      Panel(
          child: Row(children: [
        Expanded(
            child: ValuePair('Gerçekleşen K/Z',
                money(widget.c.engine.realizedPnl, signed: true),
                color: pnlColor(widget.c.engine.realizedPnl))),
        ValuePair('Toplam emir', '${all.length}')
      ])),
      SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(children: [
            for (final f in ['Tümü', 'AL', 'SAT', 'Kârlı', 'Zararlı'])
              Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: ChoiceChip(
                      label: Text(f),
                      selected: filter == f,
                      showCheckmark: false,
                      onSelected: (_) => setState(() => filter = f)))
          ])),
      const SizedBox(height: 18),
      if (list.isEmpty)
        const Panel(
            child: Column(children: [
          Icon(Icons.receipt_long_outlined, size: 35, color: muted),
          SizedBox(height: 14),
          Text('Bu filtrede işlem bulunmuyor.', style: TextStyle(color: muted))
        ]))
      else
        for (final t in list) TradeTile(trade: t),
    ]);
  }
}

Future<bool> confirm(BuildContext context, String title, String body,
        {bool danger = false}) async =>
    await showDialog<bool>(
        context: context,
        builder: (context) =>
            AlertDialog(title: Text(title), content: Text(body), actions: [
              TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Vazgeç')),
              FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  style: danger
                      ? FilledButton.styleFrom(
                          backgroundColor: loss, foregroundColor: background)
                      : null,
                  child: const Text('Onaylıyorum'))
            ])) ??
    false;

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.c, required this.onMessage});
  final AppController c;
  final void Function(String?) onMessage;
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final Map<String, TextEditingController> fields = {};
  final formKey = GlobalKey<FormState>();
  String symbol = '';
  StrategySettings? loadedSettings;
  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant SettingsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(loadedSettings, widget.c.engine.settings)) _load();
  }

  void _load() {
    for (final f in fields.values) {
      f.dispose();
    }
    fields.clear();
    loadedSettings = widget.c.engine.settings;
    final j = widget.c.engine.settings.toJson();
    symbol = j['symbol'] as String;
    for (final entry in j.entries) {
      if (entry.value is num) {
        fields[entry.key] = TextEditingController(text: '${entry.value}');
      }
    }
  }

  @override
  void dispose() {
    for (final f in fields.values) {
      f.dispose();
    }
    super.dispose();
  }

  Widget field(String key, String label, {String? suffix, String? hint}) =>
      Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: TextFormField(
              controller: fields[key],
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                  labelText: label,
                  suffixText: suffix,
                  helperText: hint,
                  helperMaxLines: 2),
              validator: (v) {
                final n = double.tryParse((v ?? '').replaceAll(',', '.'));
                return n == null || !n.isFinite || n < 0
                    ? 'Geçerli bir değer girin.'
                    : null;
              }));
  Future<void> save() async {
    if (!formKey.currentState!.validate()) return;
    final j = widget.c.engine.settings.toJson()..['symbol'] = symbol;
    for (final f in fields.entries) {
      j[f.key] = double.parse(f.value.text.replaceAll(',', '.'));
    }
    final settings = StrategySettings.fromJson(j);
    final error = settings.validate();
    if (error != null) {
      widget.onMessage(error);
      return;
    }
    if (!await confirm(context, 'Strateji ayarlarını kaydet',
        'Yeni risk limitleri ve işlem maliyetleri uygulanacak. Maksimum sermaye: ${money(settings.maxCapital)}; stop loss: ${settings.stopLossPct}%.')) {
      return;
    }
    final result = await widget.c.applySettings(settings);
    widget.onMessage(result ?? 'Ayarlar kaydedildi.');
  }

  Future<void> mode(bool live) async {
    if (!live) {
      widget.onMessage(await widget.c.activatePaper());
      return;
    }
    var checked = false, permissionsChecked = false;
    final approved = await showDialog<bool>(
        context: context,
        builder: (context) => StatefulBuilder(
            builder: (context, update) => AlertDialog(
                    title: const Row(children: [
                      Icon(Icons.warning_amber_rounded, color: loss),
                      SizedBox(width: 10),
                      Expanded(child: Text('Gerçek spot işlem'))
                    ]),
                    content: SingleChildScrollView(
                        child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                          const Text(
                              'Canlı mod, Binance TR hesabındaki gerçek bakiyeyle AL/SAT emirleri gönderebilir. Kayıp yaşayabilirsiniz.'),
                          const SizedBox(height: 14),
                          Text(
                              'Sermaye üst sınırı: ${money(widget.c.engine.settings.maxCapital)}\nİşlem başına üst sınır: ${money(widget.c.engine.settings.maxPosition)}\nGünlük zarar sınırı: ${money(widget.c.engine.settings.dailyLossLimit)}\nGünlük en fazla ${widget.c.engine.settings.maxTradesPerDay} alım'),
                          const SizedBox(height: 14),
                          const Text(
                              'Önce HTTPS backend kurulmalı; API anahtarı yalnızca sunucuda ve spot işlem yetkili olmalı. Para çekme yetkisi kapalı olmalı.',
                              style: TextStyle(fontSize: 12, color: muted)),
                          const SizedBox(height: 12),
                          const Text(
                              'Canlı bot telefon açık ve uygulama ön plandayken çalışır. Ekran kilitlenince bot durur; açık pozisyon borsada kalır ve telefonun stop loss kontrolü çalışmaz.',
                              style: TextStyle(fontSize: 12, color: loss)),
                          const SizedBox(height: 12),
                          Text(
                              widget.c.backendCheck?.liveProblem(
                                      widget.c.engine.settings,
                                      DateTime.now()) ??
                                  (widget.c.backendCheck == null
                                      ? 'Önce Binance TR hesabını emir göndermeden doğrulayın.'
                                      : 'Hesap ve sunucu limitleri doğrulandı. Canlı mod tek başına botu başlatmaz.'),
                              style:
                                  const TextStyle(fontSize: 12, color: muted)),
                          CheckboxListTile(
                              contentPadding: EdgeInsets.zero,
                              value: permissionsChecked,
                              onChanged: (v) =>
                                  update(() => permissionsChecked = v ?? false),
                              title: const Text(
                                  'Anahtarı Binance TR panelinde kontrol ettim: yalnızca okuma/spot, para çekme kapalı ve sunucu IP kısıtlaması açık.',
                                  style: TextStyle(fontSize: 12))),
                          CheckboxListTile(
                              contentPadding: EdgeInsets.zero,
                              value: checked,
                              onChanged: (v) =>
                                  update(() => checked = v ?? false),
                              title: const Text(
                                  'Gerçek emir ve riskleri onaylıyorum.',
                                  style: TextStyle(fontSize: 12))),
                        ])),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: const Text('Vazgeç')),
                      FilledButton(
                          onPressed: checked &&
                                  permissionsChecked &&
                                  widget.c.backendCheck != null &&
                                  widget.c.backendCheck!.liveProblem(
                                          widget.c.engine.settings,
                                          DateTime.now()) ==
                                      null
                              ? () => Navigator.pop(context, true)
                              : null,
                          style: FilledButton.styleFrom(
                              backgroundColor: loss,
                              foregroundColor: background),
                          child: const Text('Canlı modu aç'))
                    ])));
    if (approved == true) {
      widget.onMessage(await widget.c.activateLive());
    }
  }

  Future<void> backend() async {
    final url = TextEditingController(text: widget.c.backendUrl),
        token = TextEditingController();
    String? error;
    var loading = false;
    await showDialog<void>(
        context: context,
        builder: (context) => StatefulBuilder(
            builder: (context, update) => AlertDialog(
                    title: const Text('Güvenli backend bağlantısı'),
                    content: SingleChildScrollView(
                        child:
                            Column(mainAxisSize: MainAxisSize.min, children: [
                      const Text(
                          'Binance API Secret telefona girilmez. Buraya kendi sunucunuzun adresini ve yalnızca bot erişim anahtarını girin.',
                          style: TextStyle(color: muted, fontSize: 12)),
                      const SizedBox(height: 16),
                      TextField(
                          controller: url,
                          decoration: const InputDecoration(
                              labelText: 'HTTPS sunucu adresi',
                              hintText: 'https://bot.sunucunuz.com')),
                      const SizedBox(height: 12),
                      TextField(
                          controller: token,
                          obscureText: true,
                          autocorrect: false,
                          enableSuggestions: false,
                          decoration: const InputDecoration(
                              labelText: 'Backend erişim anahtarı')),
                      if (error != null)
                        Padding(
                            padding: const EdgeInsets.only(top: 12),
                            child: Text(error!,
                                style: const TextStyle(
                                    color: loss, fontSize: 12))),
                    ])),
                    actions: [
                      TextButton(
                          onPressed:
                              loading ? null : () => Navigator.pop(context),
                          child: const Text('Kapat')),
                      FilledButton(
                          onPressed: loading
                              ? null
                              : () async {
                                  update(() => loading = true);
                                  final result = await widget.c
                                      .configureBackend(url.text, token.text);
                                  if (!context.mounted) return;
                                  if (result == null) {
                                    Navigator.pop(context);
                                    widget.onMessage(
                                        'Sunucu doğrulandı. Şimdi hesabı emir göndermeden kontrol edin.');
                                  } else {
                                    update(() {
                                      loading = false;
                                      error = result;
                                    });
                                  }
                                },
                          child: Text(
                              loading ? 'Bağlanıyor…' : 'Bağlantıyı doğrula'))
                    ])));
    url.dispose();
    token.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final symbols = {
      ...widget.c.symbolNames,
      widget.c.engine.settings.symbol,
      symbol
    }.where((s) => s.isNotEmpty).toList()
      ..sort();
    return Form(
        key: formKey,
        child: ListView(padding: const EdgeInsets.all(20), children: [
          const Text('Bot ayarları',
              style: TextStyle(fontSize: 27, fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          const Text('Stratejinizi ve sermaye sınırınızı belirleyin.',
              style: TextStyle(color: muted, fontSize: 12)),
          const SizedBox(height: 20),
          Panel(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                const Text('Çalışma modu',
                    style:
                        TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
                const SizedBox(height: 14),
                SegmentedButton<bool>(segments: const [
                  ButtonSegment(
                      value: false,
                      label: Text('Paper'),
                      icon: Icon(Icons.science_outlined)),
                  ButtonSegment(
                      value: true, label: Text('Canlı'), icon: Icon(Icons.bolt))
                ], selected: {
                  widget.c.live
                }, onSelectionChanged: (s) => mode(s.first)),
                const SizedBox(height: 12),
                Text(
                    widget.c.live
                        ? 'Gerçek spot hesap · Emirler güvenli backend ile gönderilir.'
                        : 'Gerçek piyasa · Sanal bakiye · Gerçekçi işlem maliyetleri',
                    style: const TextStyle(color: muted, fontSize: 11)),
              ])),
          Panel(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                const Text('Binance TR hesap bağlantısı',
                    style:
                        TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
                const SizedBox(height: 10),
                const Text(
                    'API anahtarı ve Secret yalnızca güvenli sunucuda saklanır. İlk kontrol bakiyeyi okur; AL/SAT veya iptal emri göndermez.',
                    style: TextStyle(color: muted, fontSize: 12, height: 1.5)),
                const SizedBox(height: 14),
                OutlinedButton.icon(
                    onPressed: widget.c.checkingBackend ? null : backend,
                    icon: const Icon(Icons.shield_outlined),
                    label: Text(widget.c.backendUrl.isEmpty
                        ? 'Güvenli sunucuyu bağla'
                        : 'Sunucu bağlantısını düzenle')),
                const SizedBox(height: 10),
                FilledButton.icon(
                    key: const ValueKey('verify-live-account'),
                    onPressed: widget.c.checkingBackend ||
                            widget.c.starting ||
                            widget.c.engine.running
                        ? null
                        : () async {
                            final result = await widget.c.verifyLiveAccount();
                            widget.onMessage(result ??
                                'Hesap doğrulandı. Gerçek emir gönderilmedi.');
                          },
                    icon: const Icon(Icons.fact_check_outlined),
                    label: Text(widget.c.checkingBackend
                        ? 'Hesap kontrol ediliyor…'
                        : 'Hesabı doğrula · Emir göndermez')),
                if (widget.c.backendCheckError.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text(widget.c.backendCheckError,
                      style: const TextStyle(color: loss, fontSize: 12)),
                ],
                if (widget.c.backendCheck != null) ...[
                  const SizedBox(height: 16),
                  Text(
                      widget.c.backendCheck!.isFresh(DateTime.now())
                          ? 'Hesap doğrulandı · Salt okuma'
                          : 'Hesap kontrolü eskidi · Yenileyin',
                      style: const TextStyle(
                          color: mint, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 8),
                  Text(
                      '${widget.c.backendCheck!.symbol.replaceAll('_', '/')} · Kullanılabilir: ${money(widget.c.backendCheck!.availableTry)}\n'
                      'TRY komisyonu: ${widget.c.backendCheck!.feePct.toStringAsFixed(3)}% · Spread: ${widget.c.backendCheck!.spreadPct.toStringAsFixed(3)}%\n'
                      'Açık emir: ${widget.c.backendCheck!.reconciliation['openOrderCount']} · Belirsiz bot emri: ${widget.c.backendCheck!.reconciliation['unresolvedIntentCount']}\n'
                      'Sunucu sermaye sınırı: ${money(number(widget.c.backendCheck!.limits['maxCapital']))}\n'
                      'Son kontrol: ${DateFormat('HH:mm:ss').format(widget.c.backendCheck!.verifiedAt.toLocal())}',
                      style: const TextStyle(
                          color: muted, fontSize: 12, height: 1.7)),
                  const SizedBox(height: 10),
                  Text(
                      widget.c.backendCheck!.liveEnabled
                          ? 'Sunucu gerçek emirlere izin verebilir. Bot ve canlı mod ayrıca başlatılır.'
                          : 'Gerçek emirler sunucuda kapalı. Hesabı bağlamak botu başlatmaz.',
                      style: TextStyle(
                          color:
                              widget.c.backendCheck!.liveEnabled ? loss : mint,
                          fontSize: 12)),
                  if (!widget.c.backendCheck!.safe)
                    const Text(
                        'Açık/belirsiz emir veya bakiye uyuşmazlığı nedeniyle canlı başlangıç engellenir.',
                        style: TextStyle(color: loss, fontSize: 12)),
                  const SizedBox(height: 8),
                  const Text(
                      'Anahtar yetkileri bu kontrolle kanıtlanamaz; Binance TR panelinden doğrulayın.',
                      style: TextStyle(color: muted, fontSize: 11)),
                ],
              ])),
          Panel(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                const Text('Piyasa ve sermaye',
                    style:
                        TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
                const SizedBox(height: 18),
                DropdownButtonFormField<String>(
                    initialValue: symbol,
                    decoration: const InputDecoration(labelText: 'İşlem çifti'),
                    items: symbols
                        .map((s) => DropdownMenuItem(
                            value: s, child: Text(s.replaceAll('_', '/'))))
                        .toList(),
                    onChanged: (s) => setState(() => symbol = s!)),
                const SizedBox(height: 14),
                field('startingBalance', 'Başlangıç sanal bakiyesi',
                    suffix: 'TL',
                    hint: 'Yeni paper hesapta veya sıfırlamada uygulanır.'),
                field('capitalPct', 'İşlem başına bakiye', suffix: '%'),
                field('maxCapital', 'Maksimum toplam sermaye', suffix: 'TL'),
                field('maxPosition', 'Maksimum pozisyon', suffix: 'TL'),
              ])),
          Panel(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                const Text('Strateji ve risk',
                    style:
                        TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
                const SizedBox(height: 18),
                field('minNetProfitPct', 'Minimum net kâr', suffix: '%'),
                field('stopLossPct', 'Stop loss', suffix: '%'),
                field('entryDropPct', 'İlk giriş geri çekilmesi', suffix: '%'),
                field('reentryDropPct', 'Yeniden giriş düşüşü', suffix: '%'),
                field('reboundPct', 'Yükseliş teyidi', suffix: '%'),
                field('flatRangePct', 'Konsolidasyon fiyat aralığı',
                    suffix: '%'),
                field('dailyLossLimit', 'Günlük maksimum zarar',
                    suffix: 'TL',
                    hint:
                        'Açık pozisyonun net zararı dahil. TSİ günü kullanılır.'),
                field('maxTradesPerDay', 'Günlük maksimum alım sayısı',
                    hint: 'Risk nedeniyle gerekli satışlar engellenmez.'),
                field('windowSize', 'Teyit örnek sayısı'),
                field('observationSeconds', 'Minimum gözlem', suffix: 'sn'),
                field('cooldownSeconds', 'Satış sonrası bekleme', suffix: 'sn'),
              ])),
          Panel(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                const Text('İşlem maliyetleri',
                    style:
                        TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
                const SizedBox(height: 18),
                field('feePct', 'Komisyon (her yön)',
                    suffix: '%',
                    hint:
                        'Paper varsayımıdır. Canlı satış tahmini sunucu üst sınırını kullanır; gerçek komisyon kayda alınır.'),
                field('slippagePct', 'Slippage varsayımı', suffix: '%'),
                field('maxSpreadPct', 'Maksimum spread', suffix: '%'),
              ])),
          FilledButton.icon(
              onPressed: save,
              icon: const Icon(Icons.check_rounded),
              label: const Text('Ayarları kaydet')),
          const SizedBox(height: 18),
          TextButton(
              onPressed: () async {
                if (!await confirm(context, 'Paper hesabı sıfırla',
                    'Sanal bakiye, işlem geçmişi ve gerçekleşen K/Z silinir. Bu işlem geri alınamaz.',
                    danger: true)) {
                  return;
                }
                widget.onMessage(
                    await widget.c.resetPaper() ?? 'Paper hesabı sıfırlandı.');
              },
              child: const Text('Paper hesabını sıfırla',
                  style: TextStyle(color: loss))),
          const SizedBox(height: 12),
          const Text(
              'CryptoLoop TR 1.1.1 · Spot\nCanlı mod her açılışta kullanıcı onayı gerektirir.',
              textAlign: TextAlign.center,
              style: TextStyle(color: muted, fontSize: 10, height: 1.6)),
        ]));
  }
}
