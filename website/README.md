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


Языки: русский `/brizfi-downloads/` и английский `/brizfi-downloads/en/`.
Обе страницы содержат полный HTML, alt, aria-label и метаданные без JavaScript.
Язык определяется адресом; автоматическая подмена по браузеру/localStorage убрана,
чтобы содержимое URL оставалось постоянным. languages.js переводит переключатель на другой URL.
Без JavaScript доступны ссылки выбора языка в noscript.

## SEO — 26.10.2026

Добавлены тематические title/description, canonical для каждой локали, взаимные
hreflang ru/en/x-default, Open Graph, Twitter Card, robots meta и sitemap.xml.
JSON-LD описывает WebSite, WebPage и SoftwareApplication без выдуманных отзывов,
рейтингов и цен. Расширенный результат Google для приложения не гарантируется.

После правки русского HTML или translations.en.json выполнить:
`python website/build_seo.py` из корня проекта. Генератор обновляет SEO-блоки,
статическую английскую страницу и sitemap; сторонних зависимостей нет.
Не редактировать en/index.html вручную.

Важная особенность GitHub Project Pages: поисковик читает robots.txt только по
`https://mkulkov.github.io/robots.txt`, а не внутри `/brizfi-downloads/`.
Подготовленный website/robots.txt нужно объединить с существующими правилами
корневого сайта mkulkov.github.io, если он управляется отдельно. Файл внутри
проекта сам по себе не управляет обходом. Отсутствие корневого robots.txt
не запрещает индексацию; sitemap можно отправить напрямую.

После подтверждённой публикации:
1. Проверить HTTP 200 для обеих локалей, sitemap, CSS/JS и изображений.
2. Добавить URL-prefix `https://mkulkov.github.io/brizfi-downloads/` в Google Search
   Console и Яндекс Вебмастер; вставлять только реально выданные коды проверки.
3. Отправить `https://mkulkov.github.io/brizfi-downloads/sitemap.xml` в оба сервиса
   и запросить переобход главной и /en/. Эти операции пока не выполнялись.

Публиковать только файлы сайта: index.html, en/index.html, languages.js,
sitemap.xml и robots.txt; styles.css/assets уже существуют. Перенос файлов
не означает разрешения публиковать ранее подготовленный релиз приложения.

Основные кнопки Windows скачивают BRIZFI-0.1.0-windows-x64-setup.exe из релиза v0.1.0. Инструкция установки обновлена для RU/EN; переносимый ZIP остаётся в Releases.


Обновление 2026-10-26: обе кнопки Windows ведут на установщик 0.1.1; обе кнопки Android — на подписанный APK 0.1.1+3 с GitHub. Русский и английский тексты обновлены.
