import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart' show DateFormat, NumberFormat;
import 'models.dart';

const mint = Color(0xFF45E6B0);
const loss = Color(0xFFFF6B82);
const muted = Color(0xFF93A3BA);

class PriceChart extends StatefulWidget {
  const PriceChart({super.key, required this.candles, required this.trades});
  final List<Candle> candles;
  final List<TradeEvent> trades;
  @override
  State<PriceChart> createState() => _PriceChartState();
}

class _PriceChartState extends State<PriceChart> {
  int? selected;
  int visible = 55;
  @override
  Widget build(BuildContext context) {
    final data = widget.candles
        .skip(math.max(0, widget.candles.length - visible))
        .toList();
    if (data.isEmpty) {
      return const SizedBox(
          height: 215,
          child: Center(
              child: Text('Mum verisi bekleniyor',
                  style: TextStyle(color: muted))));
    }
    final index = selected?.clamp(0, data.length - 1);
    final c = index == null ? data.last : data[index];
    return Column(children: [
      Row(children: [
        Expanded(
            child: Text(
                '${DateFormat('dd.MM HH:mm').format(c.time.toUtc().add(const Duration(hours: 3)))}  ·  ${NumberFormat('#,##0.00', 'tr_TR').format(c.close)} TL',
                style: const TextStyle(color: muted, fontSize: 11))),
        IconButton(
            tooltip: 'Grafiği yakınlaştır',
            visualDensity: VisualDensity.compact,
            onPressed: () =>
                setState(() => visible = math.max(20, visible - 15)),
            icon: const Icon(Icons.zoom_in, size: 18)),
        IconButton(
            tooltip: 'Grafiği uzaklaştır',
            visualDensity: VisualDensity.compact,
            onPressed: () =>
                setState(() => visible = math.min(150, visible + 15)),
            icon: const Icon(Icons.zoom_out, size: 18)),
      ]),
      LayoutBuilder(
          builder: (_, box) => GestureDetector(
                onTapDown: (d) => setState(() => selected =
                    ((d.localPosition.dx - 4) /
                            (box.maxWidth - 72) *
                            data.length)
                        .floor()
                        .clamp(0, data.length - 1)),
                onHorizontalDragUpdate: (d) => setState(() => selected =
                    ((d.localPosition.dx - 4) /
                            (box.maxWidth - 72) *
                            data.length)
                        .floor()
                        .clamp(0, data.length - 1)),
                child: SizedBox(
                    height: 220,
                    width: double.infinity,
                    child: CustomPaint(
                        painter: CandlePainter(data, widget.trades, index))),
              )),
      const Row(children: [
        Icon(Icons.arrow_drop_up, color: mint, size: 17),
        Text('AL', style: TextStyle(fontSize: 10, color: muted)),
        SizedBox(width: 12),
        Icon(Icons.arrow_drop_down, color: loss, size: 17),
        Text('SAT', style: TextStyle(fontSize: 10, color: muted)),
        SizedBox(width: 10),
        Expanded(
            child: Text('İncelemek için dokunun',
                textAlign: TextAlign.right,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 10, color: muted)))
      ]),
    ]);
  }
}

class CandlePainter extends CustomPainter {
  CandlePainter(this.data, this.trades, this.selected);
  final List<Candle> data;
  final List<TradeEvent> trades;
  final int? selected;
  void label(Canvas canvas, String text, Offset pos,
      {Color color = muted, double size = 9}) {
    final p = TextPainter(
        text: TextSpan(
            text: text,
            style:
                TextStyle(color: color, fontSize: size, fontFamily: 'Roboto')),
        textDirection: TextDirection.ltr)
      ..layout();
    p.paint(canvas, pos);
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (data.isEmpty) return;
    final w = size.width - 72, h = size.height - 43, step = w / data.length;
    var lo = data.map((c) => c.low).reduce(math.min),
        hi = data.map((c) => c.high).reduce(math.max);
    final padding = math.max((hi - lo) * 0.12, hi * 0.0001);
    lo -= padding;
    hi += padding;
    double y(double p) => 8 + (hi - p) / (hi - lo) * (h - 16);
    final grid = Paint()
      ..color = const Color(0xFF263449)
      ..strokeWidth = 0.6;
    for (var i = 0; i <= 4; i++) {
      final yy = 8 + i * (h - 16) / 4;
      canvas.drawLine(Offset(0, yy), Offset(w, yy), grid);
      label(
          canvas,
          NumberFormat.compact(locale: 'tr_TR').format(hi - i * (hi - lo) / 4),
          Offset(w + 7, yy - 5));
    }
    final maxVolume = math.max(1.0, data.map((c) => c.volume).reduce(math.max));
    for (var i = 0; i < data.length; i++) {
      final c = data[i], x = step * (i + 0.5);
      final color = c.close >= c.open ? mint : loss;
      final p = Paint()
        ..color = color
        ..strokeWidth = 1.2;
      canvas.drawLine(Offset(x, y(c.high)), Offset(x, y(c.low)), p);
      canvas.drawRect(
          Rect.fromLTRB(
              x - math.max(1, step * 0.31),
              math.min(y(c.open), y(c.close)),
              x + math.max(1, step * 0.31),
              math.max(y(c.open), y(c.close)) + 1),
          p);
      canvas.drawRect(
          Rect.fromLTRB(x - step * 0.3, h + 23 - c.volume / maxVolume * 20,
              x + step * 0.3, h + 23),
          Paint()..color = color.withValues(alpha: 0.22));
    }
    for (final t in trades) {
      if (t.time.isBefore(data.first.time)) continue;
      var i = data.lastIndexWhere((c) => !c.time.isAfter(t.time));
      if (i < 0) continue;
      final lastInterval = data.length > 1
          ? data.last.time.difference(data[data.length - 2].time)
          : const Duration(minutes: 1);
      if (t.time.isAfter(data.last.time.add(lastInterval))) continue;
      final x = (i + 0.5) * step, yy = y(t.price).clamp(12.0, h - 12);
      final buy = t.side == 'AL', color = buy ? mint : loss;
      final path = Path()
        ..moveTo(x, yy)
        ..lineTo(x - 5, yy + (buy ? 9 : -9))
        ..lineTo(x + 5, yy + (buy ? 9 : -9))
        ..close();
      canvas.drawPath(path, Paint()..color = color);
      label(canvas, t.side, Offset(x - 7, yy + (buy ? 10 : -23)), color: color);
    }
    final latest = data.last.close, yy = y(latest);
    canvas.drawLine(
        Offset(0, yy),
        Offset(w, yy),
        Paint()
          ..color = mint.withValues(alpha: 0.25)
          ..strokeWidth = 0.7);
    label(canvas, NumberFormat.compact(locale: 'tr_TR').format(latest),
        Offset(w + 7, yy - 5),
        color: mint);
    if (selected != null) {
      final x = (selected! + 0.5) * step;
      canvas.drawLine(
          Offset(x, 0),
          Offset(x, h + 25),
          Paint()
            ..color = Colors.white38
            ..strokeWidth = 0.8);
      canvas.drawCircle(Offset(x, y(data[selected!].close)), 3,
          Paint()..color = Colors.white);
    }
    for (final i in [0, data.length ~/ 2, data.length - 1]) {
      final text = DateFormat('HH:mm')
          .format(data[i].time.toUtc().add(const Duration(hours: 3)));
      label(canvas, text, Offset((step * i).clamp(0.0, w - 28), h + 29));
    }
  }

  @override
  bool shouldRepaint(covariant CandlePainter oldDelegate) => true;
}
