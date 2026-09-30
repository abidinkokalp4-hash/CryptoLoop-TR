# CryptoLoop TR

Binance TR spot piyasasi icin paper-trading ile baslayan otomatik strateji projesi.

## V1
- Gercek piyasa verisi, sanal bakiye
- Durum makinesi: BEKLE -> AL -> KAR BEKLE -> SAT -> GERI GIRIS BEKLE
- Net kar hesabi: alis/satis ucretleri ve spread hesaba katilir
- Satis sonrasi fiyat yukselmeye devam ederse pesinden alinmaz
- Geri cekilme veya yataylasma + teyit sonrasi yeniden giris
- Stop-loss, gunluk zarar limiti, maksimum pozisyon ve acil durdurma
- Tum islemler ve strateji kararlari kaydedilir

## Guvenlik
API anahtari ve secret repoya yazilmayacak. Gercek emir modu V1'de kapali olacak.
