import 'dart:convert';
import 'package:cryptoloop_tr/live_execution.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Map<String, dynamic> preflightJson(
        {bool liveEnabled = false, DateTime? time}) =>
    {
      'readOnly': true,
      'symbol': 'BTC_TRY',
      'verifiedAt': (time ?? DateTime.now()).toUtc().toIso8601String(),
      'liveEnabled': liveEnabled,
      'armed': false,
      'market': {'bid': '100', 'ask': '100.1', 'spreadPct': '0.1'},
      'account': {'availableTry': '1000', 'feePct': '0.15', 'canTrade': true},
      'reconciliation': {
        'safe': true,
        'riskLocked': false,
        'openOrderCount': 0,
        'unresolvedIntentCount': 0,
        'historyCount': 0,
        'tradeCount': 0,
        'position': null
      },
      'serverLimits': {
        'maxCapital': '10000',
        'maxPosition': '2000',
        'dailyLossLimit': '300',
        'maxTradesPerDay': 20
      },
      'keyPermissionsVerified': false,
      'withdrawalPermissionVerified': false
    };

BackendClient readOnlyBackend(List<http.Request> requests,
        {bool liveEnabled = false}) =>
    BackendClient(
        baseUrl: 'https://test.example.invalid',
        token: 'test-only-control-token-with-32-characters',
        client: MockClient((request) async {
          requests.add(request);
          if (request.method != 'GET') {
            throw StateError('Unexpected exchange mutation');
          }
          final symbols = (request.url.queryParameters['symbols'] ??
                  request.url.queryParameters['symbol'] ??
                  'BTC_TRY')
              .split(',');
          if (request.url.path == '/v1/preflight') {
            return http.Response(
                jsonEncode(symbols.length == 1
                    ? (preflightJson(liveEnabled: liveEnabled)
                      ..['symbol'] = symbols.single)
                    : portfolioPreflightJson(symbols,
                        liveEnabled: liveEnabled)),
                200);
          }
          if (request.url.path == '/v1/reconcile') {
            return http.Response(
                jsonEncode({
                  if (symbols.length > 1)
                    'coins': {
                      for (final s in symbols)
                        s: {
                          'position': null,
                          'lastSellPrice': '0',
                          'lastSellTime': null
                        }
                    },
                  'safe': true,
                  'availableTry': '1000',
                  'realizedPnl': '0',
                  'dailyPnl': '0',
                  'dailyEntries': 0,
                  'riskLocked': false,
                  'events': [],
                  'lastSellPrice': '0',
                  'lastSellTime': null,
                  'position': null,
                  'feePct': '1'
                }),
                200);
          }
          throw StateError('Unexpected backend route');
        }));

Map<String, dynamic> portfolioPreflightJson(List<String> symbols,
        {bool liveEnabled = false, DateTime? time}) =>
    {
      'readOnly': true,
      'symbols': symbols,
      'checks': [
        for (final s in symbols)
          preflightJson(liveEnabled: liveEnabled, time: time)..['symbol'] = s
      ]
    };
