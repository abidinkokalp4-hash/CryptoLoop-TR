# İlk hesap bağlantısı: emir göndermeden

Bu kurulum önce gerçek fiyatı, Binance TR bakiyesini, TRY komisyonunu ve açık/geçmiş emirleri **okur**. Sunucu sermaye limitleri sıfır ve `CRYPTOLOOP_LIVE_ENABLED=false` olarak oluşturulur. Kurulum borsaya emir göndermez. Anahtarları veya bot erişim token'ını sohbete/GitHub'a yazmayın.

Gerekenler: sizin kontrolünüzde Python 3.11+ ve systemd bulunan Linux sunucu, sabit çıkış IP'si, geçerli sertifikası olan HTTPS adresi, Binance TR API'sine desteklenen ağdan erişim. Sunucunun gerçekten erişebildiği doğrulanmadan bölgesini tahmin ederek seçmeyin. 451 sonucu desteklenmeyen erişimdir; VPN veya başka borsa verisiyle gizlemeyin.

## 1. Anahtar ve dosyalar

Binance TR hesabında ilk doğrulama için okuma yetkili anahtar oluşturun; para çekme kapalı ve sunucu IP kısıtlaması açık olsun. Paneldeki yetki adlarını ve kullanılabilirliğini hesabınızdan kontrol edin. Uygulama `canTrade`/`canWithdraw` hesap alanlarından API anahtarının izinlerini kanıtlayamaz. Gerçek spot yetkisi yalnızca sonraki açık canlı işlem onayıyla eklenir.

Repoyu sunucuda indirdikten sonra, repo kökünden çalıştırın. Komutlar paket satın almaz, sertifika veya hesap oluşturmaz; mevcut Linux sunucuyu hazırlar:

```sh
sudo useradd --system --home /var/lib/cryptoloop --shell /usr/sbin/nologin cryptoloop
sudo install -d -o root -g root -m 755 /opt/cryptoloop/backend
sudo install -d -o cryptoloop -g cryptoloop -m 700 /etc/cryptoloop /var/lib/cryptoloop
sudo install -o root -g root -m 644 backend/*.py /opt/cryptoloop/backend/
sudo -u cryptoloop python3 /opt/cryptoloop/backend/setup.py --output /etc/cryptoloop/bot.env --database /var/lib/cryptoloop/bot.sqlite3
```

Son komut güvenli sunucu terminalinde API anahtarını ve Secret'ı **göstermeden** alır; komut satırına veya shell geçmişine yazmayın. Mevcut yapılandırmayı değiştirmez. Anahtar henüz hazır değilse iki alanı da boş bırakabilirsiniz; özel hesap kontrolü anahtar eklenene kadar başarısız olur.

Yalnızca uygulamaya girilecek rastgele bot erişim token'ı terminalde gösterilir. Bu token da gizlidir; güvenli biçimde kendi telefonunuza aktarın. Binance Secret telefona girilmez. Yapılandırma servis kullanıcısına ait, `600` izinli normal dosya olmalıdır; geniş izin veya sembolik bağlantı reddedilir. Dosya shell ile `source` edilmez.

## 2. Hizmet ve HTTPS

```sh
sudo install -o root -g root -m 644 backend/deploy/cryptoloop.service /etc/systemd/system/cryptoloop.service
sudo systemctl daemon-reload
sudo systemctl enable --now cryptoloop
sudo systemctl status cryptoloop
```

`cryptoloop` kullanıcısı kodu değiştiremez; yalnızca `/var/lib/cryptoloop` defterine yazabilir. Servis yalnızca `127.0.0.1:8080` üzerinde dinler. 8080'i internete açmayın. `bot.env` ile kalıcı SQLite dizinini özel olarak yedekleyin; herkese açık yedeğe/loga eklemeyin.

[nginx.conf.example](nginx.conf.example) dosyasındaki `bot.example.com` ve sertifika yollarını kendi doğrulanmış HTTPS alan adınızla değiştirin. Dosya nginx `http` bağlamına (`conf.d` gibi) yüklenir. Kurulu nginx sürümünde `nginx -t` başarılı olmadan reload etmeyin. Sertifika edinme ve alan adı/DNS hesabı bu örnek tarafından otomatik yapılmaz.

## 3. Telefonda salt okuma kontrolü

1. CryptoLoop TR → **Ayarlar → Binance TR hesap bağlantısı → Güvenli sunucuyu bağla**.
2. Kendi HTTPS adresinizi ve **bot erişim token'ını** girin. Bu alan Binance API Key/Secret için değildir.
3. **Hesabı doğrula · Emir göndermez** düğmesine basın.
4. Gerçek TRY bakiyesi, hesabın TRY komisyonu, bid/ask ve spread, açık/belirsiz emir sayıları, sunucu limitleri görüntülenir. İlk kurulumda “Gerçek emirler sunucuda kapalı” yazmalıdır.

Bu kontrol `GET /v1/preflight?symbol=BTC_TRY` kullanır; borsaya yalnızca GET istekleri gönderir. Emir koymaz/iptal etmez, botu arm etmez, paper bakiyeyi değiştirmez. Hata olduğunda önceki başarılı bakiye kaldırılır. Canlıya geçişte son kontrolün aynı çift için ve en fazla beş dakika önce yapılmış olması gerekir. Başlatmada ayrıca yeni kontrol ve reconcile yapılır.

429/timeout/401/451 veya eksik TRY komisyonu doğrulama başarısı sayılmaz. Özel API ve gerçek emirler bu geliştirme ortamında uçtan uca denenmedi; sizin sunucunuzdaki okuma kontrolü ilk gerçek hesap doğrulamasıdır.

## 4. Gerçek işlem için ayrı adım

Başarılı okuma kontrolünden sonra kullanıcı **toplam sermaye, pozisyon, günlük zarar, günlük yeni alım sınırını** belirler. Onay olmadan limit seçilmez veya `true` yapılmaz.

Operatör yalnızca sunucunun özel `bot.env` dosyasında dört limiti pozitif, pozisyonu toplam sermayeden küçük/eşit olacak şekilde ayarlar. Kullanıcı onayıyla okuma/spot yetkisi ve IP kısıtı kontrol edilmiş anahtar kullanır, `CRYPTOLOOP_LIVE_ENABLED=true` yapar ve hizmeti yeniden başlatır. Eksik/sıfır limitlerle canlı başlangıç reddedilir; restart botu arm etmez.

Telefonda ayarlar sunucu sınırlarını aşmamalıdır. Yeniden hesap kontrolü, iki ayrı canlı onay kutusu ve ardından **Botu başlat** gerekir. Canlı modu açmak tek başına arm/emir göndermez. İlk gerçek deneme emri de ayrıca kullanıcı tarafından başlatılmalıdır; gerçekleşme, gerçek komisyon ve reconcile sonucunu kontrol edin. Kâr garantisi yoktur.

**Çalışma sınırı:** canlı strateji hâlen telefondadır. Ekran kilitlenince/arka plana geçince durur; açık spot pozisyon borsada kalır ve telefonun stop loss kontrolü çalışmaz. Kesintisiz gerçek para yönetimi için sunucuda bağımsız strateji/risk zamanlayıcısı ayrıca geliştirilip test edilmelidir. Bu köprü tek başına 24/7 canlı bot değildir.

Kaynak: [Binance TR resmi API](https://www.binance.tr/apidocs/), 30.09.2026.
