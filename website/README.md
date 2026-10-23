# Лендинг BRIZFI

Статическая страница без сборки, CDN, внешних шрифтов и аналитики.
Иллюстрации скопированы из ресурсов приложения; app-icon-v3.png — актуальная иконка из assets/branding/app-icon.png.
Локально: `python -m http.server 8765 --bind 127.0.0.1 --directory website`.

Публичный сайт: https://mkulkov.github.io/brizfi-downloads/
Публичный репозиторий: https://github.com/mkulkov/brizfi-downloads
Windows: https://github.com/mkulkov/brizfi-downloads/releases/tag/v0.1.0
Android: https://www.rustore.ru/catalog/app/ru.mkulkov.brizfi — HTTP404 на 23.10.2026,
на странице отмечено ожидание публикации. Не подтверждено скачивание Android из магазина.

Собственные код и ресурсы опубликованы под GPL-3.0-or-later с разрешения пользователя.
Публикация работает через Settings → Pages → GitHub Actions и ручной workflow pages.yml.
Загружается только website/, а не исходники приложения или локальные документы.
Относительные пути ресурсов поддерживают адрес /brizfi-downloads/.
После изменения локальной страницы перенесите правки в website/ публичного репозитория,
отправьте commit и вручную запустите Publish BRIZFI landing.
Исходный приватный репозиторий остаётся приватным, история Git не переносилась.


Языки: русский и английский. languages.js переводит текст, alt, aria-label и метаданные.
При первом посещении используется основной язык браузера: ru → русский, остальные → английский.
Ручной выбор в шапке сохраняется в localStorage (brizfi-language); при блокировке хранения
переключение продолжает работать. Без JavaScript остаётся русская версия HTML.

Основные кнопки Windows скачивают BRIZFI-0.1.0-windows-x64-setup.exe из релиза v0.1.0. Инструкция установки обновлена для RU/EN; переносимый ZIP остаётся в Releases.
