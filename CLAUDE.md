# CLAUDE.md

Bu dosya Claude Code (claude.ai/code) için projeyle ilgili rehberdir.

## Project Overview

**Heart** — local development environment launcher for macOS. Tek pencerede birden fazla shell komutunu (servers, daemons, dev agents) start/stop/restart edebileceğin bir GUI. SwiftUI native macOS uygulaması.

Her task için:
- Status indicator (yeşil = running, sarı = starting/stopping spinner, kırmızı = stopped/crashed)
- Real PTY içinde komut çalıştırma (TUIs gibi `ngrok`, `htop` da düzgün render olur)
- Interactive terminal panel — output canlı stream + klavyeyle stdin'e yazılabilir (Ctrl+C, Ctrl+D, ok tuşları PTY'ye forward)
- Optional `port` alanı → "KILL PORT" butonu (`lsof -ti tcp:<port> | xargs kill -9`) + readiness check (port bind olana kadar `.starting` kalır)
- Settings = JSON editor + Import / Export / Reset to Defaults / Open in Finder

## Tech Stack

- **Language:** Swift 6 + SwiftUI
- **Build:** Swift Package Manager (Xcode projesi yok)
- **Min macOS:** 13 (Ventura)
- **Bundle:** `app.heart.launcher`
- **Storage:** `~/Library/Application Support/Heart/tasks.json`

## Folder Structure

```
heart/
├── Package.swift
├── Sources/Heart/
│   ├── HeartApp.swift                # @main + AppDelegate (terminate cleanup)
│   ├── Models/
│   │   ├── DevTask.swift              # Codable: id, name, command, cwd, port?, autoStart
│   │   └── TaskStatus.swift           # enum: stopped/starting/running/stopping/crashed
│   ├── Services/
│   │   ├── TaskStore.swift            # tasks.json load/save + defaults
│   │   └── ProcessManager.swift       # spawn/kill/readiness/PTY input/port-kill
│   └── Views/
│       ├── ContentView.swift          # NavigationSplitView (sidebar + output)
│       ├── TaskRow.swift              # status dot + name + port chip + buttons
│       ├── OutputView.swift           # NSTextView wrapped — interactive terminal
│       └── SettingsView.swift         # JSON editor + Import/Export
├── scripts/
│   └── make-icon.swift                # generates AppIcon.iconset → .icns
├── build.sh                           # swift build + bundle .app
├── install.sh                         # build + copy to /Applications
├── tasks.example.json                 # ornek config (Maatrics komutları)
├── README.md
└── CLAUDE.md                          # this file
```

## Quick Commands

```bash
# Build & install to /Applications/Heart.app
./install.sh

# Just build the .app in current dir (don't install)
./build.sh

# Build universal (arm64+x86_64), ad-hoc sign, package Heart.zip for distribution
./dist.sh

# Re-render the app icon only
swift scripts/make-icon.swift && iconutil -c icns AppIcon.iconset -o AppIcon.icns
```

## User Commands (Türkçe)

Kullanıcıdan aşağıdaki cümleler geldiğinde ilgili komutu çalıştır:

### "deploy", "deploy et", "son halini ver", "production al", "uygulamayi cikar"

→ **`./dist.sh`** çalıştır.

Bu script:
1. `scripts/make-icon.swift` ile icon'u render eder, `iconutil` ile `.icns` üretir
2. `swift build -c release --arch arm64 --arch x86_64` ile **universal binary** derler (Apple Silicon + Intel)
3. `Heart.app` bundle'ını oluşturur, Info.plist + AppIcon.icns yerleştirir
4. `codesign --force --deep --sign -` ile **ad-hoc imzalar** (Apple Silicon "is damaged" hatasını engeller)
5. `Heart.app` + `INSTALL.txt` (Türkçe kurulum talimatı) + `tasks.example.json`'u **`Heart.zip`** içine paketler

Çıktı: `Heart.zip` — boyutunu, mimarileri ve dosya yolunu kullanıcıya raporla. Bu zip arkadaşlara/takıma gönderilebilir, alıcı `xattr -cr /Applications/Heart.app` ile açar.

### "kur", "yükle", "install et"

→ **`./install.sh`** — kendi makinesine `/Applications/Heart.app`'a kurar (geliştirme döngüsü için).

## Key Conventions

### Process spawning (ProcessManager.start)

Komutlar şu şekilde sarmalanır:

```swift
process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
process.arguments = ["-q", "/dev/null", "/bin/zsh", "-l", "-c",
                     "stty rows 40 cols 160 2>/dev/null; <user_command>"]
```

