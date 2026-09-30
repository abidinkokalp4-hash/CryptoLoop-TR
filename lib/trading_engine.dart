import 'dart:collection';

enum BotState { waitingEntry, holding, waitingReentry }
class TradeEvent { final String side; final double price,quantity,pnl; final DateTime time; const TradeEvent(this.side,this.price,this.quantity,this.pnl,this.time); }

class TradingEngine {
 TradingEngine({this.startingTry=10000,this.feeRate=0.001,this.minNetProfitPct=0.20,this.reentryDropPct=0.15,this.stopLossPct=2.0,this.flatWindow=30,this.flatRangePct=0.20}):cashTry=startingTry;
 final double startingTry,feeRate,minNetProfitPct,reentryDropPct,stopLossPct,flatRangePct; final int flatWindow;
 double cashTry,coin=0,entryPrice=0,lastSellPrice=0,realizedPnl=0,lastPrice=0; BotState state=BotState.waitingEntry;
 final List<TradeEvent> events=[]; final Queue<double> _window=Queue<double>();
 double get markValue=>cashTry+coin*lastPrice;
 void onPrice(double p){if(p<=0)return;lastPrice=p;_window.addLast(p);while(_window.length>flatWindow)_window.removeFirst();
  if(state==BotState.waitingEntry){_buy(p);return;}
  if(state==BotState.holding){final gross=coin*p,net=gross-gross*feeRate,cost=coin*entryPrice,pct=((net-cost)/cost)*100;if(pct>=minNetProfitPct||pct<=-stopLossPct)_sell(p);return;}
  final drop=p<=lastSellPrice*(1-reentryDropPct/100); if(drop||_flatAndRecovering(p))_buy(p);
 }
 bool _flatAndRecovering(double p){if(_window.length<flatWindow)return false;final lo=_window.reduce((a,b)=>a<b?a:b),hi=_window.reduce((a,b)=>a>b?a:b);if(lo<=0)return false;final range=(hi-lo)/lo*100;final list=_window.toList();return range<=flatRangePct&&p>list[list.length-2]&&p<=lastSellPrice*1.01;}
 void _buy(double p){if(cashTry<=0)return;final fee=cashTry*feeRate;coin=(cashTry-fee)/p;cashTry=0;entryPrice=p;state=BotState.holding;events.insert(0,TradeEvent('AL',p,coin,0,DateTime.now()));}
 void _sell(double p){final gross=coin*p,net=gross-gross*feeRate,basis=coin*entryPrice,pnl=net-basis;cashTry=net;realizedPnl+=pnl;events.insert(0,TradeEvent('SAT',p,coin,pnl,DateTime.now()));coin=0;lastSellPrice=p;entryPrice=0;_window.clear();state=BotState.waitingReentry;}
}
