# CryptoLoop TR

Türkçe, Android için Binance TR **spot** işlem asistanı. Varsayılan mod paper trading'dir. Gerçek piyasa fiyatı ve emir defteri kullanılır; sahte fiyat veya otomatik canlı aktivasyon yoktur.

## Uygulama

- Portföy, kullanılabilir TL, açık pozisyon, günlük ve gerçekleşen K/Z.
- Resmi WebSocket trade / miniTicker / depth5 / kline akışı, REST ilk yükleme, yeniden bağlantı ve güncellik kontrolü.
- Mum grafiği: 1 dakika, 1 saat, 4 saat, 1 gün, 1 hafta, 1 ay. Yakınlaştırma, fiyat inceleme, AL/SAT işaretleri.
- İlk alım: gözlem süresi + geri çekilme veya konsolidasyon + yükseliş teyidi. İlk tick'te alım yapılmaz.
- Satış sonrası: geri çekilme/konsolidasyon ve teyit; son satışın üstündeki fiyat kovalanmaz.
- Komisyon, spread, slippage, lot/minimum emir kuralları, stop loss ve sermaye sınırları.
- Günlük zarar kilidi ve maksimum yeni alım sayısı; gerekli risk satışları sayıya takılmaz. Gün TSİ (UTC+3) ile hesaplanır.
- Yeni alımları durdurma, tamamen durdurma ve acil durdurma farklı işlemlerdir. Tam durdurma açık pozisyonu **satmaz**.
- Paper bakiye, geçmiş, pozisyon maliyet bazısı ve risk ayarları kalıcıdır. Açılışta bot kapalıdır.
- Uygulama arka plana geçtiğinde bot durur. Bu sürüm telefon kapalıyken veya uygulama öldürüldüğünde 24/7 çalışan bir sunucu botu değildir. Açık pozisyon borsada kalır; stop loss uygulama çalışırken uygulanır.

## Maliyet hesabı

`alış maliyet bazısı = gerçekleşen alış tutarı + alış komisyonu`

`net K/Z = miktar × bid × (1 − satış slippage) × (1 − satış komisyonu) − maliyet bazısı`

Alış ask üzerinden, satış bid üzerinden gerçekleşir. Spread/slippage zaten gerçekleşen fiyatı değiştirdiği için ikinci kez düşülmez; arayüzde maliyet katkıları ayrıca gösterilir. Paper lot miktarı aşağı yuvarlanır. Emir ilk kademedeki likiditeyi aşıyorsa hayali gerçekleşme yaratılmaz.

Canlı alış komisyonu base varlıkla kesilirse net miktar azalır; base komisyonu maliyet bazısına ikinci kez eklenmez. TRY/diğer varlık komisyonları gerçek fill kayıtlarından uzlaştırılır. Canlı satış tahmini sunucunun komisyon üst sınırını kullanır; işlem geçmişi gerçek komisyonu gösterir.

## Mimari

`TradingEngine → RiskManager → ExecutionAdapter → PaperExecution / BinanceTrExecution`

Canlı adapter yalnızca HTTPS backend'e konuşur. Binance API anahtarı ve Secret **APK'ya, Flutter kaynaklarına, SharedPreferences'a veya repoya yazılmaz**. Telefon yalnızca backend erişim token'ını Android güvenli deposunda saklar. Android otomatik yedeklemesi ve düz HTTP kapalıdır.

## Binance TR API doğrulaması

Kaynak: [Binance TR resmi API dokümanı](https://www.binance.tr/apidocs/), 30.09.2026. Global Binance özel işlem endpoint'leri kullanılmaz. Şimdilik type=1 MAIN TRY spot çiftleri desteklenir; type=2/3 için sessiz varsayım yapılmaz.

| İşlev | Resmi endpoint |
|---|---|
| Semboller / filtreler | `https://www.binance.tr/open/v1/common/symbols` |
| Sunucu saati | `/open/v1/common/time` |
| Emir defteri | `https://api.binance.me/api/v3/depth` |
| Son işlemler | `https://api.binance.me/api/v3/aggTrades` |
| Mumlar | `https://api.binance.me/api/v1/klines` |
| Piyasa WebSocket | `wss://stream-cloud.binance.tr/stream?streams=...` |
| Spot bakiye | `/open/v1/account/spot` |
| Market / limit emir | `POST /open/v1/orders` |
| Emir durum takibi | `GET /open/v1/orders/detail` |
| Emir iptali | `POST /open/v1/orders/cancel` |
| Açık / geçmiş emir | `GET /open/v1/orders` (`type=1/2/-1`) |
| Gerçekleşmeler / komisyon | `GET /open/v1/orders/trades` |

İmzalama sunucuda HMAC-SHA256, X-MBX-APIKEY, sunucu saatine göre timestamp ve 5000 ms recvWindow ile yapılır. Emirler timeout/5xx sonrası otomatik yeniden gönderilmez. Binance TR `clientId` eşsizliğini sağlamadığı için sunucuda SQLite ile kalıcı idempotency vardır. Restart canlı modu kapatır. Açık/belirsiz emirler ve hesap miktarları uzlaştırılmadan yeni işlem açılmaz.

Kâr çıkışı FOK limit fiyatı ile net kâr alt sınırını korur; stop loss koşulu ayrıca kontrol edilerek market satışına izin verilir. Borsa reddi, minimum emir/dust, ağ kesintisi veya fiyat boşluğu emrin gerçekleşmemesine yol açabilir; stop loss mutlak kayıp garantisi değildir.

## Doğrulama ve build

```sh
flutter pub get
flutter analyze
flutter test --reporter expanded
python3 -m unittest discover -s backend/tests -v
flutter build apk --release
python3 scripts/verify_apk.py build/app/outputs/flutter-apk/app-release.apk
```

Flutter 3.47.5 / Java 17 sabitlenmiştir. Android projesi repodadır; CI her seferinde örnek uygulama üretmez. Actions APK'yı ve QA raporlarını ayrı artifact olarak verir. Halka açık piyasa probe'u ağ/bölge kısıtlamasını raporlar; gerçek fiyat alınamamışsa başarı diye işaretlemez.

Bu özel kullanım APK'sı release modunda derlenir, Android debug sertifikasıyla imzalanır. Mağaza dağıtımı ve kalıcı güncelleme imzası için kullanıcıya ait release keystore sonradan güvenli CI secret olarak yapılandırılmalıdır. Eski prototipin farklı sertifikası varsa Android üzerine kurulum yerine önce eski sürümün kaldırılmasını ister.

## Canlıya geçmeden önce

1. [backend/README.md](backend/README.md) uyarınca operatörün kontrolündeki bir HTTPS sunucuyu kurun. Varsayılan canlı bayrağı kapalıdır.
2. Binance TR API anahtarını sunucunun secret/env deposuna ekleyin: yalnızca okuma + spot; **para çekme kapalı**, sunucu IP kısıtlaması açık. Anahtarı sohbetten paylaşmayın.
3. Sunucu sermaye limitlerini doğrulayın; anahtar yetkilerini Binance TR panelinden kontrol edin.
4. Telefonda yalnızca HTTPS adresi ve backend kontrol token'ını bağlayın. Canlı mod uyarısını açıkça onaylayın.
5. Bakiye/emir reconciliation ve kullanıcı onayından sonra düşük sermayeyle gerçek fill/komisyon kontrolü yapın.

Geliştirme/test sürecinde gerçek anahtar bağlanmaz ve gerçek para emri gönderilmez. Live private API uçtan uca testi, bu kurulum ve ayrı kullanıcı onayından sonra yapılır.
