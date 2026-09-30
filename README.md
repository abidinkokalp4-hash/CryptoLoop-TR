# CryptoLoop TR

Türkçe, Android için Binance TR **spot** işlem asistanı. Varsayılan mod paper trading'dir. Gerçek piyasa fiyatı ve emir defteri kullanılır; sahte fiyat veya otomatik canlı aktivasyon yoktur.

## Uygulama

- Varsayılan 10 coin izleme listesi; ayarlardan en fazla 20 resmi MAIN TRY spot çift seçilebilir. Uygun sinyal varsa birden fazla pozisyon açılır; 10 coin seçmek 10 coin’i zorunlu satın almak değildir.
- Coin başına bağımsız gözlem, stop loss, net kâr çıkışı ve re-entry geçmişi. Grafik seçimi işlemleri/pozisyonları değiştirmez.
- Tek ortak TL bakiye, bütün pozisyonların alış komisyonu dahil toplam sermaye sınırı, coin başına tutar ve eşzamanlı pozisyon sınırı. Günlük zarar ve alım sayısı bütün coin’lerde ortaktır.
- Portföy, kullanılabilir TL, bütün açık pozisyonlar, toplam günlük ve gerçekleşen K/Z; işlem geçmişinde coin filtresi.
- Birleşik resmi WebSocket bağlantısında coin adına göre yönlendirilen trade / miniTicker / depth5 / kline akışı, REST ilk yükleme, yeniden bağlantı ve güncellik kontrolü.
- Mum grafiği: 1 dakika, 1 saat, 4 saat, 1 gün, 1 hafta, 1 ay. Yakınlaştırma, fiyat inceleme, AL/SAT işaretleri.
- İlk alım: gözlem süresi + geri çekilme veya konsolidasyon + yükseliş teyidi. İlk tick'te alım yapılmaz.
- Satış sonrası: geri çekilme/konsolidasyon ve teyit; son satışın üstündeki fiyat kovalanmaz.
- Komisyon, spread, slippage, lot/minimum emir kuralları, stop loss ve sermaye sınırları.
- Günlük zarar kilidi ve maksimum yeni alım sayısı; gerekli risk satışları sayıya takılmaz. Gün TSİ (UTC+3) ile hesaplanır.
- Yeni alımları durdurma, tamamen durdurma ve acil durdurma farklı işlemlerdir. Tam durdurma açık pozisyonu **satmaz**.
- Paper bakiye, geçmiş, bütün pozisyonların maliyet bazısı ve coin başına satış sonrası bekleme bilgisi kalıcıdır. Şema v2 tek coin kayıtları v3 çok coin defterine bakiyeyi çoğaltmadan taşınır. Açılışta bot kapalıdır.
- **Paper bot**, kullanıcı başlattıktan sonra Android bildirimi ve aynı trading engine ile ekran kilitliyken/arka planda çalışır. Bildirimde **BOTU DURDUR** kontrolü vardır. Başlatma için bildirim izni gerekir; izin veya servis hatasında bot başlamaz.
- Tek bir Flutter engine saklanır; uygulamaya dönüşte ikinci bot veya çift emir üretilmez. Servis heartbeat ile motorun yanıtını kontrol eder, wake lock yalnızca bot çalışırken tutulur. Android süreci sonlandırırsa/telefon yeniden başlarsa bot otomatik açılmaz. Paper kayıtları geri yüklenir; kullanıcı tekrar başlatır.
- **Canlı bot** arka plana geçince güvenli şekilde durmaya devam eder. Backend şu an güvenli emir köprüsüdür, 24/7 sunucu strateji zamanlayıcısı değildir. Açık pozisyon borsada kalır; stop loss telefon motoru çalışırken uygulanır. Telefon kapalıyken kesintisiz canlı işlem için ayrı sunucu motoru gereklidir.
- Ayarlarda **Hesabı doğrula · Emir göndermez** ile gerçek TRY bakiyesi, TRY komisyonu, fiyat/spread ve açık/belirsiz emirler salt okuma olarak kontrol edilir. Bu adım paper hesabını veya işlem modunu değiştirmez. Canlı mod seçimi de tek başına arm etmez; bot ayrıca başlatılır.
- Telefonun pil kısıtlamaları/üretici süreç yönetimi servisi durdurabilir; cihazda uygulamanın bildirim ve pil ayarlarını kontrol edin. Ağ kesintisinde eski fiyatla paper işlem yapılmaz. Herhangi bir açık pozisyonun fiyatı eskimişse yeni alımlar bütün coin’lerde bekler; güncel fiyatı olan pozisyonun risk çıkışı engellenmez.

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

Android API 34 ve 36 emülatörlerinde ayrıca aynı motorun arka planda paper satış yapması, gerçek foreground servis/wake lock, bildirimden durdurma, kayıtların korunması ve üretim release APK'nın açılışı kontrol edilir. Bu testlerdeki fiyatlar yalnızca test APK'sına ait fixture'dır; gerçek Binance fiyat erişimi veya canlı emir doğrulaması sayılmaz. Release uygulaması kendiliğinden bot başlatmadan PAPER modunda açılmalıdır.

Bağlantı hatasının nedeni ve endpoint, yeniden bağlantı mesajı değişse de ekranda kalır. `market-probe.json` son hata/zaman/endpoint ve son güncel fiyat zamanını içerir. HTTP 451 bölge kısıtlaması başka borsa fiyatı ile örtülmez; desteklenen ağda gerçek veri erişimi ayrıca doğrulanmalıdır.

Bu özel kullanım APK'sı release modunda derlenir, Android debug sertifikasıyla imzalanır. Mağaza dağıtımı ve kalıcı güncelleme imzası için kullanıcıya ait release keystore sonradan güvenli CI secret olarak yapılandırılmalıdır. Eski prototipin farklı sertifikası varsa Android üzerine kurulum yerine önce eski sürümün kaldırılmasını ister.

## Canlıya geçmeden önce

1. [Salt okuma kurulum rehberi](backend/deploy/README.md) uyarınca sizin kontrolünüzdeki HTTPS sunucuyu hazırlayın. Varsayılan canlı bayrağı kapalı, sunucu sermaye limitleri **sıfırdır**.
2. Önce okuma anahtarını sunucunun özel deposuna ekleyin; **para çekme kapalı**, sunucu IP kısıtlaması açık olsun. Secret'ı sohbetten paylaşmayın veya telefona girmeyin.
3. Telefonda yalnızca HTTPS adresini ve backend token'ını bağlayıp **Hesabı doğrula · Emir göndermez** ile gerçek fiyat/bakiye/TRY komisyonunu kontrol edin.
4. Kullanıcı toplam/pozisyon sermayesi ve günlük zarar/alım sınırlarını belirledikten ve ayrı onay verdikten sonra sunucuda bu limitleri ve okuma/spot anahtarını yapılandırın. Canlı bayrağı `true` yapılınca da bot kendiliğinden arm olmaz.
5. Uygulama ayarlarını sunucu sınırlarına eşitleyin, güncel hesap kontrolü ve iki canlı onay kutusunu tamamlayın. **Botu başlat** ayrı adımdır; başlangıçta tekrar hesap kontrolü ve reconcile yapılır. Kullanıcı tarafından başlatılan ilk gerçek işlemin fill/komisyon sonucunu doğrulayın.

Geliştirme/test sürecinde gerçek anahtar bağlanmaz ve gerçek para emri gönderilmez. Live private API uçtan uca testi, bu kurulum ve ayrı kullanıcı onayından sonra yapılır.
