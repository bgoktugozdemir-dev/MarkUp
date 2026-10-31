# MarkUp: sahip tarafından yapılacak imzalama ve yayın hazırlığı

Kod ve workflow hazırlığı hesap erişimi olmadan yapılabilir. Gerçek Developer ID
imzası, Apple notarization ve N → N+1 kurulum testi için sizin Apple/GitHub
hesaplarınızdaki işlemler gerekir. Özel anahtarları, `.p12`/`.p8` dosyalarını ve
parolaları sohbete göndermeyin. `main` üzerindeki bir `vX.Y.Z` tag'i, `release`
environment onayından sonra imzalı/notarized asset'leri üretir ve GitHub Release'i
(ZIP, `appcast.xml`, `SHA256SUMS`, `release-evidence.json`) otomatik yayınlar.
Harici bir feed adresine appcast yüklemez.

İngilizce teknik başvuru ve workflow'un tam davranışı: [RELEASING.md](RELEASING.md).

## 1. Kimlikleri ve erişimi doğrulayın

1. Apple Developer üyeliğinizin etkin olduğunu ve Team ID'nizi hesap sayfasından
   doğrulayın. Xcode Settings → Accounts içinde aynı takımı seçin.
2. Repository'nin gerçek `OWNER/REPOSITORY` değerini belirleyin. İlk geliştirmede
   Git remote ve üretim güncelleme adresi yoktu; örnek adresleri gerçek sanmayın.
3. Bundle identifier `com.bgoktugozdemir.MarkUp`. Size ait olduğunu ve Developer
   portalındaki yapılandırmayla uyuştuğunu doğrulayın. macOS hedefi 14.0, dağıtım
   Universal (`arm64` + `x86_64`) olarak kalmalıdır.
4. Güncel Xcode'u çalıştırıp lisans ve Command Line Tools kurulumunu tamamlayın.
   CI, resmi macOS 15 runner'ında Xcode 26.3 kullanacak şekilde hazırlanmıştır.

## 2. Developer ID Application sertifikasını hazırlayın

Account Holder, Xcode Settings → Accounts → Manage Certificates veya Apple
Developer Certificates ekranından **Developer ID Application** oluşturur/seçer.
Bu ZIP dağıtımında Developer ID Installer kullanılmaz. Apple'ın [Developer ID
rehberi](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/)
hesap yetkisini ve işlemi açıklar.

Keychain Access → My Certificates içinde sertifikayı genişletin; altında private
key görünmelidir. Sertifika ve private key'i birlikte güçlü bir parola ile `.p12`
olarak dışa aktarın. Yalnız `.cer` dosyası CI imzasına yetmez. Dosyayı repository
dışında, şifreli/özel bir yerde tutun. Tam identity adını öğrenmek için:

```sh
security find-identity -v -p codesigning
```

`Developer ID Application: ADINIZ (TEAMID)` satırındaki identity adını kullanın.
Private key'i export edemiyorsanız sertifikayı oluşturan Mac'teki kimliği veya
şifreli yedeği kullanmanız gerekir; public sertifika private key yerine geçmez.

## 3. Notarization hesabını doğrulayın

Tercih edilen CI yolu ayrı bir **Team App Store Connect API key**'dir. Account
Holder/Admin API erişimini açıp anahtarı oluşturur. Takımınızda notarization
doğrulamasını geçen en düşük rolü seçin; önce Developer rolünü deneyin, gerekçesiz
Admin vermeyin. `.p8` dosyası bir kez indirilir; Key ID ve Issuer ID'yi de kaydedin.
Bu anahtarın takım genelindeki etkisini dikkate alıp `release` environment
onaylayıcılarını sınırlandırın.

```sh
xcrun notarytool store-credentials MarkUp-notary \
  --key /guvenli/konum/AuthKey_KEYID.p8 --key-id KEY_ID --issuer ISSUER_UUID
```

