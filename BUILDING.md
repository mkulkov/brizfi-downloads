# BRIZFI 0.1.1+3 — сборка

Flutter 3.47.6 / Dart 3.13.5, Rust/Cargo 1.98.1. Зависимости закреплены lockfiles.
Из source/: `flutter pub get --enforce-lockfile`, затем `flutter build windows --release`
или `flutter build apk --release`. Windows требует Visual Studio C++ / Windows SDK;
Android — Android SDK/NDK и JDK (на машине выпуска JDK 25, SDK 36.1.0).
Android minSdk 29. Для подписи Android создайте собственный android/key.properties;
ключи подписи в исходники не входят. Используется стандартная конфигурация приложения
с рекламой и RuStore Pay. Для установщика Windows: packaging/windows/build-installer.ps1
-NoticesDir .. (Inno Setup 6.7.3). Установщик Windows не подписан.

Архив исходников включает rust-vendor, dart-pub-cache и cargo-vendor-config.toml.
Для офлайн-зависимостей скопируйте cargo-vendor-config.toml в .cargo/config.toml
и задайте PUB_CACHE на dart-pub-cache. Сам toolchain устанавливается отдельно.
Побайтовая воспроизводимость и сборка на чистой машине не проверялись.
