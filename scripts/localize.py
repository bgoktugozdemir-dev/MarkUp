#!/usr/bin/env python3
"""Deterministic English/Turkish resources. Data only; run after adding translated UI copy."""
from pathlib import Path
import json
import re

translations = '''Open Recent|Son Kullanılanları Aç
Show all code|Kodun tamamını göster
Limit code height|Kod yüksekliğini sınırla
All code is already visible|Kodun tamamı zaten görünüyor
Show long code blocks in short view|Uzun kod bloklarını kısa görünümde göster
View Mode|Görünüm Modu
Preview|Önizleme
Source|Kaynak
Widen the window to show this panel|Bu paneli göstermek için pencereyi genişletin
Test build: separate from the installed MarkUp and its data|Test sürümü: yüklü MarkUp'tan ve verilerinden ayrıdır
Clear Recent Documents|Son Kullanılan Belgeleri Temizle
Undo|Geri Al
Redo|Yinele
A calm place for Markdown.|Markdown için sakin bir alan.
A calm place to read. Türkçe: İı Şş Ğğ — 123|Okumak için sakin bir alan. Türkçe: İı Şş Ğğ — 123
Actual Size|Gerçek Boyut
Allow remote images by default|Uzak görsellere varsayılan olarak izin ver
Annotation storage could not be updated. Your documents were not changed.|İşaret deposu güncellenemedi. Belgeleriniz değiştirilmedi.
Annotation storage needs recovery. Existing recovery data has been preserved; adding marks is disabled.|İşaret deposunun kurtarılması gerekiyor. Kurtarma verileri korundu; yeni işaret ekleme devre dışı.
Annotations|İşaretler
Annotations are excluded by default. Exported text remains selectable.|Kişisel işaretler varsayılan olarak dahil edilmez. Dışa aktarılan metin seçilebilir kalır.
Annotations could not be loaded. Your source document is unchanged.|İşaretler yüklenemedi. Kaynak belgeniz değiştirilmedi.
App controls change immediately. Restart to update system-owned menus and dialogs.|Uygulama kontrolleri hemen değişir. Sistem menüleri ve iletişim kutuları için uygulamayı yeniden başlatın.
Appearance|Görünüm
Automatically check for updates|Güncellemeleri otomatik denetle
Automatically pair light and dark themes|Açık ve koyu temaları otomatik eşleştir
Cancel|Vazgeç
Check for Updates…|Güncellemeleri Denetle…
Choose External Editor…|Harici Düzenleyici Seç…
Choose a different destination. The Markdown source cannot be overwritten.|Başka bir hedef seçin. Markdown kaynağının üzerine yazılamaz.
Choose a folder to allow local images, linked documents, and reliable replacement-save monitoring.|Yerel görseller, bağlantılı belgeler ve dosya değişimlerini izlemek için bir klasör seçin.
Choose an external editor again in Settings.|Ayarlar’dan harici düzenleyiciyi yeniden seçin.
Choose an external editor in Settings first.|Önce Ayarlar’dan bir harici düzenleyici seçin.
Clear All Annotations|Tüm İşaretleri Sil
Clear All Annotations…|Tüm İşaretleri Sil…
Clear Rendering Cache|Görüntüleme Önbelleğini Temizle
Clear all annotations in every document?|Tüm belgelerdeki işaretler silinsin mi?
Close|Kapat
Code|Kod
Code Theme|Kod Teması
Dark|Koyu
Data|Veriler
Dismiss|Kapat
Document minimap|Belge mini haritası
Done|Bitti
Drop a .md or .markdown file here, or press ⌘O.|Buraya bir .md veya .markdown dosyası bırakın ya da ⌘O tuşlarına basın.
Export PDF|PDF Dışa Aktar
Export PDF…|PDF Dışa Aktar…
Export Preferences…|Tercihleri Dışa Aktar…
Export…|Dışa Aktar…
Find|Bul
Find Next|Sonrakini Bul
Find Previous|Öncekini Bul
Find in document|Belgede bul
Find…|Bul…
General|Genel
Grant Access|Erişim İzni Ver
Grant Folder Access…|Klasör Erişim İzni Ver…
Heading outline|Başlık listesi
Highlight Blue|Mavi Vurgula
Highlight Green|Yeşil Vurgula
Highlight Yellow|Sarı Vurgula
Import Preferences…|Tercihleri İçe Aktar…
Include personal annotations|Kişisel işaretleri dahil et
Landscape|Yatay
Language|Dil
Light|Açık
Load Remote Images|Uzak Görselleri Yükle
Loading document…|Belge yükleniyor…
Margins (points)|Kenar boşlukları (punto)
Markdown document|Markdown belgesi
Minimap|Mini Harita
No readable content|Okunabilir içerik yok
OK|Tamam
Only Markdown documents and HTTP(S) links can be opened.|Yalnızca Markdown belgeleri ve HTTP(S) bağlantıları açılabilir.
Open Markdown…|Markdown Aç…
Open a Markdown file to begin.|Başlamak için bir Markdown dosyası açın.
Open in External Editor|Harici Düzenleyicide Aç
Open…|Aç…
Outline|Başlıklar
PDF export failed. Check the destination and available disk space.|PDF dışa aktarılamadı. Hedefi ve boş disk alanını kontrol edin.
PDF exported.|PDF dışa aktarıldı.
Paper|Kağıt
Preferences could not be exported.|Tercihler dışa aktarılamadı.
Printing failed. Try exporting a PDF instead.|Yazdırma başarısız oldu. PDF dışa aktarmayı deneyin.
Print…|Yazdır…
Reading|Okuma
Reload|Yeniden Yükle
Remote images can disclose your IP address to their host. Local documents are never uploaded.|Uzak görseller IP adresinizi sunucularıyla paylaşabilir. Yerel belgeler hiçbir zaman yüklenmez.
Remove|Kaldır
Rendering cache cleared.|Görüntüleme önbelleği temizlendi.
Reset Typography|Tipografiyi Sıfırla
Retry|Yeniden Dene
Select text to highlight or underline it.|Vurgulamak veya altını çizmek için metin seçin.
Show Annotations|İşaretleri Göster
Show line numbers|Satır numaralarını göster
Show minimap|Mini haritayı göster
Show outline|Başlıkları göster
Storage|Depolama
System|Sistem
The annotation could not be saved. Select complete characters and try again.|İşaret kaydedilemedi. Tam karakterleri seçip yeniden deneyin.
The file could not be read. Check its location, encoding, and access permissions. The last readable version is kept.|Dosya okunamadı. Konumunu, kodlamasını ve erişim izinlerini kontrol edin. Son okunabilir sürüm korundu.
The owner must configure the signed update feed and public key before distributing MarkUp.|MarkUp dağıtılmadan önce imzalı güncelleme kaynağı ve açık anahtar yapılandırılmalıdır.
This document could not be rendered. It may exceed the supported resource limits.|Bu belge görüntülenemedi. Desteklenen kaynak sınırlarını aşıyor olabilir.
This link is unavailable or needs folder access. Use Grant Folder Access to choose its containing folder.|Bu bağlantı kullanılamıyor veya klasör erişimi gerekiyor. Klasör Erişim İzni Ver ile ilgili klasörü seçin.
This permanently removes highlights and underlines, including recovery copies. Documents and preferences are kept.|Kurtarma kopyaları dahil tüm vurgular ve alt çizgiler kalıcı olarak silinir. Belgeler ve tercihler korunur.
This preference file is invalid or uses an unsupported version.|Bu tercih dosyası geçersiz veya desteklenmeyen bir sürüm kullanıyor.
This undo is no longer available because annotations were cleared.|İşaretler silindiği için bu işlem artık geri alınamaz.
Typography|Tipografi
Underline|Altını Çiz
Unmatched — preserved for recovery|Eşleşmedi — kurtarma için korundu
Updates are not configured in this development build.|Bu geliştirme sürümünde güncellemeler yapılandırılmadı.
Use current appearance|Geçerli görünümü kullan
Welcome to MarkUp|MarkUp’a Hoş Geldiniz
Wrap code|Kod satırlarını kaydır
Zoom In|Büyüt
Zoom Out|Küçült
unmatched annotations|eşleşmeyen işaret
Body Font|Gövde Yazı Tipi
Body Size|Gövde Boyutu
Heading Font|Başlık Yazı Tipi
Code Font|Kod Yazı Tipi
Code Size|Kod Boyutu
Line Spacing|Satır Aralığı
Paragraph Spacing|Paragraf Aralığı
Reading Width|Okuma Genişliği
Code language|Kod dili
Copy|Kopyala
Copied|Kopyalandı
Copy code|Kodu kopyala
Code copied|Kod kopyalandı
Wrap|Kaydır
Lines|Satırlar
Wrap this code block|Bu kod bloğunun satırlarını kaydır
Line numbers for this code block|Bu kod bloğunun satır numaraları
Horizontal code scroll|Kodu yatay kaydır
Horizontal table scroll|Tabloyu yatay kaydır
Recover Annotations|İşaretleri Kurtar
Recover Annotations…|İşaretleri Kurtar…
If a file was replaced while MarkUp was closed, its old marks remain separate. Choose their previous document only if you recognize it.|MarkUp kapalıyken bir dosya değiştirildiyse eski işaretleri ayrı tutulur. Yalnızca tanıdığınız önceki belgeyi seçin.
No other saved annotations are available.|Başka kayıtlı işaret bulunmuyor.
Move these annotations to the current document?|Bu işaretler geçerli belgeye taşınsın mı?
Only trustworthy text matches will be shown. Other marks stay recoverable. The source files are not changed.|Yalnızca güvenilir metin eşleşmeleri gösterilir. Diğer işaretler kurtarılabilir kalır. Kaynak dosyalar değiştirilmez.
Annotations could not be recovered. The saved marks have been kept.|İşaretler kurtarılamadı. Kayıtlı işaretler korundu.
Some images need access or are missing, unsupported, or too large.|Bazı görseller erişim izni gerektiriyor, eksik, desteklenmiyor veya çok büyük.
Body Weight|Gövde Kalınlığı
Heading Weight|Başlık Kalınlığı
Regular|Normal
Medium|Orta
Semibold|Yarı Kalın
Bold|Kalın
Heading preview|Başlık önizlemesi
Reset Code Settings|Kod Ayarlarını Sıfırla
This item is not a regular Markdown file.|Bu öğe normal bir Markdown dosyası değil.
This file is larger than the 16 MiB reading limit.|Bu dosya 16 MiB okuma sınırından büyük.
This file is not valid UTF-8 or UTF-16 text.|Bu dosya geçerli UTF-8 veya UTF-16 metni değil.
This file looks like binary data. Choose a Markdown text file.|Bu dosya ikili veri içeriyor. Bir Markdown metin dosyası seçin.
Preparing Document|Belge Hazırlanıyor
Preparing document…|Belge hazırlanıyor…
Paginating document…|Belge sayfalara ayrılıyor…
Preparing PDF links…|PDF bağlantıları hazırlanıyor…
Rendering PDF pages…|PDF sayfaları oluşturuluyor…
Saving PDF…|PDF kaydediliyor…
Cancelling…|İptal ediliyor…
PDF export cancelled.|PDF dışa aktarma iptal edildi.
Print job submitted.|Yazdırma işi gönderildi.
Printing cancelled.|Yazdırma iptal edildi.
Letter|Letter
Document|Belge
Image Preview|Görsel Önizleme'''

mapping = dict(line.split("|", 1) for line in translations.splitlines())
for level in range(1, 7):
    mapping[f"H{level}"] = f"H{level}"
root = Path(__file__).resolve().parent.parent
keys = set()
for path in (root / "Sources/MarkUpApp").rglob("*.swift"):
    keys.update(re.findall(r'localized\("([^"\n]*)"\)', path.read_text()))
missing = keys - mapping.keys()
if missing:
    raise SystemExit(f"Missing Turkish translations: {sorted(missing)}")
for language in ["en", "tr"]:
    path = root / f"Sources/MarkUpApp/Resources/{language}.lproj/Localizable.strings"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("// App-owned copy. Document content is never translated.\n" + "\n".join(
        f"{json.dumps(key, ensure_ascii=False)} = {json.dumps(key if language == 'en' else value, ensure_ascii=False)};"
        for key, value in sorted(mapping.items())) + "\n")
print(f"Validated {len(mapping)} English/Turkish strings")
