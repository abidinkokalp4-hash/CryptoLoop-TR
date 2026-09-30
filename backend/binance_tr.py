"""Spot-only Binance TR client. Official API reviewed 2026-09-30.
No credentials in URLs/log output, no withdrawal/margin/futures methods.
A mutating request is NEVER automatically retried.
"""
import hashlib
import hmac
import json
import time
import urllib.error
import urllib.parse
import urllib.request
from decimal import Decimal, InvalidOperation, ROUND_DOWN, ROUND_UP

D = Decimal
REST = 'https://www.binance.tr'
MARKET = 'https://api.binance.me'
ALLOWED = {
    ('GET', '/open/v1/common/time'), ('GET', '/open/v1/common/symbols'),
    ('GET', '/open/v1/account/spot'), ('GET', '/open/v1/account/spot/asset'),
    ('GET', '/open/v1/orders'), ('GET', '/open/v1/orders/detail'),
    ('GET', '/open/v1/orders/trades'), ('POST', '/open/v1/orders'),
    ('POST', '/open/v1/orders/cancel'), ('POST', '/open/v1/user-listen-token'),
}

class NoRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *_args, **_kwargs):
        return None  # Never forward API headers or signed URLs to another host.

class ApiError(Exception):
    def __init__(self, message, *, uncertain=False, status=400):
        super().__init__(message)
        self.uncertain, self.status = uncertain, status

def dec(value):
    try:
        v = D(str(value))
    except InvalidOperation as exc:
        raise ApiError('Geçersiz sayısal değer.') from exc
    if not v.is_finite() or v < 0:
        raise ApiError('Değer sonlu ve negatif olmayan bir sayı olmalı.')
    return v

def fmt(value):
    return format(value, 'f')

def quantize(value, step, *, up=False):
    if step <= 0:
        return value
    return (value / step).to_integral_value(rounding=ROUND_UP if up else ROUND_DOWN) * step

class BinanceTrClient:
    def __init__(self, api_key='', api_secret='', transport=None, clock=time.time):
        self._key, self._secret = api_key, api_secret
        self.transport = transport or self._transport
        self.clock = clock
        self.offset = 0
        self.blocked_until = 0

    @staticmethod
    def _transport(method, url, headers, body):
        request = urllib.request.Request(url, data=body, headers=headers, method=method)
        try:
            with urllib.request.build_opener(NoRedirects()).open(request, timeout=10) as response:
                return response.status, dict(response.headers), response.read()
        except urllib.error.HTTPError as exc:
            return exc.code, dict(exc.headers), exc.read()
        except (TimeoutError, OSError) as exc:
            raise ApiError('Borsa bağlantısı kesildi; emir sonucu doğrulanmalı.', uncertain=method != 'GET', status=503) from exc

    def _call(self, method, path, params=None, *, signed=False, market=False):
        if market:
            if method != 'GET' or path not in ('/api/v3/depth', '/api/v1/klines', '/api/v3/aggTrades'):
                raise ApiError('Piyasa endpoint erişimi engellendi.')
        elif (method, path) not in ALLOWED:
            raise ApiError('Bu endpoint spot bot kapsamı dışında.')
        if self.clock() < self.blocked_until:
            raise ApiError('Borsa hız sınırı; Retry-After süresi bekleniyor.', status=429)
        p = dict(params or {})
        headers = {'Accept': 'application/json', 'User-Agent': 'CryptoLoop-TR/1.0'}
        if signed:
            if not self._key or not self._secret:
                raise ApiError('Sunucu Binance API bilgileri yapılandırılmadı.', status=503)
            p.update(timestamp=int(self.clock() * 1000) + self.offset, recvWindow=5000)
            query = urllib.parse.urlencode(p)
            signature = hmac.new(self._secret.encode(), query.encode(), hashlib.sha256).hexdigest()
            query += '&signature=' + signature
            headers['X-MBX-APIKEY'] = self._key
        else:
            query = urllib.parse.urlencode(p)
        base = MARKET if market else REST
        url, body = base + path, None
        if method == 'GET':
            if query: url += '?' + query
        else:
            body = query.encode()
            headers['Content-Type'] = 'application/x-www-form-urlencoded'
        status, response_headers, raw = self.transport(method, url, headers, body)
        if status in (418, 429):
            normalized = {k.lower(): v for k, v in response_headers.items()}
            retry = int(normalized.get('retry-after', '60'))
            self.blocked_until = self.clock() + max(1, retry)
            raise ApiError('Borsa hız sınırı; istekler geçici durduruldu.', status=429)
        if status == 451:
            raise ApiError('Borsa sunucunun bölgesinden erişimi engelliyor (451).', status=503)
        if status >= 500:
            raise ApiError('Borsa sunucu hatası. Emir sonucu belirsiz.', uncertain=method != 'GET', status=503)
        try:
            result = json.loads(raw)
        except (ValueError, TypeError) as exc:
            raise ApiError('Borsa yanıtı doğrulanamadı.', uncertain=method != 'GET', status=503) from exc
        if status != 200 or isinstance(result, dict) and result.get('code', 0) != 0:
            code = result.get('code', status) if isinstance(result, dict) else status
            raise ApiError(f'Borsa emri/isteği reddetti (kod {code}). Bakiye, yetki ve emir filtrelerini kontrol edin.')
        if isinstance(result, dict) and 'code' in result:
            if path == '/open/v1/common/time':
                return result
            if 'data' not in result:
                raise ApiError('Borsa yanıtında veri eksik.', uncertain=method != 'GET', status=503)
            return result['data']
        return result

    def sync_time(self):
        start = int(self.clock() * 1000)
        j = self._call('GET', '/open/v1/common/time')
        end = int(self.clock() * 1000)
        self.offset = int(j['timestamp']) - (start + end) // 2
        if abs(self.offset) > 60_000:
            raise ApiError('Sunucu saati hatalı; önce saat senkronizasyonunu düzeltin.')

    def symbols(self):
        return self._call('GET', '/open/v1/common/symbols')['list']
    def account(self):
        return self._call('GET', '/open/v1/account/spot', signed=True)
    def orders(self, symbol, kind=-1):
        return self._call('GET', '/open/v1/orders', {'symbol': symbol, 'type': kind, 'limit': 1000}, signed=True)['list']
    def order(self, *, order_id=None, client_id=None):
        return self._call('GET', '/open/v1/orders/detail', {'orderId': order_id} if order_id else {'clientId': client_id}, signed=True)
    def cancel(self, *, order_id=None, client_id=None):
        return self._call('POST', '/open/v1/orders/cancel', {'orderId': order_id} if order_id else {'clientId': client_id}, signed=True)
    def trades(self, symbol, order_id=None):
        params = {'symbol': symbol, 'limit': 1000}
        if order_id: params['orderId'] = order_id
        return self._call('GET', '/open/v1/orders/trades', params, signed=True)['list']
    def place(self, params):
        return self._call('POST', '/open/v1/orders', params, signed=True)
    def listen_token(self):
        return self._call('POST', '/open/v1/user-listen-token', signed=True)
    def book(self, symbol):
        return self._call('GET', '/api/v3/depth', {'symbol': symbol.replace('_', ''), 'limit': 5}, market=True)
    def fee_asset_value(self, asset):
        rows = self._call('GET', '/api/v3/aggTrades', {'symbol': asset + 'TRY', 'limit': 1}, market=True)
        if not rows: raise ApiError('Komisyon varlığı TL değeri doğrulanamadı.', uncertain=True)
        return dec(rows[-1]['p'])
