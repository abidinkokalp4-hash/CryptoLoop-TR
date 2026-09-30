import hashlib
import hmac
import json
from pathlib import Path
import sys
import tempfile
import unittest
from urllib.parse import parse_qs
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from binance_tr import ApiError, BinanceTrClient, dec, quantize
from service import BotService

SETTINGS = {'symbol': 'BTC_TRY', 'maxCapital': 1000, 'maxPosition': 1000, 'capitalPct': 100,
    'dailyLossLimit': 100, 'maxTradesPerDay': 3, 'stopLossPct': 2, 'minNetProfitPct': 0.3,
    'maxSpreadPct': 1, 'slippagePct': 0.05}
class FakeClient:
    _key = _secret = 'fake-test-only'
    def __init__(self): self.calls = []; self.unknown = False; self.bid = 100; self.fee_asset = 'TRY'; self.open = []; self.base = '20'
    def sync_time(self): pass
    def symbols(self): return [{'symbol': 'BTC_TRY', 'type': 1, 'spotTradingEnable': 1, 'orderTypes': ['MARKET','LIMIT'],
        'filters': [{'filterType':'LOT_SIZE','minQty':'0.001','maxQty':'100','stepSize':'0.001'},
                    {'filterType':'NOTIONAL','minNotional':'10'}, {'filterType':'PRICE_FILTER','tickSize':'0.01'}]}]
    def account(self): return {'canTrade':1, 'fiatTakerCommission':'0.0015',
        'accountAssets':[{'asset':'TRY','free':'1000'},{'asset':'BTC','free':self.base}]}
    def orders(self, symbol, kind): return self.open
    def book(self, symbol): return {'bids':[[str(self.bid),'100']], 'asks':[[str(self.bid + .1),'100']]}
    def place(self, params):
        self.calls.append(params)
        if self.unknown: raise ApiError('timeout', uncertain=True)
        return {'orderId':len(self.calls)}
    def order(self, **kwargs):
        if self.unknown: raise ApiError('order not found')
        order_id = kwargs.get('order_id') or '1'
        return {'orderId':order_id,'executedQty':'1','status':2}
    def trades(self, symbol, order_id): return [{'orderId':str(order_id),'qty':'1','quoteQty':str(self.calls[int(order_id)-1].get('price', self.bid if self.calls[int(order_id)-1]['side']==1 else 100)),'commission':'0.0015' if self.fee_asset=='BTC' else '0.15', 'commissionAsset':self.fee_asset}]
    def cancel(self, **kwargs): return {'status':3}
    def fee_asset_value(self, asset): return dec(10)
class BackendTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.client = FakeClient()
        self.service = BotService(self.client, self.temp.name+'/db.sqlite3', enabled=True,
            max_capital=1000,max_position=1000,clock=lambda:1790769600,sleep=lambda _:None)
        self.service.arm({'confirmation':'CANLI SPOT ISLEM ONAYI','settings':SETTINGS})
    def tearDown(self): self.service.db.close(); self.temp.cleanup()
    def body(self, id='cl-test'): return {'intentId':id,'symbol':'BTC_TRY','side':'BUY','budget':200}
    def test_idempotency_is_durable_not_exchange_clientid_assumption(self):
        a=self.service.execute(self.body()); b=self.service.execute(self.body())
        self.assertEqual(a['fill'],b['fill']); self.assertEqual(len(self.client.calls),1)
    def test_same_id_with_changed_payload_rejected(self):
        self.service.execute(self.body())
        with self.assertRaises(ApiError): self.service.execute(dict(self.body(),budget=201))
    def test_unknown_outcome_never_resubmitted(self):
        self.client.unknown=True
        with self.assertRaises(ApiError): self.service.execute(self.body())
        with self.assertRaises(ApiError): self.service.execute(self.body())
        self.assertEqual(len(self.client.calls),1); self.assertFalse(self.service.armed)
        self.assertFalse(self.service.reconcile('BTC_TRY')['safe'])
    def test_disabled_by_default(self):
        self.service.enabled=False
        with self.assertRaises(ApiError): self.service.execute(self.body())
    def test_explicit_arm_confirmation_required(self):
        with self.assertRaises(ApiError): self.service.arm({'confirmation':'yes','settings':SETTINGS})
    def test_server_cap_cannot_be_increased_from_mobile(self):
        with self.assertRaises(ApiError): self.service.arm({'confirmation':'CANLI SPOT ISLEM ONAYI','settings':dict(SETTINGS,maxCapital=2000)})
    def test_buy_budget_cannot_exceed_cap(self):
        with self.assertRaises(ApiError): self.service.execute(dict(self.body(),budget=1001))
        self.assertEqual(self.client.calls,[])
    def test_market_buy_has_fee_reserve_and_official_numeric_enums(self):
        self.service.execute(self.body()); p=self.client.calls[0]
        self.assertEqual(p['type'],2); self.assertEqual(p['side'],0)
        self.assertLess(dec(p['quoteOrderQty'])*dec('1.01'),dec(200))
    def test_base_asset_fee_not_double_counted(self):
        self.client.fee_asset='BTC'; f=self.service.execute(self.body())['fill']
        self.assertEqual(dec(f['quantity']),dec('0.9985'))
        self.assertEqual(dec(f['notional'])+dec(f['fee']),dec(100))
        p=self.service.reconcile('BTC_TRY')['position']; self.assertEqual(dec(p['buyFee']),dec('0.15'))
    def test_quote_asset_fee_is_in_cost_basis(self):
        f=self.service.execute(self.body())['fill']; self.assertEqual(dec(f['notional'])+dec(f['fee']),dec('100.15'))
    def test_existing_external_open_order_blocks_arming(self):
        self.client.open=[{'orderId':99}]
        with self.assertRaises(ApiError): self.service.arm({'confirmation':'CANLI SPOT ISLEM ONAYI','settings':SETTINGS})
    def test_account_mismatch_blocks_reconciliation(self):
        self.service.execute(self.body()); self.client.base='0'; self.assertFalse(self.service.reconcile('BTC_TRY')['safe'])
    def test_second_open_position_is_rejected(self):
        self.service.execute(self.body())
        with self.assertRaises(ApiError): self.service.execute(self.body('cl-other'))
        self.assertEqual(len(self.client.calls),1)
    def test_profit_exit_uses_net_positive_fok_price_floor(self):
        self.service.execute(self.body()); self.client.bid=102
        self.service.execute({'intentId':'cl-exit','symbol':'BTC_TRY','side':'SELL','quantity':1,'stopLoss':False})
        p=self.client.calls[-1]; self.assertEqual(p['type'],1); self.assertEqual(p['timeInForce'],3)
        self.assertGreater(dec(p['price'])*dec('0.99'),dec('100.15')*dec('1.003'))
    def test_stop_loss_exit_is_market_and_requires_loss(self):
        self.service.execute(self.body())
        body={'intentId':'cl-exit','symbol':'BTC_TRY','side':'SELL','quantity':1,'stopLoss':True}
        with self.assertRaises(ApiError): self.service.execute(body)
        self.client.bid=95; self.service.execute(body); self.assertEqual(self.client.calls[-1]['type'],2)
    def test_daily_lock_prevents_new_buy(self):
        self.service._lock_day()
        with self.assertRaises(ApiError): self.service.execute(self.body())
        self.assertEqual(len(self.client.calls),0)
    def test_halt_disarms(self):
        self.service.halt()
        with self.assertRaises(ApiError): self.service.execute(self.body())
    def test_backend_restart_is_disarmed(self):
        other=BotService(self.client,self.temp.name+'/db.sqlite3',enabled=True)
        self.assertFalse(other.armed); other.db.close()
class ClientTests(unittest.TestCase):
    def test_signature_matches_exact_form_body(self):
        captured=[]
        def transport(m,u,h,b): captured.append((m,u,h,b)); return 200,{},b'{"code":0,"data":{"orderId":"1"}}'
        c=BinanceTrClient('fake-test-key','fake-test-secret',transport,clock=lambda:1000)
        c.place({'symbol':'BTC_TRY','side':0,'type':2,'quoteOrderQty':'100'})
        m,u,h,b=captured[0]; text=b.decode(); query,signature=text.rsplit('&signature=',1)
        self.assertEqual(signature,hmac.new(b'fake-test-secret',query.encode(),hashlib.sha256).hexdigest())
        self.assertEqual(u,'https://www.binance.tr/open/v1/orders'); self.assertEqual(m,'POST')
        self.assertNotIn('signature=',u); self.assertEqual(parse_qs(query)['recvWindow'],['5000'])
    def test_withdrawal_and_futures_endpoints_blocked(self):
        c=BinanceTrClient()
        for path in ['/open/v1/withdraws','/fapi/v1/order','/sapi/v1/margin/order']:
            with self.assertRaises(ApiError): c._call('POST',path)
    def test_rate_limit_honors_retry_after(self):
        calls=[]
        def transport(*args): calls.append(args); return 429,{'Retry-After':'60'},b'{}'
        c=BinanceTrClient(transport=transport,clock=lambda:1000)
        for _ in range(2):
            with self.assertRaises(ApiError): c.symbols()
        self.assertEqual(len(calls),1)
    def test_post_server_error_is_unknown_and_never_retried(self):
        calls=[]
        def transport(*args): calls.append(args); return 503,{},b'{}'
        c=BinanceTrClient('fake-test-key','fake-test-secret',transport)
        with self.assertRaises(ApiError) as e: c.place({'symbol':'BTC_TRY'})
        self.assertTrue(e.exception.uncertain); self.assertEqual(len(calls),1)
    def test_non_finite_numbers_rejected(self):
        for v in ['NaN','Infinity','-1']:
            with self.assertRaises(ApiError): dec(v)
    def test_step_rounding_is_conservative(self):
        self.assertEqual(quantize(dec('1.239'),dec('0.01')),dec('1.23'))
        self.assertEqual(quantize(dec('1.231'),dec('0.01'),up=True),dec('1.24'))
if __name__=='__main__': unittest.main()