- `/usr/bin/script` BSD `script` → gerçek bir PTY allocate eder; ngrok/htop/top gibi TUI'ler düzgün çalışır
- `zsh -l -i` (login + **interactive**) → `.zprofile` **ve** `.zshrc` sourcelanır. **`-i` zorunlu**: zsh'de non-interactive mode'da `.zshrc` sourcelanmaz. Bunu unutursan GUI'den (Launchpad/Spotlight) açıldığında kullanıcının `~/.zshrc`'ye koyduğu `export PATH="$HOME/bin:$PATH"` gibi satırlar etki etmez, custom binary'ler "command not found" verir. Terminal'den `open` ile açıldığında inherit ediliyordu, bu yüzden ilk testlerde fark edilmemişti.
- `stty rows 40 cols 160` → BSD `script` PTY'yi default 0×0 boyutla açar; bunu set etmezsek TUI'ler size'ı tespit edip çıkar

### Stop sequence

Graceful shutdown chain:

1. PTY'ye `0x03` (Ctrl+C ETX byte) yaz + `process.interrupt()` (SIGINT)
2. 3 sn timer → hâlâ alive ise `process.terminate()` (SIGTERM)
3. 3 sn timer → hâlâ alive ise `kill(pid, SIGKILL)`

### Readiness check

Start sonrası status `.starting` kalır (sarı spinner) ta ki:

- `port` set'liyse: BSD socket connect'i `127.0.0.1:port`'a başarılı olana kadar her 300ms poll. 30sn timeout → yine `.running` (best effort).
- `port` yoksa: 1.5sn grace sonrası `.running`.

Process readiness'ten önce ölürse → `terminationHandler` zaten `.crashed` set eder; readiness loop status'u `.starting` değil görüp çıkar.

### ANSI strip

NSTextView terminal emülatörü değil — gelen escape sekansları UI'da çöp gibi görünür. `ProcessManager.stripAnsi` regex'i şunları siler:

- CSI: `ESC [ ... finalByte`
- OSC: `ESC ] ... BEL`
- 2-byte ESC sequences: `ESC =`, `ESC >`, `ESC 7/8`, `ESC D/E/H/M/c …`
- G0/G1 charset: `ESC ( B`

### Terminal input

`TerminalTextView` (NSTextView subclass):

- `isEditable = true` → focus ve caret çalışsın
- `keyDown(with:)` override → super çağrılmaz; tüm keystroke'ler PTY stdin'e yazılır (PTY echo geri gelip text view'da görünür)
- Special keys: Return → CR (0x0D), Backspace → DEL (0x7F), arrows → CSI sequences, Ctrl+letter → ETX/EOT/SUB/etc.
- Cmd-shortcuts (copy/paste/select-all) → `super.keyDown` ile macOS default davranışına bırakılır

### tasks.json migration / version

Schema versiyonu yok. Yeni alan eklendiğinde `Codable` decode'da nil/default ile geçer (örn. `port: Int?`). Breaking change yapılırsa `TaskStore.load`'a manual migration eklenir.

### Settings JSON editor

`SettingsView` doğrudan `tasks.json`'un JSON metnini düzenletir. Save'de:

- UTF-8 decode → `JSONDecoder().decode([DevTask].self, ...)`
- Boş `name` veya `command` olan task'lar filtrelenir (auto-strip)
- Hata varsa turuncu warning bar'da `decodingError.context` mesajıyla gösterilir, save iptal

## Don't Do

- **Migration table'ı koda gömme** — eskiden `MaatricsDevLauncher` storage path'iyle deneme yapıldı, şimdi `Heart` kullanılıyor. ID-bazlı port migration kaldırıldı; artık her kullanıcı kendi config'ini import eder.
- **Background process spawn'ı `bash` veya `sh` ile** — login shell olmadan kullanıcı PATH/aliasları kayıp olur. Hep `/bin/zsh -l -c` kullan.
- **PTY size'ı atlamak** — `stty rows 40 cols 160` olmadan ngrok/htop hemen çıkar.

## Notes

- App sandbox kapalı (child process spawn için zorunlu); code signing local kullanım için yapılmıyor (`xattr -cr` Gatekeeper karantinasını siler).
- Cmd+Q'da `applicationWillTerminate` çağrılır → `ProcessManager.terminateAllSync` tüm child'ları sync olarak SIGTERM → 2sn → SIGKILL ile temizler. Orphan kalmaz.
- `tasks.example.json` Maatrics-spesifik komutları içerir; başka projelerde Settings → Import ile JSON yüklenebilir.
