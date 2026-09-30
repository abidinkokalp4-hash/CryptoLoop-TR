"""Authenticated single-owner signing bridge with durable order idempotency.
Strategy runs on the phone; this service enforces independent caps and reconciles.
A restart disarms trading. Uncertain orders remain locked, never resubmitted.
"""
import hashlib
import json
import re
import sqlite3
import threading
import time
from datetime import datetime, timezone, timedelta
from decimal import Decimal as D
from binance_tr import ApiError, dec, fmt, quantize

TSI = timezone(timedelta(hours=3))
ACTIVE = (-2, 0, 1, 4)
TERMINAL = (2, 3, 5, 6)

def day(now):
    return datetime.fromtimestamp(now, TSI).date().isoformat()

def utc_iso(now):
    return datetime.fromtimestamp(now, timezone.utc).isoformat()

class BotService:
    def __init__(self, client, database, *, enabled=False, max_capital='10000',
                 max_position='2000', daily_loss='300', max_entries=20,
                 fee_ceiling='0.01', clock=time.time, sleep=time.sleep):
        self.client, self.clock, self.sleep = client, clock, sleep
        self.enabled, self.armed = enabled, False
        self.settings = None
        self.max_capital, self.max_position = dec(max_capital), dec(max_position)
        self.daily_loss, self.max_entries = dec(daily_loss), int(max_entries)
        self.fee_ceiling = dec(fee_ceiling)
        if not D('0') < self.fee_ceiling < D('0.05'):
            raise ValueError('Invalid commission ceiling')
        self.lock = threading.RLock()
        self.db = sqlite3.connect(database, check_same_thread=False)
        self.db.row_factory = sqlite3.Row
        self.db.execute('PRAGMA journal_mode=WAL')
        self.db.execute('PRAGMA synchronous=FULL')
        self.db.executescript('''CREATE TABLE IF NOT EXISTS intents (
            id TEXT PRIMARY KEY, fingerprint TEXT NOT NULL, symbol TEXT NOT NULL,
            side TEXT NOT NULL, created REAL NOT NULL, state TEXT NOT NULL,
            order_id TEXT, fill TEXT, budget TEXT, profit_min TEXT);
          CREATE TABLE IF NOT EXISTS risk_days (day TEXT PRIMARY KEY, locked INTEGER NOT NULL DEFAULT 0);
        ''')
        columns = {r[1] for r in self.db.execute('PRAGMA table_info(intents)')}
        for column in ('budget', 'profit_min'):
            if column not in columns: self.db.execute(f'ALTER TABLE intents ADD COLUMN {column} TEXT')
        self.db.commit()

    def health(self):
        return {'spotOnly': True, 'liveEnabled': self.enabled, 'armed': self.armed,
                'credentialsConfigured': bool(self.client._key and self.client._secret),
                'readOnlyPreflight': True}
    def _rows(self):
        return self.db.execute('SELECT * FROM intents ORDER BY created, rowid').fetchall()
    def _positions(self):
        positions, realized, daily_realized, entries = {}, D(0), D(0), 0
        for row in self._rows():
            if not row['fill']: continue
            f = json.loads(row['fill']); symbol = row['symbol']
            qty, notional, fee = dec(f['quantity']), dec(f['notional']), dec(f['fee'])
            if row['side'] == 'BUY':
                if day(row['created']) == day(self.clock()): entries += 1
                p = positions.setdefault(symbol, {'quantity': D(0), 'basis': D(0), 'notional': D(0),
                    'buyFee': D(0), 'openedAt': f['time'], 'orderId': f['orderId']})
                p['quantity'] += qty; p['basis'] += notional + fee
                p['notional'] += notional; p['buyFee'] += fee
            else:
                p = positions.get(symbol)
                if not p or qty > p['quantity'] + D('0.000000000001'):
                    raise ApiError('Bot emir defteri ile miktar uyuşmuyor.', uncertain=True)
                ratio = min(D(1), qty / p['quantity'])
                pnl = notional - fee - p['basis'] * ratio
                realized += pnl
                if day(row['created']) == day(self.clock()): daily_realized += pnl
                for key in ('basis', 'notional', 'buyFee'): p[key] *= 1 - ratio
                p['quantity'] = max(D(0), p['quantity'] - qty)
        return positions, realized, daily_realized, entries
    @staticmethod
    def _assets(account):
        return {a['asset']: dec(a['free']) for a in account['accountAssets']}
    def _fee(self, account):
        if 'fiatTakerCommission' not in account:
            raise ApiError('TRY hesap komisyonu doğrulanamadı; emir gönderilmedi.')
        fee = dec(account['fiatTakerCommission'])
        if fee > self.fee_ceiling: raise ApiError('Hesap komisyonu sunucu üst sınırını aşıyor.')
        return fee
    def _rules(self, symbol):
        if not re.fullmatch(r'[A-Z0-9]+_TRY', symbol): raise ApiError('Yalnızca TRY spot çifti kabul edilir.')
        for r in self.client.symbols():
            if r['symbol'] == symbol:
                if int(r['type']) != 1 or not r.get('spotTradingEnable') or 'MARKET' not in r['orderTypes']:
                    raise ApiError('Desteklenmeyen veya kapalı spot çift.')
                return {f['filterType']: f for f in r['filters']}
        raise ApiError('Borsada işlem çifti bulunamadı.')
    def _validate_order(self, rules, qty, price):
        lot = rules.get('LOT_SIZE', {})
        if qty <= 0 or qty < dec(lot.get('minQty', 0)) or (dec(lot.get('maxQty', 0)) and qty > dec(lot['maxQty'])):
            raise ApiError('Emir miktarı borsa sınırları dışında.')
        n = rules.get('NOTIONAL', rules.get('MIN_NOTIONAL', {}))
        if qty * price < dec(n.get('minNotional', 0)):
            raise ApiError('Minimum emir tutarı sağlanmıyor.')
        if dec(n.get('maxNotional', 0)) and qty * price > dec(n['maxNotional']):
            raise ApiError('Maksimum emir tutarı aşılıyor.')
    def _unknown(self):
        return self.db.execute("SELECT COUNT(*) FROM intents WHERE state IN ('PENDING','SUBMITTED','UNKNOWN')").fetchone()[0]
    def _risk_locked(self):
        row = self.db.execute('SELECT locked FROM risk_days WHERE day=?', (day(self.clock()),)).fetchone()
        return bool(row and row[0])
    def _lock_day(self):
        self.db.execute('INSERT OR REPLACE INTO risk_days(day,locked) VALUES (?,1)', (day(self.clock()),)); self.db.commit()
    def _resolve(self):
        for row in self.db.execute("SELECT * FROM intents WHERE state IN ('PENDING','SUBMITTED','UNKNOWN')").fetchall():
            try:
                detail = self.client.order(order_id=row['order_id'], client_id=row['id'])
                if int(detail['status']) not in TERMINAL: continue
                self._record_terminal(row['id'], detail)
            except ApiError:
                continue
    def history(self, symbol):
        events, qty, basis, notional = [], D(0), D(0), D(0)
        last_sell, last_time = D(0), None
        for row in self._rows():
            if row['symbol'] != symbol or not row['fill']: continue
            f = json.loads(row['fill']); q, n, fee = dec(f['quantity']), dec(f['notional']), dec(f['fee'])
            gross, pnl = D(0), D(0)
            if row['side'] == 'BUY':
                qty += q; basis += n + fee; notional += n
            else:
                ratio = min(D(1), q / qty)
                gross, pnl = n - notional * ratio, n - fee - basis * ratio
                qty = max(D(0), qty - q); basis *= 1 - ratio; notional *= 1 - ratio
                if qty == 0: last_sell, last_time = dec(f['price']), f['time']
            events.insert(0, dict(f, side='AL' if row['side']=='BUY' else 'SAT', symbol=symbol,
                paper=False, grossPnl=fmt(gross), pnl=fmt(pnl), reason='Sunucudan uzlaştırılan spot emir'))
        return events, last_sell, last_time
    def reconcile(self, symbol):
        with self.lock:
            if not re.fullmatch(r'[A-Z0-9]+_TRY', symbol): raise ApiError('Geçersiz TRY spot çifti.')
            self.client.sync_time(); self._resolve()
            account = self.client.account(); self._fee(account)
            open_orders = self.client.orders(symbol, 1)
            return self._reconcile_snapshot(symbol, account, open_orders)
    def _reconcile_snapshot(self, symbol, account, open_orders):
        positions, realized, daily_pnl, entries = self._positions()
        assets = self._assets(account); p = positions.get(symbol)
        base = symbol.split('_')[0]
        safe = not self._unknown() and not open_orders and (
            p is None or assets.get(base, D(0)) + D('0.000000000001') >= p['quantity'])
        result = None
        if p and p['quantity'] > 0:
            result = {'symbol': symbol, 'quantity': fmt(p['quantity']), 'entryPrice': fmt(p['notional'] / p['quantity']),
                'notional': fmt(p['notional']), 'buyFee': fmt(p['buyFee']), 'openedAt': p['openedAt'], 'orderId': p['orderId']}
        events, last_sell, last_time = self.history(symbol)
        return {'events': events, 'lastSellPrice': fmt(last_sell), 'lastSellTime': last_time, 'safe': safe, 'availableTry': fmt(assets.get('TRY', D(0))), 'position': result,
            'realizedPnl': fmt(realized), 'dailyPnl': fmt(daily_pnl), 'dailyEntries': entries,
            'riskLocked': self._risk_locked(), 'feePct': fmt(self.fee_ceiling * 100), 'accountFeePct': fmt(self._fee(account) * 100)}
    def preflight(self, symbol):
        """Only exchange GET requests. Never arm, cancel, or place an order.

        canTrade describes the account, not this key's permissions. Withdrawal
        permissions cannot be verified from the account response.
        """
        with self.lock:
            self.client.sync_time(); self._rules(symbol)
            book = self.client.book(symbol)
            bid, ask = dec(book['bids'][0][0]), dec(book['asks'][0][0])
            if not D(0) < bid <= ask: raise ApiError('Emir defteri doğrulanamadı.')
            account = self.client.account(); fee = self._fee(account)
            open_orders = self.client.orders(symbol, 1)
            history = self.client.orders(symbol, 2)
            trades = self.client.trades(symbol)
            self._resolve()
            snapshot = self._reconcile_snapshot(symbol, account, open_orders)
            return {'readOnly': True, 'symbol': symbol, 'verifiedAt': utc_iso(self.clock()),
                'liveEnabled': self.enabled, 'armed': self.armed,
                'market': {'bid': fmt(bid), 'ask': fmt(ask), 'spreadPct': fmt((ask - bid) / ((ask + bid) / 2) * 100)},
                'account': {'availableTry': snapshot['availableTry'], 'feePct': fmt(fee * 100),
                    'canTrade': int(account.get('canTrade', 0)) == 1},
                'reconciliation': {'safe': snapshot['safe'], 'riskLocked': snapshot['riskLocked'],
                    'openOrderCount': len(open_orders), 'unresolvedIntentCount': self._unknown(),
                    'historyCount': len(history), 'tradeCount': len(trades), 'position': snapshot['position']},
                'serverLimits': {'maxCapital': fmt(self.max_capital), 'maxPosition': fmt(self.max_position),
                    'dailyLossLimit': fmt(self.daily_loss), 'maxTradesPerDay': self.max_entries},
                'keyPermissionsVerified': False, 'withdrawalPermissionVerified': False}
    def arm(self, body):
        with self.lock:
            self.armed = False; self.settings = None
            if not self.enabled: raise ApiError('Canlı işlemler sunucuda kapalı. Önce sunucu operatörü etkinleştirmeli.', status=403)
            if body.get('confirmation') != 'CANLI SPOT ISLEM ONAYI': raise ApiError('Açık kullanıcı onayı gerekli.', status=403)
            s = body.get('settings', {})
            for key in ('maxCapital','maxPosition','capitalPct','dailyLossLimit','stopLossPct','minNetProfitPct','maxSpreadPct','slippagePct'):
                dec(s.get(key))
            if not D(0) < dec(s['capitalPct']) <= 100 or not D(0) < dec(s['stopLossPct']) < 100 or dec(s['minNetProfitPct']) <= 0:
                raise ApiError('Geçersiz risk/strateji ayarı.')
            if not D(0) < dec(s['maxPosition']) <= dec(s['maxCapital']) <= self.max_capital or dec(s['maxPosition']) > self.max_position:
                raise ApiError('Sermaye/pozisyon limiti sunucunun izin verdiği sınırı aşıyor.')
            if dec(s['dailyLossLimit']) <= 0 or int(s['maxTradesPerDay']) < 1:
                raise ApiError('Günlük limitler geçersiz.')
            reconciled = self.reconcile(s['symbol'])
            if not reconciled['safe']: raise ApiError('Açık/belirsiz emir veya miktar uyuşmazlığı var.', uncertain=True)
            positions, *_ = self._positions()
            capital = min(dec(s['maxCapital']), self.max_capital)
            position_limit = min(dec(s['maxPosition']), self.max_position)
            if sum((p['basis'] for p in positions.values() if p['quantity'] > 0), D(0)) > capital or any(
                    p['quantity'] > 0 and p['basis'] > position_limit for p in positions.values()):
                raise ApiError('Mevcut bot pozisyonu yeni sermaye/pozisyon sınırını aşıyor. Önce hesabı kontrol edin.')
            if any(p['quantity'] > 0 and sym != s['symbol'] for sym, p in positions.items()):
                raise ApiError('Başka çiftte bot pozisyonu açık; çift değiştirilemez.')
            self._rules(s['symbol']); self.settings = s; self.armed = True
            return {'armed': True, 'maxCapital': s['maxCapital']}
    def halt(self):
        # Disarm before locking: an in-flight order can finish but no next order starts.
        self.armed = False
        with self.lock:
            failures = 0
            for row in self.db.execute("SELECT * FROM intents WHERE state IN ('PENDING','SUBMITTED','UNKNOWN')").fetchall():
                try:
                    self.client.cancel(order_id=row['order_id'], client_id=row['id'])
                except ApiError:
                    failures += 1
            self._resolve()
            return {'armed': False, 'unresolved': self._unknown(), 'cancelFailures': failures}
    def _record_terminal(self, intent_id, detail):
        row = self.db.execute('SELECT * FROM intents WHERE id=?', (intent_id,)).fetchone()
        if row['fill']: return json.loads(row['fill'])
        qty = dec(detail.get('executedQty', 0))
        if qty == 0:
            self.db.execute("UPDATE intents SET state='REJECTED',order_id=? WHERE id=?", (str(detail['orderId']), intent_id)); self.db.commit()
            raise ApiError('Emir gerçekleşmedi. Yeniden piyasa teyidi bekleyin.')
        trades = self.client.trades(row['symbol'], str(detail['orderId']))
        trades = [t for t in trades if str(t['orderId']) == str(detail['orderId'])]
        filled_qty = sum((dec(t['qty']) for t in trades), D(0))
        if abs(filled_qty - qty) > D('0.000000000001'):
            raise ApiError('Gerçekleşen işlemler henüz tam uzlaştırılamadı.', uncertain=True)
        gross = sum((dec(t['quoteQty']) for t in trades), D(0))
        base, base_fee, other_fee = row['symbol'].split('_')[0], D(0), D(0)
        for t in trades:
            fee, asset = dec(t['commission']), t['commissionAsset']
            if asset == base: base_fee += fee
            elif asset == 'TRY': other_fee += fee
            elif fee: other_fee += fee * self.client.fee_asset_value(asset)
        price = gross / qty
        if row['side'] == 'BUY':
            actual_qty = qty - base_fee
            # Base-asset fee is already reflected in net quantity. Report it as a fee
            # while subtracting it from notional, preserving exact TRY cost basis.
            notional, fee = gross - base_fee * price, other_fee + base_fee * price
        else:
            actual_qty = qty + base_fee
            notional, fee = gross + base_fee * price, other_fee + base_fee * price
        if actual_qty <= 0: raise ApiError('Gerçekleşen miktar geçersiz.', uncertain=True)
        fill = {'orderId': str(detail['orderId']), 'quantity': fmt(actual_qty), 'price': fmt(price),
                'notional': fmt(notional), 'fee': fmt(fee), 'time': utc_iso(self.clock())}
        violates_budget = row['budget'] is not None and notional + fee > dec(row['budget']) + D('0.000001')
        violates_profit = row['profit_min'] is not None and notional - fee < dec(row['profit_min'])
        self.db.execute("UPDATE intents SET state='FILLED',order_id=?,fill=? WHERE id=?",
                        (str(detail['orderId']), json.dumps(fill), intent_id)); self.db.commit()
        if violates_budget or violates_profit:
            self.armed = False; self._lock_day()
            raise ApiError('Gerçekleşme beklenen maliyet/kâr sınırını ihlal etti. Emir kaydedildi; risk kontrolü gerekli.', uncertain=True, status=503)
        return fill
    def execute(self, body):
        with self.lock:
            fingerprint = hashlib.sha256(json.dumps(body, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
            intent_id = body.get('intentId', '')
            if not re.fullmatch(r'cl-[a-zA-Z0-9-]{1,48}', intent_id): raise ApiError('Geçersiz emir kimliği.')
            row = self.db.execute('SELECT * FROM intents WHERE id=?', (intent_id,)).fetchone()
            if row:
                if row['fingerprint'] != fingerprint: raise ApiError('Emir kimliği farklı içerikle tekrar kullanıldı.', status=409)
                if row['fill']: return {'fill': json.loads(row['fill']), 'replayed': True}
                raise ApiError('Bu emir daha önce işlendi; tekrar gönderilmez. Önce uzlaştırın.', uncertain=row['state'] != 'REJECTED', status=409)
            if not self.armed or not self.enabled or self.settings is None: raise ApiError('Canlı bot aktif değil.', status=403)
            if self._unknown(): raise ApiError('Belirsiz emir varken yeni emir gönderilmez.', uncertain=True)
            s, symbol, side = self.settings, body.get('symbol'), body.get('side')
            if symbol != s['symbol'] or side not in ('BUY', 'SELL'): raise ApiError('İşlem çifti/yönü geçersiz.')
            self.client.sync_time(); account = self.client.account(); fee_rate = self._fee(account)
            if int(account.get('canTrade', 0)) != 1: raise ApiError('Spot işlem yetkisi yok.')
            if self.client.orders(symbol, 1): raise ApiError('Açık emir varken yeni bot emri açılmaz.')
            assets = self._assets(account); rules = self._rules(symbol)
            book = self.client.book(symbol); bid, ask = dec(book['bids'][0][0]), dec(book['asks'][0][0])
            if not D(0) < bid <= ask: raise ApiError('Emir defteri geçersiz.')
            positions, _, daily_realized, entries = self._positions(); p = positions.get(symbol)
            unrealized = sum((p0['quantity'] * bid * (1 - fee_rate) - p0['basis'] for sym, p0 in positions.items() if sym == symbol), D(0))
            loss_limit = min(self.daily_loss, dec(s['dailyLossLimit']))
            if daily_realized + unrealized <= -loss_limit: self._lock_day()
            budget_limit, profit_min = None, None
            params = {'symbol': symbol, 'side': 0 if side == 'BUY' else 1, 'clientId': intent_id}
            lot = rules.get('LOT_SIZE', {}); step = dec(lot.get('stepSize', 0))
            if side == 'BUY':
                if self._risk_locked() or entries >= min(self.max_entries, int(s['maxTradesPerDay'])):
                    raise ApiError('Günlük risk/işlem limiti; yeni alımlar durduruldu.')
                if any(v['quantity'] > 0 for v in positions.values()): raise ApiError('Bot pozisyonu zaten açık.')
                if (ask - bid) / ((ask + bid) / 2) * 100 > dec(s['maxSpreadPct']): raise ApiError('Spread limiti aşıldı.')
                available = assets.get('TRY', D(0)); requested = dec(body.get('budget'))
                cap = min(dec(s['maxPosition']), dec(s['maxCapital']), self.max_capital, self.max_position,
                          available, available * dec(s['capitalPct']) / 100)
                if requested <= 0 or requested > cap + D('0.000001'): raise ApiError('Sermaye üst sınırı aşılıyor.')
                budget_limit = fmt(requested)
                quote_budget = quantize(requested / (1 + self.fee_ceiling), D('0.01'))
                qty = quantize(quote_budget / (ask * (1 + dec(s['slippagePct']) / 100)), step)
                self._validate_order(rules, qty, ask)
                params.update(type=2, quoteOrderQty=fmt(quote_budget))
            else:
                if not p or p['quantity'] <= 0: raise ApiError('Bota ait açık pozisyon yok.')
                qty = quantize(min(dec(body.get('quantity')), p['quantity'], assets.get(symbol.split('_')[0], D(0))), step)
                if qty <= 0: raise ApiError('Satılabilir bot miktarı yok.')
                stop_loss = body.get('stopLoss') is True
                if stop_loss:
                    net_pct = (p['quantity'] * bid * (1 - dec(s['slippagePct']) / 100) * (1 - fee_rate) / p['basis'] - 1) * 100
                    if net_pct > -dec(s['stopLossPct']): raise ApiError('Stop loss koşulu henüz oluşmadı.')
                    params.update(type=2, quantity=fmt(qty))
                    self._validate_order(rules, qty, bid)
                else:
                    # Net-positive profit exits use a FOK limit floor; a market sell
                    # could slip below break-even between the signal and fill.
                    profit_min = fmt(p['basis'] * qty / p['quantity'] * (1 + dec(s['minNetProfitPct']) / 100))
                    floor = p['basis'] / p['quantity'] * (1 + dec(s['minNetProfitPct']) / 100) / (1 - self.fee_ceiling)
                    price = quantize(floor, dec(rules.get('PRICE_FILTER', {}).get('tickSize', '0.01')), up=True)
                    if bid < price: raise ApiError('Net kârı koruyan satış fiyatı henüz oluşmadı.')
                    self._validate_order(rules, qty, price)
                    params.update(type=1, quantity=fmt(qty), price=fmt(price), timeInForce=3)
            # Persist BEFORE submission. clientId is not unique on Binance TR!
            self.db.execute("INSERT INTO intents(id,fingerprint,symbol,side,created,state,budget,profit_min) VALUES (?,?,?,?,?,'PENDING',?,?)",
                (intent_id, fingerprint, symbol, side, self.clock(), budget_limit, profit_min)); self.db.commit()
            if not self.armed:
                self.db.execute("UPDATE intents SET state='REJECTED' WHERE id=?", (intent_id,)); self.db.commit()
                raise ApiError('Acil durdurma nedeniyle emir gönderilmedi.')
            try:
                result = self.client.place(params); order_id = str(result['orderId'])
                self.db.execute("UPDATE intents SET state='SUBMITTED',order_id=? WHERE id=?", (order_id, intent_id)); self.db.commit()
                for _ in range(8):
                    detail = self.client.order(order_id=order_id)
                    if int(detail['status']) in TERMINAL: return {'fill': self._record_terminal(intent_id, detail)}
                    self.sleep(1)
                # Accepted orders are not assumed filled. Cancel remainder, then reconcile.
                self.client.cancel(order_id=order_id)
                detail = self.client.order(order_id=order_id)
                if int(detail['status']) in TERMINAL: return {'fill': self._record_terminal(intent_id, detail)}
                raise ApiError('Emir durumu belirsiz; uzlaştırma gerekiyor.', uncertain=True, status=503)
            except ApiError as exc:
                current = self.db.execute('SELECT state FROM intents WHERE id=?', (intent_id,)).fetchone()[0]
                if current != 'FILLED' and current != 'REJECTED':
                    # A known placement rejection is safe; all post-acceptance failures lock.
                    uncertain = exc.uncertain or current == 'SUBMITTED'
                    self.db.execute('UPDATE intents SET state=? WHERE id=?', ('UNKNOWN' if uncertain else 'REJECTED', intent_id)); self.db.commit()
                    exc.uncertain = uncertain
                if exc.uncertain: self.armed = False
                raise
            except Exception as exc:
                self.db.execute("UPDATE intents SET state='UNKNOWN' WHERE id=?", (intent_id,)); self.db.commit(); self.armed = False
                raise ApiError('Emir işleme sonucu doğrulanamadı; uzlaştırma gerekli.', uncertain=True, status=503) from exc
