# Сторонние компоненты

Собственный код BRIZFI: Copyright (C) 2026 Maksim Kulkov, GPL-3.0-or-later.
Сторонние компоненты сохраняют исходные лицензии и авторские права.

- Конвертер Boko 0.5.0: Zachary Denton и участники проекта,
  GPL-3.0-or-later, https://github.com/zacharydenton/boko,
  revision `8f412fb1a507399bce320d591feb517467cdb5f7`.
  Лицензия включена в THIRD_PARTY_LICENSES/Boko-GPL-3.0.txt,
  полный исходный код — в rust-vendor/boko в архиве исходников релиза.
- Flutter framework/engine: The Flutter Authors, BSD-3-Clause,
  https://github.com/flutter/flutter/tree/5fc346839b.
- Dart SDK: The Dart project authors, BSD-3-Clause,
  https://github.com/dart-lang/sdk.
- flutter_rust_bridge 2.13.0: авторы flutter_rust_bridge, MIT,
  https://github.com/fzyzcjy/flutter_rust_bridge.

Полный список точных Dart/Rust-зависимостей закреплён в source/pubspec.lock,
source/rust/Cargo.lock и source/poc/converter/Cargo.lock.
Лицензионные уведомления Flutter-пакета доступны в бинарном дистрибутиве
как THIRD_PARTY_LICENSES/Flutter-NOTICES.txt и data/flutter_assets/NOTICES.Z.
Лицензионные файлы Rust-компонентов скопированы в THIRD_PARTY_LICENSES/rust/;
оригинальные тексты и уведомления также сохранены в архиве исходников зависимостей.

Платформенные Android-пакеты в pubspec не означают их включение в Windows-бинарник.
Этот релиз предоставляет Windows x64; Android/iOS SDK и сборки не поставляются.
