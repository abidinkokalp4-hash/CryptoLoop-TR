"""Multi-coin execution safety with fake exchange fills; no account or network."""
from copy import deepcopy
import tempfile
import unittest
from test_backend import FakeClient, SETTINGS
from binance_tr import ApiError, dec
from service import BotService

SYMBOLS = ['BTC_TRY','ETH_TRY','BNB_TRY','SOL_TRY','XRP_TRY','DOGE_TRY','ADA_TRY','AVAX_TRY','LINK_TRY','DOT_TRY']
class MultiClient(FakeClient):
    def __init__(self):
        super().__init__(); self.bids = {}; self.opened = {}; self.assets = {}; self.reads = []
    def symbols(self):
        self.reads.append(('symbols',None)); template = super().symbols()[0]
        return [dict(deepcopy(template),symbol=s) for s in SYMBOLS]
    def account(self):
        self.reads.append(('account',None))
        return {'canTrade':1,'fiatTakerCommission':'0.0015','accountAssets':
            [{'asset':'TRY','free':'10000'}] + [{'asset':s.split('_')[0],'free':self.assets.get(s,'100')} for s in SYMBOLS]}
    def book(self, symbol):
        self.reads.append(('book',symbol)); bid = self.bids.get(symbol,100)
        return {'bids':[[str(bid),'1000']], 'asks':[[str(bid + .1),'1000']]}
    def orders(self, symbol, kind):
        self.reads.append(('orders',symbol)); return self.opened.get(symbol,[])

class MultiCoinTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.client = MultiClient()
        self.service = BotService(self.client,self.temp.name+'/multi.sqlite3',enabled=True,
            max_capital=10000,max_position=2000,max_entries=30,daily_loss=1000,clock=lambda:1790769600,sleep=lambda _:None)
        self.settings = dict(SETTINGS,symbols=SYMBOLS,maxCapital=2000,maxPosition=200,capitalPct=100,
            maxOpenPositions=10,maxTradesPerDay=20,dailyLossLimit=100)
        self.arm()
    def tearDown(self): self.service.db.close(); self.temp.cleanup()
    def arm(self): return self.service.arm({'confirmation':'CANLI SPOT ISLEM ONAYI','settings':self.settings})
    def buy(self, symbol, budget=150):
        return self.service.execute({'intentId':'cl-'+symbol.replace('_','-')+'-'+str(len(self.client.calls)),
            'symbol':symbol,'side':'BUY','budget':budget})
    def test_ten_simultaneous_positions_share_one_capital_and_entry_counter(self):
        for symbol in SYMBOLS: self.buy(symbol)
        positions, _, _, entries = self.service._positions()
        self.assertEqual(sum(p['quantity']>0 for p in positions.values()),10)
        self.assertEqual(entries,10)
        self.assertEqual(sum(p['basis'] for p in positions.values()),dec('1001.50'))
        self.assertLess(sum(p['basis'] for p in positions.values()),dec(self.settings['maxCapital']))
    def test_aggregate_cost_including_buy_fee_caps_another_coin(self):
        self.settings.update(maxCapital=200,maxPosition=150); self.arm(); self.buy(SYMBOLS[0])
        with self.assertRaises(ApiError): self.buy(SYMBOLS[1],100)
        self.assertEqual(len(self.client.calls),1)
    def test_existing_coin_cannot_open_duplicate_position(self):
        self.buy(SYMBOLS[0])
        with self.assertRaises(ApiError): self.buy(SYMBOLS[0])
        self.assertEqual(len(self.client.calls),1)
    def test_concurrent_position_count_limit_is_shared(self):
        self.settings['maxOpenPositions']=2; self.arm()
        self.buy(SYMBOLS[0]); self.buy(SYMBOLS[1])
        with self.assertRaises(ApiError): self.buy(SYMBOLS[2])
        self.assertEqual(len(self.client.calls),2)
    def test_daily_entry_count_is_shared(self):
        self.settings['maxTradesPerDay']=2; self.arm()
        self.buy(SYMBOLS[0]); self.buy(SYMBOLS[1])
        with self.assertRaises(ApiError): self.buy(SYMBOLS[2])
    def test_loss_in_another_coin_locks_new_buy(self):
        self.settings['dailyLossLimit']=10; self.arm(); self.buy(SYMBOLS[0])
        self.client.bids[SYMBOLS[0]]=50
        with self.assertRaises(ApiError): self.buy(SYMBOLS[1])
        self.assertTrue(self.service._risk_locked()); self.assertEqual(len(self.client.calls),1)
    def test_account_mismatch_in_another_coin_blocks_new_buy(self):
        self.buy(SYMBOLS[0]); self.client.assets[SYMBOLS[0]]='0'
        with self.assertRaises(ApiError): self.buy(SYMBOLS[1])
        self.assertEqual(len(self.client.calls),1)
        self.assertFalse(self.service.reconcile_many(SYMBOLS)['safe'])
    def test_open_order_in_another_watched_coin_blocks_buy(self):
        self.client.opened[SYMBOLS[-1]]=[{'orderId':'outside-bot'}]
        with self.assertRaises(ApiError): self.buy(SYMBOLS[0])
        self.assertEqual(self.client.calls,[])
    def test_sell_only_changes_its_coin_and_remains_allowed_at_entry_limit(self):
        self.settings['maxTradesPerDay']=2; self.arm(); self.buy(SYMBOLS[0]); self.buy(SYMBOLS[1])
        self.client.bids[SYMBOLS[0]]=102; self.client.bid=102
        self.service.execute({'intentId':'cl-exit-btc','symbol':SYMBOLS[0],'side':'SELL','quantity':1,'stopLoss':False})
        positions, _, _, entries = self.service._positions()
        self.assertEqual(positions[SYMBOLS[0]]['quantity'],0); self.assertEqual(positions[SYMBOLS[1]]['quantity'],1)
        self.assertEqual(entries,2)
    def test_read_only_preflight_checks_every_pair_but_cash_is_shared(self):
        self.service.halt(); self.client.reads.clear()
        self.client.place=lambda _: self.fail('preflight placed a real order')
        self.client.cancel=lambda **_: self.fail('preflight cancelled an order')
        report=self.service.preflight_many(SYMBOLS)
        self.assertTrue(report['readOnly']); self.assertEqual(report['symbols'],SYMBOLS)
        self.assertEqual(len(report['checks']),10); self.assertFalse(self.service.armed)
        self.assertEqual(sum(kind=='account' for kind,_ in self.client.reads),1)
        self.assertEqual(sum(kind=='symbols' for kind,_ in self.client.reads),1)
        self.assertTrue(all(c['account']['availableTry']=='10000' for c in report['checks']))
    def test_reconcile_collects_all_positions_and_history_without_multiplying_cash(self):
        for symbol in SYMBOLS: self.buy(symbol)
        report=self.service.reconcile_many(SYMBOLS)
        self.assertTrue(report['safe']); self.assertEqual(report['availableTry'],'10000')
        self.assertEqual(len(report['coins']),10); self.assertEqual(len(report['events']),10)
    def test_held_pair_cannot_be_removed_when_rearming(self):
        self.buy(SYMBOLS[-1]); self.settings['symbols']=SYMBOLS[:-1]
        with self.assertRaises(ApiError): self.arm()
        self.assertFalse(self.service.armed)
    def test_unselected_or_duplicate_pairs_are_rejected(self):
        for selected in [['BTC_TRY','BTC_TRY'],SYMBOLS+['FAKE_TRY'],['BTC_USDT']]:
            with self.assertRaises(ApiError): self.service.preflight_many(selected)
        self.settings['symbols']=SYMBOLS[:2]; self.arm()
        with self.assertRaises(ApiError): self.buy(SYMBOLS[-1])
    def test_emergency_disarms_all_coins_without_selling_positions(self):
        self.buy(SYMBOLS[0]); self.buy(SYMBOLS[1]); self.service.halt()
        with self.assertRaises(ApiError): self.buy(SYMBOLS[2])
        self.assertEqual(len(self.client.calls),2)
        self.assertEqual(sum(p['quantity']>0 for p in self.service._positions()[0].values()),2)

if __name__=='__main__': unittest.main()
