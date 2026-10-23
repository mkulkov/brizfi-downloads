# Сборка Windows

## Версии

- Flutter stable 3.47.6, revision `5fc346839b`, Dart 3.13.5.
- Rust/Cargo 1.98.1, MSVC x64 target.
- Visual Studio 2022 с компонентом Desktop development with C++, Windows SDK 10.0.22621.0.
- flutter_rust_bridge runtime/hooks/codegen 2.13.0; для обычной сборки повторный codegen не нужен.
- Boko 0.5.0, revision `8f412fb1a507399bce320d591feb517467cdb5f7`.

Исходный снимок приложения: `ecab2f72270e7584c2673c976b139d6eebe1c4f3`.
Собственный исполняемый код снимка соответствует Windows-сборке от 23 октября 2026 года.
Лицензия и документация распространения добавлены после сборки. Переносимый ZIP сохраняет первоначальную иконку. Установщик использует новую иконку
из текущего source/windows/runner/resources/app_icon.ico и app-local CRT Visual C++. Полная побайтовая воспроизводимость не заявляется.

## Обычная сборка

Установите указанные инструменты, проверьте `flutter doctor -v`.
Из каталога `source`:

```powershell
flutter pub get --enforce-lockfile
flutter build windows --release
```

Результат: весь каталог `source/build/windows/x64/runner/Release`, а не один EXE.
Сборка Rust запускается Native Assets hook `source/hook/build.dart` с `--locked`.
Не обновляйте lockfiles ради пересборки опубликованного релиза.
Для тестов: `flutter test`; для конвертера: `cargo test --manifest-path poc/converter/Cargo.toml --locked`.

## Архив исходников зависимостей

Архив `BRIZFI-0.1.0-20261023-sources.zip` в Releases содержит этот репозиторий без `.git`,
а также `rust-vendor/` (включая Boko) и `dart-pub-cache/` (пакеты из pubspec.lock).
Он не содержит Flutter SDK/Visual Studio/Windows SDK: их устанавливают отдельно.

После распаковки из корня архива:

```powershell
New-Item -ItemType Directory -Force .cargo | Out-Null
Copy-Item cargo-vendor-config.toml .cargo/config.toml
$env:PUB_CACHE = Join-Path $PWD 'dart-pub-cache'
Set-Location source
flutter pub get --offline --enforce-lockfile
flutter build windows --release
```

`cargo-vendor-config.toml` перенаправляет crates.io и точную Git-ревизию Boko на локальный `rust-vendor`.
Полностью автономная установка самого toolchain этим архивом не предоставляется.
Лицензии Dart-пакетов находятся в `dart-pub-cache/hosted/pub.dev/<package-version>/`;
лицензии Rust-пакетов — в `rust-vendor/<package>/`.

## Упаковка

Копируйте весь Release в чистую папку, добавьте LICENSE, README.txt, THIRD_PARTY_NOTICES.md
и THIRD_PARTY_LICENSES, затем создайте ZIP. Не включайте книги, ключи, локальные пути SDK,
кэши сборки или приватные документы. SHA-256 опубликованных архивов находится в SHA256SUMS.txt.

## Windows installer update, 23 October 2026

`BRIZFI-0.1.0-windows-installer-sources.zip` is a source overlay for the original
`BRIZFI-0.1.0-20261023-sources.zip`: extract it into the same root, replacing the
Windows icon and adding the installer definitions and icon master. All application
logic and dependency lockfiles remain the same. The current repository source/
already contains these files. The portable binary ZIP is unchanged.

After rebuilding Flutter Windows, install Inno Setup 6.7.3 and run from source/:

```powershell
./packaging/windows/build-installer.ps1 -NoticesDir ..
```

The script includes the complete Release directory, project/dependency licenses,
and the x64 CRT DLLs from the installed Visual Studio redistributable folder.
Default setup is per-user and does not require administrator rights.
The delivered installer is unsigned. Exact file hashes are in SHA256SUMS.txt.
