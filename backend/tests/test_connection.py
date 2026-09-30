import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import sys
import tempfile
import threading
import unittest
from urllib.parse import urlsplit, parse_qs

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from binance_tr import ApiError, BinanceTrClient, dec
from config import load_config, live_settings
from server import Server
from service import BotService
from setup import write_config
from test_backend import FakeClient

class ReadOnlyClient(FakeClient):
    def place(self, _): raise AssertionError('Read-only check placed an order')
    def cancel(self, **_): raise AssertionError('Read-only check cancelled an order')
    def listen_token(self): raise AssertionError('Read-only check used a POST')

class ConnectionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.client = ReadOnlyClient()
        self.service = BotService(self.client, self.temp.name+'/bot.sqlite3', enabled=False,
            max_capital=0, max_position=0, daily_loss=0, max_entries=0)
    def tearDown(self): self.service.db.close(); self.temp.cleanup()
    def test_read_only_check_reads_real_fee_and_balance_without_arming(self):
        report = self.service.preflight('BTC_TRY')
        self.assertTrue(report['readOnly']); self.assertFalse(report['armed'])
        self.assertFalse(report['liveEnabled']); self.assertFalse(self.service.armed)
        self.assertEqual(report['account']['availableTry'], '1000')
        self.assertEqual(dec(report['account']['feePct']), dec('0.15'))
        self.assertEqual(report['serverLimits']['maxCapital'], '0')
        self.assertTrue(report['reconciliation']['safe'])
        self.assertEqual(self.service._rows(), [])
    def test_key_permissions_are_never_inferred_from_account_flags(self):
        original = self.client.account
        self.client.account = lambda: dict(original(), canWithdraw=0, canTrade=1)
        report = self.service.preflight('BTC_TRY')
        self.assertFalse(report['keyPermissionsVerified'])
        self.assertFalse(report['withdrawalPermissionVerified'])
        self.assertTrue(report['account']['canTrade'])
    def test_open_orders_are_reported_but_never_cancelled(self):
        self.client.open = [{'orderId':'outside-bot'}]
        report = self.service.preflight('BTC_TRY')
        self.assertFalse(report['reconciliation']['safe'])
        self.assertEqual(report['reconciliation']['openOrderCount'], 1)
    def test_invalid_book_or_missing_fiat_fee_fails_check(self):
        self.client.bid = -1
        with self.assertRaises(ApiError): self.service.preflight('BTC_TRY')
        self.client.bid = 100
        self.client.account = lambda: {'canTrade':1, 'accountAssets':[]}
        with self.assertRaises(ApiError): self.service.preflight('BTC_TRY')
        self.assertFalse(self.service.armed)
    def test_every_exchange_request_is_get_even_with_trading_capability(self):
        calls = []
        def transport(method, url, headers, body):
            calls.append((method, url, headers, body))
            self.assertEqual(method, 'GET'); self.assertIsNone(body)
            path = urlsplit(url).path
            if path == '/open/v1/common/time': data = {'code':0,'timestamp':1000000}
            elif path == '/open/v1/common/symbols': data = {'code':0,'data':{'list':self.client.symbols()}}
            elif path == '/api/v3/depth': data = self.client.book('BTC_TRY')
            elif path == '/open/v1/account/spot': data = {'code':0,'data':self.client.account()}
            elif path in ('/open/v1/orders', '/open/v1/orders/trades'): data = {'code':0,'data':{'list':[]}}
            else: self.fail('Unexpected exchange endpoint: '+path)
            return 200, {}, json.dumps(data).encode()
        client = BinanceTrClient('test-only-key','test-only-secret',transport,clock=lambda:1000)
        self.service.client = client
        report = self.service.preflight('BTC_TRY')
        self.assertTrue(report['readOnly']); self.assertEqual(len(calls), 7)
        self.assertNotIn('orderId', parse_qs(urlsplit(calls[-1][1]).query))
        self.assertEqual(self.service._rows(), [])
    def test_http_preflight_requires_token_and_disabled_server_rejects_mutations(self):
        server = Server(('127.0.0.1', 0), self.service, 'test-only-control-token-with-32-characters')
        thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
        def request(method, path, auth=True):
            connection = http.client.HTTPConnection(*server.server_address, timeout=3)
            headers = {'Content-Type':'application/json'}
            if auth: headers['Authorization'] = 'Bearer '+server.control_token
            connection.request(method, path, body='{}' if method=='POST' else None, headers=headers)
            response = connection.getresponse(); status = response.status
            payload = json.loads(response.read()); connection.close(); return status, payload
        try:
            self.assertEqual(request('GET','/v1/preflight',False)[0], 401)
            status, payload = request('GET','/v1/preflight?symbol=BTC_TRY')
            self.assertEqual(status, 200); self.assertTrue(payload['readOnly'])
            self.assertEqual(request('POST','/v1/arm')[0], 403)
            self.assertEqual(request('POST','/v1/cancel')[0], 403)
            self.assertFalse(self.service.armed)
        finally:
            server.shutdown(); server.server_close(); thread.join(timeout=3)

