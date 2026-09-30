"""Run interactively on the operator's server, never in chat or CI.

Creates a private read-only configuration. Refuses to overwrite existing secrets.
"""
import argparse
import getpass
import os
from pathlib import Path
import secrets
import sys

def write_config(path, api_key, api_secret, *, database='data/bot.sqlite3'):
    for value in (api_key, api_secret, str(database)):
        if any(c in value for c in ('\n', '\r', '\x00')):
            raise ValueError('Tek satırlık değer gerekli.')
    if bool(api_key) != bool(api_secret): raise ValueError('API anahtarı ve Secret birlikte girilmeli.')
    token = secrets.token_urlsafe(48)
    values = {'CRYPTOLOOP_CONTROL_TOKEN': token,
        'BINANCE_TR_API_KEY': api_key, 'BINANCE_TR_API_SECRET': api_secret,
        'CRYPTOLOOP_LIVE_ENABLED': 'false', 'CRYPTOLOOP_MAX_CAPITAL_TRY': '0',
        'CRYPTOLOOP_MAX_POSITION_TRY': '0', 'CRYPTOLOOP_DAILY_LOSS_TRY': '0',
        'CRYPTOLOOP_MAX_ENTRIES': '0', 'CRYPTOLOOP_DB': str(database),
        'CRYPTOLOOP_BIND': '127.0.0.1', 'CRYPTOLOOP_PORT': '8080'}
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'w', encoding='utf-8') as output:
        output.write('# CryptoLoop TR: sadece sunucuda, GitHub ve sohbet disinda.\n')
        output.write(''.join(f'{key}={value}\n' for key, value in values.items()))
        output.flush(); os.fsync(output.fileno())
    return token

def main():
    parser = argparse.ArgumentParser(description='Sunucuda gizli, emirleri kapalı ilk kurulum.')
    parser.add_argument('--output', default='.env')
    parser.add_argument('--database', default='data/bot.sqlite3')
    args = parser.parse_args()
    if not sys.stdin.isatty() or not sys.stderr.isatty():
        raise SystemExit('Gizli giriş için doğrudan güvenli sunucu terminali gerekli.')
    if Path(args.output).exists(): raise SystemExit('Mevcut dosya değiştirilmez; önce mevcut kurulumu kontrol edin.')
    print('Binance TR Secret yalnızca bu sunucuda saklanır. İlk kurulum emir göndermez.')
    key = getpass.getpass('Binance TR API anahtarı (yoksa boş bırakın): ').strip()
    secret = getpass.getpass('Binance TR API Secret (yoksa boş bırakın): ').strip()
    try:
        token = write_config(args.output, key, secret, database=args.database)
    except (OSError, ValueError):
        raise SystemExit('Kurulum kaydedilemedi. Dosya izinlerini ve anahtar çiftini kontrol edin.')
    print('Özel yapılandırma kaydedildi. Canlı işlem KAPALI; sermaye sınırları sıfır.')
    print('Yalnızca uygulamanın Güvenli backend bağlantısı alanına girilecek erişim anahtarı:')
    print(token)
    print('Bu erişim anahtarını da sohbete, GitHub’a veya loglara kopyalamayın.')

if __name__ == '__main__': main()
