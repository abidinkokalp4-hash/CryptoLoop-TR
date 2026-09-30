import 'models.dart';

abstract interface class ExecutionAdapter {
  bool get isPaper;
  Future<Fill> buy(
      {required MarketQuote quote,
      required SymbolRules rules,
      required StrategySettings settings,
      required double budget,
      required String intentId});
  Future<Fill> sell(
      {required MarketQuote quote,
      required SymbolRules rules,
      required StrategySettings settings,
      required Position position,
      required String intentId,
      bool stopLoss = false});
  Future<void> halt();
}

class ExecutionException implements Exception {
  const ExecutionException(this.message, {this.uncertain = false});
  final String message;
  final bool uncertain;
  @override
  String toString() => message;
}

class PaperExecution implements ExecutionAdapter {
  @override
  bool get isPaper => true;
  @override
  Future<void> halt() async {}
  @override
  Future<Fill> buy(
      {required MarketQuote quote,
      required SymbolRules rules,
      required StrategySettings settings,
      required double budget,
      required String intentId}) async {
    final price = quote.ask * (1 + settings.slippageRate);
    final qty = rules.floorQuantity(budget / (price * (1 + settings.feeRate)));
    final problem = rules.validateOrder(qty, price);
    if (problem != null) throw ExecutionException(problem);
    if (qty > quote.askQty) {
      throw const ExecutionException(
          'İlk satış kademesinde yeterli likidite yok.');
    }
    final notional = qty * price;
    return Fill(
        orderId: 'P-$intentId',
        quantity: qty,
        price: price,
        notional: notional,
        fee: notional * settings.feeRate,
        time: quote.time,
        spreadCost: qty * (quote.ask - quote.mid),
        slippageCost: qty * (price - quote.ask));
  }

  @override
  Future<Fill> sell(
      {required MarketQuote quote,
      required SymbolRules rules,
      required StrategySettings settings,
      required Position position,
      required String intentId,
      bool stopLoss = false}) async {
    final price = quote.bid * (1 - settings.slippageRate);
    final qty = rules.floorQuantity(position.quantity);
    final problem = rules.validateOrder(qty, price);
    if (problem != null) throw ExecutionException(problem);
    if (qty > quote.bidQty) {
      throw const ExecutionException(
          'İlk alış kademesinde yeterli likidite yok.');
    }
    final notional = qty * price;
    return Fill(
        orderId: 'P-$intentId',
        quantity: qty,
        price: price,
        notional: notional,
        fee: notional * settings.feeRate,
        time: quote.time,
        spreadCost: qty * (quote.mid - quote.bid),
        slippageCost: qty * (quote.bid - price));
  }
}
