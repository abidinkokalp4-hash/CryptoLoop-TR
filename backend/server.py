"""Run behind TLS reverse proxy. Default loopback bind; live execution disabled."""
import hmac
import json
import os
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit, parse_qs
from binance_tr import ApiError, BinanceTrClient
from config import load_config, live_settings
from service import BotService

class Handler(BaseHTTPRequestHandler):
    server_version = 'CryptoLoop'
    def log_message(self, *_):
        pass  # Never log bearer, signed query strings, bodies or credentials.
    def reply(self, code, payload):
        data = json.dumps(payload, ensure_ascii=False, allow_nan=False).encode()
        self.send_response(code)
        self.send_header('Content-Type', 'application/json; charset=utf-8')
        self.send_header('Content-Length', str(len(data)))
        self.send_header('Cache-Control', 'no-store')
        self.send_header('X-Content-Type-Options', 'nosniff')
        self.end_headers()
        self.wfile.write(data)
    def dispatch(self, method):
        expected = 'Bearer ' + self.server.control_token
        if not hmac.compare_digest(self.headers.get('Authorization', ''), expected):
            self.reply(401, {'error': 'Yetkisiz istek.'}); return
        try:
            path = urlsplit(self.path); query = parse_qs(path.query)
            symbol = query.get('symbol', ['BTC_TRY'])[0]
            symbols = query['symbols'][0].split(',') if 'symbols' in query else None
            service = self.server.service
            if method == 'GET':
                if path.path == '/v1/health': result = service.health()
                elif path.path == '/v1/preflight': result = service.preflight_many(symbols) if symbols is not None else service.preflight(symbol)
                elif path.path == '/v1/reconcile': result = service.reconcile_many(symbols) if symbols is not None else service.reconcile(symbol)
                elif path.path == '/v1/orders':
                    kind = {'open': 1, 'history': 2, 'all': -1}.get(query.get('kind', ['all'])[0], -1)
                    service._rules(symbol); result = {'orders': service.client.orders(symbol, kind)}
                elif path.path == '/v1/order': result = {'order': service.client.order(order_id=query.get('orderId', [None])[0])}
                elif path.path == '/v1/trades': result = {'trades': service.client.trades(symbol, query.get('orderId', [''])[0])}
                else: self.reply(404, {'error': 'Böyle bir işlem yok.'}); return
            else:
                length = int(self.headers.get('Content-Length', '0'))
                if length < 2 or length > 16384 or self.headers.get('Content-Type', '').split(';')[0] != 'application/json':
                    raise ApiError('JSON istek boyutu/biçimi geçersiz.')
                def invalid(_): raise ValueError('Non-finite JSON')
                body = json.loads(self.rfile.read(length), parse_constant=invalid)
                if not isinstance(body, dict): raise ApiError('JSON nesnesi gerekli.')
                if path.path == '/v1/arm': result = service.arm(body)
                elif path.path == '/v1/halt': result = service.halt()
                elif path.path == '/v1/execute': result = service.execute(body)
                elif path.path == '/v1/cancel':
                    if not service.enabled: raise ApiError('Salt okuma kurulumunda emir iptali kapalı.', status=403)
                    with service.lock:
                        row = service.db.execute('SELECT * FROM intents WHERE id=?', (body.get('intentId'),)).fetchone()
                        if row is None: raise ApiError('Bota ait emir bulunamadı.')
                        result = {'order': service.client.cancel(order_id=row['order_id'], client_id=row['id'])}
                else: self.reply(404, {'error': 'Böyle bir işlem yok.'}); return
            self.reply(200, result)
        except ApiError as exc:
            self.reply(exc.status, {'error': str(exc), 'uncertain': exc.uncertain})
        except (ValueError, KeyError, TypeError, IndexError):
            self.reply(400, {'error': 'İstek veya borsa verisi doğrulanamadı.'})
        except Exception:
            self.server.service.armed = False
            self.reply(503, {'error': 'Sunucu işlemi doğrulanamadı; bot durduruldu.', 'uncertain': True})
    def do_GET(self): self.dispatch('GET')
    def do_POST(self): self.dispatch('POST')

class Server(ThreadingHTTPServer):
    daemon_threads = True
    def __init__(self, address, service, control_token):
        if len(control_token) < 32: raise ValueError('Backend control token must have at least 32 characters')
        self.service, self.control_token = service, control_token
        super().__init__(address, Handler)

if __name__ == '__main__':
    os.umask(0o077)
    config = load_config()
    token = config.get('CRYPTOLOOP_CONTROL_TOKEN', '')
    if len(token) < 32: raise SystemExit('Sunucu erişim anahtarı eksik veya kısa.')
    settings = live_settings(config)
    database = config.get('CRYPTOLOOP_DB', 'data/bot.sqlite3')
    Path(database).parent.mkdir(parents=True, exist_ok=True)
    client = BinanceTrClient(config.get('BINANCE_TR_API_KEY', ''), config.get('BINANCE_TR_API_SECRET', ''))
    service = BotService(client, database, **settings)
    os.chmod(database, 0o600)
    Server((config.get('CRYPTOLOOP_BIND', '127.0.0.1'), int(config.get('CRYPTOLOOP_PORT', '8080'))), service, token).serve_forever()
