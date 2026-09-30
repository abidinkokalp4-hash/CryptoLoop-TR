import 'dart:async';
import 'dart:convert';
import 'package:stream_channel/stream_channel.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

class FakeSink implements WebSocketSink {
  final messages = <dynamic>[];
  final _done = Completer<void>();
  @override
  void add(dynamic data) => messages.add(data);
  @override
  void addError(Object error, [StackTrace? stackTrace]) {}
  @override
  Future<void> addStream(Stream<dynamic> stream) async {
    await for (final item in stream) {
      add(item);
    }
  }

  @override
  Future<void> close([int? closeCode, String? closeReason]) async {
    if (!_done.isCompleted) _done.complete();
  }

  @override
  Future<void> get done => _done.future;
}

class FakeSocket extends StreamChannelMixin<dynamic>
    implements WebSocketChannel {
  final frames = StreamController<dynamic>();
  @override
  final FakeSink sink = FakeSink();
  @override
  Stream<dynamic> get stream => frames.stream;
  @override
  Future<void> get ready async {}
  @override
  String? get protocol => null;
  @override
  int? get closeCode => null;
  @override
  String? get closeReason => null;
  void send(String symbol, Map<String, dynamic> data, String type) =>
      frames.add(jsonEncode(
          {'stream': '${symbol.toLowerCase()}@$type', 'data': data}));
}