Bu komut kimlik bilgilerini doğrular; uygulama göndermez. CI'nin auth biçimi Team
key + Issuer ID'dir. Individual key'i doğrulamadan yerine koymayın. [Apple API key
rehberi](https://developer.apple.com/documentation/AppStoreConnectAPI/creating-api-keys-for-app-store-connect-api)
ve yerel `xcrun notarytool --help` seçtiğiniz toolchain için başvurudur.

API key erişiminiz yoksa yerel alternatif 2FA etkin Apple Account + **app-specific
password** + Team ID'dir:

```sh
xcrun notarytool store-credentials MarkUp-notary \
  --apple-id APPLE_HESABINIZ --team-id TEAM_ID
```

Parolayı güvenli prompt'a girin; normal hesap parolasını kullanmayın. Ardından yerel
`notarytool submit --keychain-profile MarkUp-notary --wait ...` akışı kullanılabilir.
Mevcut CI API key bekler; fallback için workflow'un auth kısmı ve secret adları
ayrıca gözden geçirilerek değiştirilmelidir.

## 4. Sparkle güncelleme anahtarını üretin

Pinned paketler çözümlendikten sonra:

```sh
.build/xcode-packages/artifacts/sparkle/Sparkle/bin/generate_keys --account MarkUp-release
.build/xcode-packages/artifacts/sparkle/Sparkle/bin/generate_keys --account MarkUp-release -x /guvenli/konum/markup-update-private
```

İlk komut private key'i login Keychain'de tutar ve public key'i gösterir. Public
key uygulamaya girebilir; export edilen private dosyanın içeriği yalnız GitHub
environment secret'ına ve şifreli offline yedeğinize gitmelidir. Private export
metnini ikinci kez base64 yapmayın. [Sparkle yayın
rehberi](https://sparkle-project.org/documentation/publishing/) bu iki anahtarın
rollerini açıklar.

## 5. GitHub environment ve tam ayar listesi

Repository Settings → Environments altında **release** oluşturun. Required
reviewer olarak yetkili sahibini belirleyin; deployment tag kuralını `v*` ile
sınırlandırın. Repository ruleset ile bu tag'leri oluşturma/silme yetkisini
sınırlandırın. Yalnız incelenmiş commit'leri tag'leyin. Fork/PR kodunu imzalama
secrets'ı olan bir ortamda çalıştırmayın.

Environment **variables**:

| Ad | Değer |
| --- | --- |
| `RELEASE_ENABLED` | Diğer korumalar hazır olduğunda en son `true` |
| `RELEASE_REPOSITORY` | Doğruladığınız `OWNER/REPOSITORY` |
| `DEVELOPMENT_TEAM` | 10 karakterli Team ID |
| `DEVELOPER_ID_APPLICATION` | Tam Developer ID Application identity adı |
| `MARKUP_UPDATE_FEED` | Size ait, public HTTPS `appcast.xml` adresi |
| `MARKUP_UPDATE_PUBLIC_KEY` | Sparkle public key, 32 byte'ın base64 metni |
| `MARKUP_DOWNLOAD_URL_PREFIX` | Örneğin `https://github.com/OWNER/REPOSITORY/releases/download`; tag ve ZIP adı script tarafından eklenir |

Environment **secrets**:

| Ad | İçerik |
| --- | --- |
| `CERTIFICATE_P12_BASE64` | Sertifika + private key içeren `.p12` dosyasının base64'ü |
| `CERTIFICATE_P12_PASSWORD` | `.p12` export parolası |
| `NOTARY_API_KEY_BASE64` | `.p8` dosyasının base64'ü |
| `NOTARY_KEY_ID` | Team API Key ID |
| `NOTARY_ISSUER_ID` | Issuer UUID |
| `SPARKLE_PRIVATE_KEY` | `generate_keys -x` ile export edilen metnin kendisi |

Dosya içeriğini terminale veya sohbete yazdırmadan GitHub CLI ile aktarabilirsiniz:

```sh
base64 -i /guvenli/konum/DeveloperID.p12 | gh secret set CERTIFICATE_P12_BASE64 --env release --repo OWNER/REPOSITORY
base64 -i /guvenli/konum/AuthKey_KEYID.p8 | gh secret set NOTARY_API_KEY_BASE64 --env release --repo OWNER/REPOSITORY
gh secret set SPARKLE_PRIVATE_KEY --env release --repo OWNER/REPOSITORY < /guvenli/konum/markup-update-private
gh secret set CERTIFICATE_P12_PASSWORD --env release --repo OWNER/REPOSITORY
```

Son komut güvenli giriş ister. Key ID/Issuer ID secrets'ını da GitHub ekranı veya
`gh secret set` prompt'u ile girin. Uzun ömürlü keychain parolası/PAT gerekmez.
Workflow geçici keychain parolasını her çalışmada üretir ve maskeler.

## 6. İlk hazırlama çalışması

Önce secret gerektirmeyen `Checks` workflow'unu çalıştırın. İngilizce/Türkçe kaynak,
unit/integration tests ve Universal derleme kontrollerini inceleyin. CI'nin
derlediği mimariler ile testleri gerçekten çalıştırdığı host mimarisini ayırın.

Gözden geçirilmiş commit için `v0.1.0` benzeri tag oluşturun; workflow protected
environment onayından sonra ilerler. Alternatif olarak workflow_dispatch'ta bir
version tag seçin. Branch seçimi imzalama çalıştırmaz. `--preflight` eksik ayar
adlarını bildirir; private değerleri yazdırmaz.

Script geçici keychain'e identity'yi import eder, Release archive + Xcode
developer-id export yapar, Sparkle helper/XPC imzalarını ve iki mimariyi kontrol
eder. ZIP'i Apple'a yollar, sonucu/log'u inceler ve `Accepted` ister. Ardından
**app payload**'ına staple yapar, doğrular, Gatekeeper kontrol eder ve son ZIP'i
yeniden üretir. ZIP'e staple yapılamaz. Sparkle imzası/appcast/checksum yalnız son
byte'lar için üretilir. İmzalama için `codesign --deep` kullanılmaz.

Başarısızlıkta/cancellation'da geçici credential dosyaları ve keychain temizlenir;
önceki keychain search list geri yüklenir. Notarization 20 dakikada bitmezse başarı
iddia edilmez; log'daki submission ID ile `notarytool history/log` üzerinden
araştırın. Bu akış kalıcı self-hosted runner için onaylanmış değildir.

Başarılı çıktılar `artifacts/release` altında ZIP, `appcast.xml`, `SHA256SUMS` ve
`release-evidence.json` olarak oluşur; `publish` job'ı checksum'ları doğrulayıp
bunları GitHub Release'e ekler. İmza takımı, sürüm/build numarası, notarization/ticket ve gerçek
mimari/OS test kayıtlarını inceleyin.

## 7. Kontrollü gerçek güncelleme testi ve yayın

Üretim kurulumu veya verisi bulunmayan, ayrı bir test hesabı ya da geçici VM kullanın; feed, key ve kurulum yolu staging için ayrılmalıdır. Hazır workflow/verifier `com.bgoktugozdemir.MarkUp` bundle ID’sini zorunlu tutar. Farklı staging bundle ID kullanmak isterseniz önce `project.yml`, update entitlements ve `scripts/release-verify.py` birlikte değiştirilip incelenmelidir.
Gerçek kullanıcının üretim uygulamasının üzerine yazmayın. N sürümünü kurun,
N+1 ZIP/appcast'ini kontrollü HTTPS staging adresine koyun; uygulama içinden
download → install → relaunch ve yeni sürümün açılmasını doğrulayın. Offline,
up-to-date, cancel ve failure durumlarını da deneyin. Staging ZIP'in bir byte'ını
değiştirip imzayı aynı bırakın: güncelleme reddedilmeli, N çalışır kalmalıdır.
Yanlış anahtar imzasını da reddetmesini doğrulayın.

CI'nin CryptoKit kontrolü geçerli/değiştirilmiş/yanlış anahtarlı imzaları sınar;
Sparkle'ın gerçek kurulum/relaunch testinin yerine geçmez. Gerçek feed/hesap
kurulmadıkça bu end-to-end gate **doğrulanmamış** kalır.

Ayrıca Apple Silicon + Intel üzerinde çalışma, macOS 14/15 görünümü, güncel
Liquid Glass, Türkçe/İngilizce, keyboard/VoiceOver ve performans kontrol kayıtlarını
tamamlayın. Sahip tarafından iletilen logo 2026-10-31 tarihinde uygulama ikonuna
eklendi. Sonraki ikon değişikliklerinden sonra archive/imza/notarization tekrar gerekir.

Tag'i yalnızca bu kontroller tamamlandıktan sonra `main` üzerinde oluşturun;
`release` environment onayı son yayın kapısıdır. Feed GitHub Release dışında
barınıyorsa yayınlanan **en son appcast'i** gerçek feed adresine koyun. Eski sürümler bulunan bir feed'e yeni item'ı kontrollü ekleyip
desteklenen branch item'larını koruyun. Uygulamaya private repo token'ı gömmeyin.

## 8. Anahtar yenileme ve App Store geçişi

Sertifika bitmeden yeni `.p12`/parolayı yükleyip staging güncellemesini deneyin.
Sızan API key'i App Store Connect'te iptal edip minimum yetkili yenisini oluşturun;
ilgili üç secret'ı değiştirin. Log'a çıkan credential için log'u silmekle yetinmeyin,
credential'ı rotate edin. Kullanılmayan secrets'ı kaldırın.

Sparkle key rotation sırasında Developer ID ve EdDSA güvenini aynı anda değiştirmeyin.
Birini koruyan bridging update hazırlayıp [Sparkle'ın
yönergesine](https://sparkle-project.org/documentation/) göre staging'de test edin.
Kayıp private key için doğrulamayı gevşetmek çözüm değildir.

Gelecekte App Store sürümü `UpdateService`, updater menü/ayar/localization'ları,
Sparkle dependency/framework/helper'ları, `SU*` feed/key/service Info alanlarını ve
yalnız updater için gereken mach lookup exceptions'ı kaldırmalıdır. Sandbox,
user-selected access/bookmark ve Application Support annotation storage korunur;
güncellemeleri Store dağıtır. Bundle ID/container veri geçişi ayrıca kararlaştırılır.
Bu çalışma App Store target, satın alma, abonelik veya mağazaya gönderim içermez.

Unsigned development build dağıtıma hazır değildir. Archive başarısı notarization
başarısı değildir. Signed/notarized artifact da gerçek cihaz/OS ve N → N+1
testleri tamamlanmadan yayın onayı sayılmaz.
