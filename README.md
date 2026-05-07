# Heart

> Tek pencereden tüm local dev process'lerini başlat, durdur, restart et — ngrok'tan
> Laravel'e, npm dev'inden voice agent'a kadar her şey bir arada.

**Heart**, geliştirici makinende günde 10 kez çalıştırdığın komutları tek bir pencereden
yöneten native macOS uygulamasıdır. SwiftUI · ~5 MB binary · gerçek PTY ·
sandbox-free.

<p align="center">
  <img src="docs/screenshot.png" width="780" alt="Heart screenshot">
</p>

## Neden?

`tmux` / `screen` / 10 farklı Terminal sekmesi yerine: bir uygulama açarsın, hangi
servisin çalıştığını yeşil noktadan görürsün, durdurmak için butona basarsın.
Ekibinle bir `tasks.json` paylaşırsın, herkes aynı stack'i tek tıkla ayağa kaldırır.

## Özellikler

- **Start / Stop / Restart** her task için tek tıkla
- **Klasör yapısı** — task'ları gruplayabilir, klasör başlığından toplu start/stop yapabilirsin (iç içe klasörler de destekleniyor)
- **Sürükle-bırak import** — `tasks.json` dosyasını sidebar'a bırak → klasör olarak ekle
- **Sağ-tık → Düzenle** — port, klasör, komut, cwd hepsini arayüzden değiştir, JSON otomatik senkronlanır
- **Real PTY** — `script(1)` ile gerçek terminal allocate, `ngrok` / `htop` / `top` düzgün render olur
- **Interactive terminal** — output panel'ına klavyeden yaz, Ctrl+C / Ctrl+D / ok tuşları PTY'ye iletilir
- **Port readiness** — `port` set'liyse server gerçekten bind olana kadar sarı spinner; sonra yeşil
- **KILL PORT** butonu — port set'liyse `lsof -ti tcp:<port> | xargs kill -9`
- **JSON Settings** — tüm config raw JSON, Import / Export / Reset
- **Login shell** — komutlar `/bin/zsh -l -i -c` ile spawn edilir; `~/.zshrc` PATH ve alias'ları doğal yüklenir
- **Graceful shutdown** — SIGINT → 3sn SIGTERM → 3sn SIGKILL escalation; Cmd+Q tüm child process'leri temizler

---

## Kurulum

### Hazır build'le (önerilen)

[**Latest Release →**](https://github.com/ocracy/heart/releases/latest) sayfasından
`Heart.zip`'i indir, sonra:

1. Zip'i aç → `Heart.app`'ı **`/Applications`**'a sürükle.
2. Terminal'e şunu yapıştır + Enter (karantine flag'ini kaldırır):
   ```bash
   xattr -cr /Applications/Heart.app && open /Applications/Heart.app
   ```
3. Açıldı. Sonraki açılışlarda Spotlight (`⌘+Space`) → "heart" → Enter.

> **Neden 2. adım?** Heart ad-hoc imzalı (Apple Developer Program üyeliği gerektirmiyor).
> `xattr` sadece `com.apple.quarantine` flag'ini siler — güvenli, tek seferlik.

**Terminal'e girmek istemezsen alternatif:**
- Finder → `/Applications/Heart.app` → sağ-tık → **Open** → diyalogda **Open**
- Ya da System Settings → Privacy & Security → en alt → "Heart was blocked..." → **Open Anyway**

### Kaynak koddan build

```bash
git clone https://github.com/ocracy/heart.git
cd heart
./install.sh
```

`/Applications/Heart.app`'a kurar. Gereksinimler: macOS 13+, Xcode Command Line Tools (Swift 5.9+).

---

## İlk açılış

İlk çalıştırmada 2 jenerik örnek task (HTTP server, log tail) gelir. Kendi
config'ini eklemenin 3 yolu:

**A. Sidebar'a sürükle-bırak** — bir `tasks.json` dosyasını sidebar'ın altındaki
"drop zone"a bırak → klasör adı sor → ekle.

**B. Sağ-tık → Düzenle** — sidebar'da var olan bir task'a sağ-tık → Düzenle →
form ile değiştir, kaydet.

**C. Settings → JSON editor** (`⌘+,`) — raw JSON'u manuel yaz/yapıştır → Save & Close.

Repo'da `tasks.example.json` var — Laravel + LiveKit + ngrok + 3 frontend dev-server
kurulumu için hazır config. Ekibine bu JSON'u paylaşıp herkes Heart'a Import edebilir.

---

## tasks.json formatı

```json
[
  {
    "id": "laravel-serve",
    "name": "Laravel Serve (8000)",
    "command": "php artisan serve",
    "cwd": "/path/to/your/project",
    "port": 8000,
    "folder": "Backend",
    "autoStart": false
  }
]
```

| Alan | Tip | Açıklama |
|---|---|---|
| `id` | string | Unique key (slug ya da UUID) |
| `name` | string | Sidebar'da görünen isim |
| `command` | string | `/bin/zsh -l -i -c` ile çalıştırılır |
| `cwd` | string | Mutlak path |
| `port` | int? | Set'liyse: readiness check + KILL PORT butonu |
| `folder` | string? | Sidebar'da gruplama. `/` ile alt klasör (`"Maatrics/Frontend"`) |
| `autoStart` | bool? | (rezerv — UI henüz uygulamıyor) |

Config dosyası: `~/Library/Application Support/Heart/tasks.json`

---

## Komutlar

```bash
./build.sh     # release build, ./Heart.app oluşturur (kurmaz)
./install.sh   # build + /Applications/Heart.app'a kur
./dist.sh      # universal binary (arm64 + x86_64), ad-hoc imza, Heart.zip paketler
```

Sadece icon'u yenilemek için:
```bash
swift scripts/make-icon.swift && iconutil -c icns AppIcon.iconset -o AppIcon.icns
```

---

## Uninstall

```bash
rm -rf /Applications/Heart.app
rm -rf ~/Library/Application\ Support/Heart
```

---

## Tech stack

- Swift 5.9+ + SwiftUI (macOS 13+)
- `/usr/bin/script` ile PTY allocate
- Foundation `Process` + `Pipe` ile child process yönetimi
- Swift Package Manager (Xcode projesi yok — `./build.sh` `.app` bundle üretir)
- ~5 MB binary, sandbox kapalı (child process spawn için zorunlu)

---

## License

MIT
