"""Owner-only server configuration. Secret values are never printed or executed."""
import os
import re
import stat
from binance_tr import dec

NAMES = {
    'CRYPTOLOOP_CONTROL_TOKEN', 'BINANCE_TR_API_KEY', 'BINANCE_TR_API_SECRET',
    'CRYPTOLOOP_LIVE_ENABLED', 'CRYPTOLOOP_MAX_CAPITAL_TRY',
    'CRYPTOLOOP_MAX_POSITION_TRY', 'CRYPTOLOOP_DAILY_LOSS_TRY',
    'CRYPTOLOOP_MAX_ENTRIES', 'CRYPTOLOOP_DB', 'CRYPTOLOOP_BIND', 'CRYPTOLOOP_PORT',
}

def load_config(path=None, environ=None):
    env = os.environ if environ is None else environ
    result = {key: env[key] for key in NAMES if key in env}
    path = path or env.get('CRYPTOLOOP_CONFIG')
    if not path: return result
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    with os.fdopen(fd, 'r', encoding='utf-8') as source:
        info = os.fstat(source.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_mode & 0o077 or info.st_uid != os.geteuid():
            raise ValueError('Yapılandırma normal dosya, servis kullanıcısına ait ve 600 izinli olmalı.')
        if info.st_size > 16384: raise ValueError('Yapılandırma dosyası çok büyük.')
        seen = set()
        for line in source:
            line = line.rstrip('\n')
            if not line or line.startswith('#'): continue
            key, sep, value = line.partition('=')
            if sep != '=' or key not in NAMES or key in seen or '\r' in value or '\x00' in value:
                raise ValueError('Yapılandırma biçimi doğrulanamadı; değerler gösterilmez.')
            seen.add(key); result[key] = value
    return result

def live_settings(config):
    flag = config.get('CRYPTOLOOP_LIVE_ENABLED', 'false')
    if flag not in ('true', 'false'): raise ValueError('Canlı işlem bayrağı true/false olmalı.')
    capital = dec(config.get('CRYPTOLOOP_MAX_CAPITAL_TRY', '0'))
    position = dec(config.get('CRYPTOLOOP_MAX_POSITION_TRY', '0'))
    loss = dec(config.get('CRYPTOLOOP_DAILY_LOSS_TRY', '0'))
    entries = config.get('CRYPTOLOOP_MAX_ENTRIES', '0')
    if not re.fullmatch(r'[0-9]+', str(entries)): raise ValueError('Günlük alım sınırı tam sayı olmalı.')
    entries = int(entries)
    if flag == 'true' and (not 0 < position <= capital or loss <= 0 or entries < 1):
        raise ValueError('Canlı işlem için toplam sermaye, pozisyon, günlük zarar ve alım sınırlarını açıkça belirleyin.')
    return dict(enabled=flag == 'true', max_capital=capital, max_position=position,
                daily_loss=loss, max_entries=entries)
