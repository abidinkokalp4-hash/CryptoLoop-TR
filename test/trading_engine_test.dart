import 'package:flutter_test/flutter_test.dart';
import 'package:cryptoloop_tr/trading_engine.dart';
void main(){test('paper cycle sells profit and waits reentry',(){final e=TradingEngine(feeRate:0,minNetProfitPct:0.2,reentryDropPct:0.15);e.onPrice(100);expect(e.state,BotState.holding);e.onPrice(100.3);expect(e.state,BotState.waitingReentry);e.onPrice(100.0);expect(e.state,BotState.holding);});}