class ConfigTests(unittest.TestCase):
    def setUp(self): self.temp = tempfile.TemporaryDirectory(); self.path = Path(self.temp.name)/'bot.env'
    def tearDown(self): self.temp.cleanup()
    def test_setup_stores_secrets_owner_only_with_zero_caps_and_live_disabled(self):
        token = write_config(self.path, 'test-only-key', 'test-only-secret')
        self.assertGreaterEqual(len(token), 32)
        self.assertEqual(self.path.stat().st_mode & 0o777, 0o600)
        config = load_config(self.path, {})
        self.assertEqual(config['BINANCE_TR_API_SECRET'], 'test-only-secret')
        settings = live_settings(config)
        self.assertFalse(settings['enabled']); self.assertEqual(settings['max_capital'], 0)
        self.assertEqual(settings['max_entries'], 0)
        with self.assertRaises(FileExistsError): write_config(self.path, 'new-test-key', 'new-test-secret')
        self.assertEqual(load_config(self.path,{})['CRYPTOLOOP_CONTROL_TOKEN'], token)
    def test_permissions_and_symlinks_are_rejected_without_echoing_secrets(self):
        write_config(self.path, 'test-only-key', 'test-only-secret'); self.path.chmod(0o644)
        with self.assertRaises(ValueError) as exc: load_config(self.path,{})
        self.assertNotIn('test-only-secret', str(exc.exception))
        self.path.chmod(0o600)
        link = Path(self.temp.name)/'link.env'; link.symlink_to(self.path)
        with self.assertRaises(OSError): load_config(link,{})
    def test_secret_config_never_executes_shell_or_leaks_malformed_values(self):
        self.path.write_text('BINANCE_TR_API_SECRET=$(never-execute)\n'); self.path.chmod(0o600)
        self.assertEqual(load_config(self.path,{})['BINANCE_TR_API_SECRET'], '$(never-execute)')
        self.path.write_text('UNKNOWN=test-only-secret\n')
        with self.assertRaises(ValueError) as exc: load_config(self.path,{})
        self.assertNotIn('test-only-secret', str(exc.exception))
        self.path.write_text('CRYPTOLOOP_LIVE_ENABLED=false\nCRYPTOLOOP_LIVE_ENABLED=true\n')
        with self.assertRaises(ValueError): load_config(self.path,{})
    def test_live_flag_alone_never_enables_unbounded_trading(self):
        self.assertFalse(live_settings({})['enabled'])
        with self.assertRaises(ValueError): live_settings({'CRYPTOLOOP_LIVE_ENABLED':'true'})
        config = {'CRYPTOLOOP_LIVE_ENABLED':'true','CRYPTOLOOP_MAX_CAPITAL_TRY':'200',
            'CRYPTOLOOP_MAX_POSITION_TRY':'50','CRYPTOLOOP_DAILY_LOSS_TRY':'10','CRYPTOLOOP_MAX_ENTRIES':'2'}
        self.assertTrue(live_settings(config)['enabled'])
        for key, value in [('CRYPTOLOOP_MAX_POSITION_TRY','201'),('CRYPTOLOOP_MAX_ENTRIES','1.5'),
                           ('CRYPTOLOOP_LIVE_ENABLED','yes')]:
            with self.assertRaises(ValueError): live_settings(dict(config, **{key:value}))
    def test_server_file_disabled_flag_wins_over_environment(self):
        write_config(self.path,'test-only-key','test-only-secret')
        config = load_config(self.path, {'CRYPTOLOOP_LIVE_ENABLED':'true'})
        self.assertFalse(live_settings(config)['enabled'])
    def test_setup_rejects_newline_injection_before_creating_file(self):
        with self.assertRaises(ValueError): write_config(self.path,'test-only-key','x\nCRYPTOLOOP_LIVE_ENABLED=true')
        self.assertFalse(self.path.exists())

class RedirectTests(unittest.TestCase):
    def test_exchange_redirect_never_forwards_key_or_signature(self):
        received = []
        class Destination(BaseHTTPRequestHandler):
            def log_message(self, *_): pass
            def do_GET(self):
                received.append((self.path, dict(self.headers)))
                self.send_response(200); self.end_headers(); self.wfile.write(b'{}')
        destination = ThreadingHTTPServer(('127.0.0.1',0), Destination)
        class Origin(BaseHTTPRequestHandler):
            def log_message(self, *_): pass
            def do_GET(self):
                self.send_response(302)
                self.send_header('Location', f'http://127.0.0.1:{destination.server_port}/capture')
                self.end_headers()
        origin = ThreadingHTTPServer(('127.0.0.1',0), Origin)
        threads = [threading.Thread(target=server.serve_forever,daemon=True) for server in (origin,destination)]
        for thread in threads: thread.start()
        try:
            status, _, _ = BinanceTrClient._transport('GET',
                f'http://127.0.0.1:{origin.server_port}/signed?signature=test-only-signature',
                {'X-MBX-APIKEY':'test-only-key'}, None)
            self.assertEqual(status, 302)
            self.assertEqual(received, [])
        finally:
            for server in (origin,destination): server.shutdown(); server.server_close()
            for thread in threads: thread.join(timeout=3)

if __name__ == '__main__': unittest.main()
