import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';
class BinanceTrMarket { WebSocketChannel? _channel; Stream<double> prices(String symbol){final s=symbol.replaceAll('_','').toLowerCase();_channel=WebSocketChannel.connect(Uri.parse('wss://stream-cloud.binance.tr/ws/'+s+'@trade'));return _channel!.stream.map((event){final data=jsonDecode(event as String) as Map<String,dynamic>;return double.parse(data['p'].toString());});} Future<void> close() async=>_channel?.sink.close(); }
