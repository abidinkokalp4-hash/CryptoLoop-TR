# Güvenli spot signing backend

Python 3.11+ standart kütüphanesi yeterli. Sunucu kişisel, tek hesap içindir. Genel çok kullanıcılı servis olarak yayımlamayın.

İlk gerçek hesap bağlantısı için [emir göndermeyen kurulum rehberi](deploy/README.md) ve `setup.py` vardır. Sunucu/anahtar bağlantısı hazır olmadan canlı işlem açılmaz.

```sh
cd backend
python3 server.py
```

Environment/secret deposunda aşağıdaki isimleri yapılandırın. Gerçek değerleri GitHub'a veya sohbete koymayın:

| Değişken | Açıklama |
|---|---|
| `CRYPTOLOOP_CONTROL_TOKEN` | Rastgele en az 32 karakter. Telefonda Android güvenli deposuna kaydedilir. |
| `BINANCE_TR_API_KEY` | Okuma ve spot yetkili Binance TR anahtarı |
| `BINANCE_TR_API_SECRET` | Yalnızca sunucu secret deposu |
| `CRYPTOLOOP_LIVE_ENABLED` | Varsayılan kapalı. Açık kullanıcı onayından sonra `true`. |
| `CRYPTOLOOP_MAX_CAPITAL_TRY` | Sunucu hard cap, varsayılan **0**; kullanıcı belirler |
| `CRYPTOLOOP_MAX_POSITION_TRY` | Pozisyon cap, varsayılan **0**; kullanıcı belirler |
| `CRYPTOLOOP_DAILY_LOSS_TRY` | Günlük zarar, varsayılan **0**; kullanıcı belirler |
| `CRYPTOLOOP_MAX_ENTRIES` | Günlük alım, varsayılan **0**; kullanıcı belirler |
| `CRYPTOLOOP_DB` | Kalıcı SQLite yolu, varsayılan data/bot.sqlite3 |
| `CRYPTOLOOP_BIND` / `CRYPTOLOOP_PORT` | Varsayılan 127.0.0.1 / 8080 |
| `CRYPTOLOOP_CONFIG` | İsteğe bağlı, servis kullanıcısına ait 600 izinli özel dosya. Dosya değerleri env'den önceliklidir. |

Kontrol token'ını güvenli sunucu terminalinde `python3 -c 'import secrets; print(secrets.token_urlsafe(48))'` ile üretin. API Secret'ı telefona girmeyin. Ortam dosyası izinlerini 600 yapın ve yalnızca servis kullanıcısına açın.

TLS reverse proxy arkasında çalıştırın, 8080 portunu internete açmayın. İstek boyutu 16 KiB ile sınırlıdır. Gövde/header/imzalı query loglanmaz. TLS, rate limiting ve erişim loglarında Authorization maskelemesi proxy'de de etkin olmalı. Örnek nginx konfigürasyonu:

```nginx
server {
    listen 443 ssl;
    server_name bot.example.com;
    ssl_certificate /etc/ssl/bot/fullchain.pem;
    ssl_certificate_key /etc/ssl/bot/privkey.pem;
    client_max_body_size 16k;
    location /v1/ {
        proxy_pass http://127.0.0.1:8080;
        proxy_read_timeout 50s;
    }
}
```

Kalıcı `data/` dizinini koruyun ve yedekleyin. Defter silinirse önceki bot pozisyonu otomatik benimsenmez; eski bot emri/pozisyonu operatör tarafından incelenmelidir. Başka uygulama/manuel emirleri aynı bot bakiyesiyle eşzamanlı kullanmayın. Reconcile, sadece bot defterindeki pozisyonu takip eder; hesabınızdaki diğer coinleri sahiplenmez veya satmaz.

Özel endpoint'ler sunucu allowlist'iyle sınırlandırılmıştır. Para çekme/futures/margin yöntemleri yoktur. `canWithdraw` hesap alanı API anahtarının withdrawal iznini tek başına kanıtlamaz; Binance TR anahtar panelinde bunu ayrıca kapatın.

`POST /v1/arm` açık onay ve risk limitleri gerektirir. Sunucu restart'ta disarm olur. `POST /v1/halt` önce yeni işlemleri durdurur, sonra yalnızca bot emirlerinin kalanını iptal etmeyi dener; mevcut kriptoyu marketten satmaz. Uçuşta olan bir emir sonradan gerçekleşebilir; uzlaştırma kesin sonucu belirler.

`GET /v1/reconcile`, bakiye/açık emir/gerçekleşme bazında bot pozisyonunu doğrular. `GET /v1/orders`, `/v1/order`, `/v1/trades` ile okuma altyapısı hazırdır. `/v1/cancel` yalnızca bot defterinde olan emri iptal eder. Phone strategy foreground'da çalışır; backend 24/7 strateji scheduler değildir.

`GET /v1/preflight`, canlı işlem kapalıyken de fiyat, bakiye, TRY komisyonu, açık/geçmiş emirler ve gerçekleşme erişimini kontrol eder. Yalnızca borsa GET istekleri gönderir; botu arm etmez, emir göndermez veya iptal etmez. Rapor key/withdrawal izinlerini kanıtladığını iddia etmez. Sunucu canlı bayrağı tek başına yeterli değildir; dört pozitif risk limiti de açıkça yapılandırılmalıdır.

Normal satış için FOK limit ve komisyon üst sınırı kullanılır. Kısmi gerçekleşme, base/quote/diğer varlık komisyonu, rate limit ve bilinmeyen emir durumu güvenli deftere işlenir. Kabul edilmiş bir emir tam fill olmadan pozisyon olarak varsayılmaz. Binance TR clientId alanı eşsiz değildir; aynı intent'in tekrar gönderilmesi SQLite kaydıyla engellenir.

Testler gerçek ağ veya gerçek anahtar kullanmaz:

```sh
python3 -m unittest discover -s tests -v
```
