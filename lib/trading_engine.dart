enum BotState { waitingEntry, holding, waitingReentry }

class TradeEvent { final String side; final double price, quantity, pnl; final DateTime time; const TradeEvent(this.side,this.price,this.quantity,this.pnl,this.time); }

class TradingEngine {
 TradingEngine({this.startingTry=10000,this.feeRate=0.001,this.minNetProfitPct=0.20,this.reentryDropPct=0.15,this.stopLossPct=2.0}):cashTry=startingTry;
 final double startingTry,feeRate,minNetProfitPct,reentryDropPct,stopLossPct;
 double cashTry,coin=0,entryPrice=0,lastSellPrice=0,realizedPnl=0; BotState state=BotState.waitingEntry; final List<TradeEvent> events=[];
 void onPrice(double price){ if(price<=0)return; if(state==BotState.waitingEntry){_buy(price);return;} if(state==BotState.holding){final gross=coin*price;final net=gross-(gross*feeRate);final cost=coin*entryPrice;final pct=((net-cost)/cost)*100;if(pct>=minNetProfitPct||pct<=-stopLossPct)_sell(price);return;} final trigger=lastSellPrice*(1-reentryDropPct/100);if(price<=trigger)_buy(price); }
 void _buy(double price){if(cashTry<=0)return;final fee=cashTry*feeRate;coin=(cashTry-fee)/price;cashTry=0;entryPrice=price;state=BotState.holding;events.insert(0,TradeEvent("AL",price,coin,0,DateTime.now()));}
 void _sell(double price){final gross=coin*price;final net=gross-(gross*feeRate);final basis=coin*entryPrice;final pnl=net-basis;cashTry=net;realizedPnl+=pnl;events.insert(0,TradeEvent("SAT",price,coin,pnl,DateTime.now()));coin=0;lastSellPrice=price;entryPrice=0;state=BotState.waitingReentry;}
}
