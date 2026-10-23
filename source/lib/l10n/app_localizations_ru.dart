// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Russian (`ru`).
class AppLocalizationsRu extends AppLocalizations {
  AppLocalizationsRu([String locale = 'ru']) : super(locale);

  @override
  String get intro =>
      'Выберите EPUB, FB2 или AZW3 до 32 МиБ. Книги преобразуются на телефоне. Оставьте BRIZFI открытым.';

  @override
  String get stopped => 'Соединение остановлено';

  @override
  String get waiting => 'Ожидание ридера';

  @override
  String get pending =>
      'Посетитель запрашивает доступ. Подтвердите только свой ридер.';

  @override
  String get allowed => 'Доступ ридеру разрешён';

  @override
  String get transferred => 'Файл передан';

  @override
  String get noBook => 'Выберите EPUB, FB2 или AZW3 без DRM';

  @override
  String get converting => 'Преобразование EPUB в AZW3…';

  @override
  String get convertingFb2 => 'Преобразование FB2 в AZW3…';

  @override
  String get cancelling =>
      'Отмена запрошена. Ожидаем завершения преобразования…';

  @override
  String get cancel => 'Отменить преобразование';

  @override
  String get cancelled => 'Преобразование отменено. Исходная книга сохранена.';

  @override
  String get retryConversion => 'Повторить преобразование';

  @override
  String get conversionError =>
      'Не удалось преобразовать книгу. Возможно, файл повреждён. Повторите или выберите другую книгу.';

  @override
  String get protectedBook =>
      'Защищённые и зашифрованные книги не поддерживаются. Выберите книгу без DRM.';

  @override
  String get conversionLimit =>
      'Книга превышает ограничения конвертера. Выберите книгу меньшего размера или более простой структуры.';

  @override
  String get unsupportedEncoding =>
      'Кодировка текста не поддерживается. Выберите книгу в UTF-8 или Windows-1251.';

  @override
  String get unsupportedBook =>
      'В книге есть неподдерживаемое содержимое. Выберите другой EPUB или FB2.';

  @override
  String get pick => 'Выбрать книгу';

  @override
  String get shareDeferred =>
      'Новая книга ожидает. Дождитесь текущей операции или остановите страницу скачивания.';

  @override
  String get shareBusy =>
      'Одна книга уже ожидает импорта. Дождитесь её подготовки, затем поделитесь следующей книгой ещё раз.';

  @override
  String get shareMultiple =>
      'Передавайте одну книгу за раз. Выберите один EPUB, FB2 или AZW3 и поделитесь им снова.';

  @override
  String get shareInvalid =>
      'Не удалось получить файл. Поделитесь EPUB, FB2 или AZW3 из файлового приложения либо используйте «Выбрать книгу».';

  @override
  String get clearBook => 'Убрать выбранную книгу';

  @override
  String get cacheFull =>
      'Не хватает места для временной копии. Уберите выбранную книгу и повторите. Старые копии после сбоя очищаются по сроку хранения.';

  @override
  String get storageUnavailable =>
      'Не удалось сохранить временную книгу. Освободите место на телефоне и повторите.';

  @override
  String get importTooLarge =>
      'Книга превышает 32 МиБ. Выберите файл меньшего размера.';

  @override
  String get importUnsupported =>
      'Выберите книгу EPUB, FB2, AZW3, MOBI, PDF или TXT без DRM. Этот входной формат не поддерживается.';

  @override
  String get invalidBook => 'Файл пустой или повреждён. Выберите другую книгу.';

  @override
  String get network => 'Настройка соединения: выберите адрес Wi-Fi';

  @override
  String get noNetwork => 'Нет подключения к Wi-Fi';

  @override
  String get start => 'Открыть страницу скачивания';

  @override
  String get startReason => 'Для продолжения выберите книгу и локальный адрес.';

  @override
  String get instructions =>
      'Откройте в браузере Kindle адрес из приложения целиком: с http:// и портом. Нажмите «Подключить ридер», сверьте трёхзначный код и разрешите подключение на телефоне. После появления списка нажмите «Скачать книгу» или «Скачать весь набор». Если список не появился, обновите страницу. Доступ действует 15 минут.';

  @override
  String get approve => 'Разрешить этому ридеру';

  @override
  String bytes(int count) {
    return 'Передано в HTTP-ответ: $count байт';
  }

  @override
  String get stop => 'Остановить и отозвать доступ';

  @override
  String get backgroundInterrupted =>
      'Передача остановлена при сворачивании. Книга сохранена: откройте страницу скачивания снова и разрешите доступ ридеру.';

  @override
  String get networkInterrupted =>
      'Сеть изменилась или недоступна. Книга сохранена: подключитесь к общей Wi-Fi сети, откройте страницу снова и используйте новый адрес на Kindle.';

  @override
  String get error =>
      'Не удалось выполнить операцию. Выберите EPUB, FB2 или AZW3 до 32 МиБ, проверьте Wi-Fi и повторите.';

  @override
  String get notice =>
      'Используйте доверенную сеть: HTTP не шифрует передачу. После скачивания проверьте книгу на Kindle. Во время передачи оставьте приложение открытым.';

  @override
  String get wifiMode => 'Wi-Fi';

  @override
  String get usbMode => 'USB';

  @override
  String get usbInstructions =>
      'Подключите устройство к телефону кабелем передачи данных/OTG. Марка не ограничивает подключение. Для USB-накопителей и обычных MTP-устройств выберите папку назначения в системном окне. Для Kindle разрешите USB-доступ; при запросе папки выберите Kindle → documents. Для NOOK выберите USB-накопитель → My Files → Books → Использовать эту папку. Папка запоминается до отключения. Если Android не показывает накопитель NOOK, используйте Wi-Fi. На некоторых телефонах нужно включить OTG.';

  @override
  String get usbWindowsInstructions =>
      'Подключите Kindle или NOOK к компьютеру USB-кабелем передачи данных. Нажмите «Найти USB-ридер», проверьте найденное устройство и выберите книги. Поддерживаемый оригинал передаётся без изменений, остальные доступные форматы преобразуются автоматически. После передачи безопасно извлеките ридер и проверьте открытие книг.';

  @override
  String get usbFind => 'Найти USB-ридер';

  @override
  String get usbNoReader => 'USB-ридер не найден';

  @override
  String get usbSend => 'Передать по USB';

  @override
  String get usbSendReason =>
      'Для передачи подготовьте книгу и выберите подключённый USB-ридер.';

  @override
  String get usbConnecting => 'Подключение к USB-ридеру…';

  @override
  String get usbWriting => 'Запись книги на ридер…';

  @override
  String get usbVerifying => 'Проверка записанного файла…';

  @override
  String get usbCancel => 'Отменить передачу';

  @override
  String get usbCancelling =>
      'Отмена запрошена. Ожидаем завершения USB-операции…';

  @override
  String usbCompleted(int count, String name) {
    return 'Файл записан и проверен: $count байт, $name. Отключите кабель, проверьте библиотеку Kindle и откройте книгу.';
  }

  @override
  String get usbNotFound =>
      'Ридер отключён. Проверьте кабель и повторите поиск USB-ридера. Книга на телефоне сохранена.';

  @override
  String get usbPermission =>
      'Доступ к USB-ридеру не разрешён. Нажмите передачу снова и подтвердите системный запрос.';

  @override
  String get usbUnsupported =>
      'Ридер не предоставляет необходимые функции MTP для записи и проверки. Используйте передачу по Wi-Fi.';

  @override
  String get usbOpenFailed =>
      'Android не смог открыть USB-соединение с ридером. Переподключите кабель и повторите. Можно передать книгу по Wi-Fi.';

  @override
  String get usbChooseFolder => 'Выберите папку documents на Kindle';

  @override
  String get usbReaderBusy =>
      'USB-ридер занят другим приложением. Закройте файловый менеджер и повторите. Можно передать книгу по Wi-Fi.';

  @override
  String get usbDocumentsMissing =>
      'Папка книг ридера недоступна. Подключите ридер заново и повторите поиск.';

  @override
  String get usbFull =>
      'На ридере недостаточно свободного места. Освободите место и повторите.';

  @override
  String get usbVerificationFailed =>
      'Проверка записанной книги не пройдена. Проверьте кабель и повторите передачу. Книга на телефоне сохранена.';

  @override
  String get usbTransferFailed =>
      'Не удалось записать книгу. Проверьте кабель, свободное место и подключение ридера, затем повторите.';

  @override
  String get usbCancelled =>
      'USB-передача отменена. Книга на телефоне сохранена.';

  @override
  String get usbUncertain =>
      'Передача прервана; на ридере могла остаться новая неполная копия brizfi-. Проверьте её перед повтором. Исходная копия сохранена.';

  @override
  String get usbNotice =>
      'USB требует прямого подключения телефона к ридеру. Держите BRIZFI открытым до завершения записи и проверки. Kindle использует MTP; для NOOK Android должен подключить USB-накопитель и предоставить доступ к папке. Совместимость зависит от телефона и ридера.';

  @override
  String get usbBusy =>
      'USB-операция или очистка ещё не завершена. Дождитесь её окончания и повторите передачу.';

  @override
  String get pairingCodeTitle => 'Код сопряжения';

  @override
  String get pairingCodeCheck => 'Сверьте код с ридером';

  @override
  String get pairingCodeApproved => 'Доступ разрешён ридеру с этим кодом.';

  @override
  String pairingCodeSpoken(String code) {
    return 'Код сопряжения: $code';
  }

  @override
  String batchPrepared(int done, int total) {
    return 'Подготовлено книг: $done из $total';
  }

  @override
  String batchPreparing(int current, int total) {
    return 'Подготовка книги $current из $total';
  }

  @override
  String get batchBookReady => 'Готова к передаче';

  @override
  String get batchBookWaiting => 'Ожидает подготовки';

  @override
  String get batchBookFailed =>
      'Не подготовлена. Повторите преобразование или уберите книгу.';

  @override
  String get removeOneBook => 'Убрать эту книгу';

  @override
  String batchUsbProgress(int current, int total) {
    return 'USB: книга $current из $total';
  }

  @override
  String get batchUsbVerified => 'Записана и проверена на ридере';

  @override
  String batchUsbResult(int done, int total) {
    return 'Передано и проверено: $done из $total';
  }

  @override
  String batchHttpResult(int done, int total) {
    return 'Передано: $done из $total';
  }

  @override
  String get removeSentBooks => 'Убрать переданные из набора';

  @override
  String get batchLimit =>
      'Можно выбрать до 10 книг за раз. Выберите меньше файлов.';

  @override
  String get invalidSelection =>
      'Не удалось получить выбранные файлы. Повторите выбор EPUB, FB2 или AZW3.';

  @override
  String get batchIntro =>
      'Выберите до 10 книг EPUB, FB2 или AZW3. До 32 МиБ каждая. Оставьте BRIZFI открытым.';

  @override
  String get pickBooks => 'Выбрать книги';

  @override
  String get clearBooks => 'Убрать все выбранные книги';

  @override
  String get bookConverting => 'Преобразование…';

  @override
  String get bookCancelling => 'Отмена…';

  @override
  String get bookCancelled => 'Отменено';

  @override
  String get readerSubtitle => 'Локальная передача книг';

  @override
  String get readerConnection => 'Подключение';

  @override
  String get readerInitialTitle => 'Подключите ридер';

  @override
  String get readerInitialHint =>
      'Нажмите кнопку и подтвердите подключение в BRIZFI на телефоне.';

  @override
  String get readerConnect => 'Подключить ридер';

  @override
  String get readerWaitingTitle => 'Сверьте код';

  @override
  String get readerWaitingHint =>
      'Этот же код должен быть на телефоне. Если он совпадает, разрешите подключение в BRIZFI.';

  @override
  String get readerCodeLabel => 'Код вашего ридера';

  @override
  String get readerPendingStatus => 'Ожидаем подтверждения на телефоне';

  @override
  String get readerRefresh => 'Обновить страницу';

  @override
  String get readerPause => 'Остановить автообновление';

  @override
  String get readerPairExpired =>
      'Запрос истёк или связь прервалась. Обновите страницу, чтобы продолжить.';

  @override
  String get readerPaused =>
      'Автообновление остановлено. После подтверждения нажмите «Обновить страницу».';

  @override
  String get readerAutoHint => 'После подтверждения здесь появятся книги.';

  @override
  String get readerReadyTitle => 'Можно скачивать';

  @override
  String get readerReadyHint =>
      'Скачайте книги и откройте их в библиотеке Kindle.';

  @override
  String get readerConnected => 'Ридер подключён';

  @override
  String get readerDownloadAll => 'Скачать весь набор';

  @override
  String get readerDownloadBook => 'Скачать книгу';

  @override
  String get readerDownloadOne => 'Скачать';

  @override
  String readerBooks(int count) {
    return 'Книги · $count';
  }

  @override
  String get readerStarting => 'Начинаем загрузку…';

  @override
  String get readerFailed =>
      'Очередь остановлена. Скачайте книги по отдельности или повторите попытку.';

  @override
  String get readerComplete =>
      'Файлы переданы. Проверьте книги в библиотеке Kindle.';

  @override
  String get readerStopped =>
      'Очередь остановлена. Текущий файл может продолжить скачиваться.';

  @override
  String get readerStop => 'Остановить очередь';

  @override
  String readerDownloading(String current, String total) {
    return 'Загрузка книги $current из $total…';
  }

  @override
  String get readerFallback =>
      'Если загрузка не началась, нажмите «Скачать» рядом с нужной книгой.';

  @override
  String get readerPrivacy => 'Без облака. Через вашу Wi-Fi сеть.';

  @override
  String get aboutTitle => 'О программе';

  @override
  String get aboutDescription =>
      'BRIZFI передаёт книги с телефона на ридер локально, без регистрации, облака и доступа к интернету.';

  @override
  String get aboutWifi => 'Wi-Fi: на телефоне';

  @override
  String get aboutPhoneSteps =>
      '1. Подключите телефон и ридер к общей Wi-Fi сети.\n2. Выберите книги — готовые файлы появятся на странице ридера автоматически.\n3. Сверьте код с ридером и разрешите подключение.';

  @override
  String get aboutReader => 'На ридере';

  @override
  String get aboutFormats => 'Форматы и ограничения';

  @override
  String get aboutBatchLimits =>
      'EPUB и FB2 преобразуются на телефоне в AZW3. Готовые AZW3 передаются без изменений. Можно выбрать до 10 книг, до 32 МиБ каждая. При нехватке места уменьшите набор. Защищённые DRM книги не поддерживаются.';

  @override
  String get aboutSingleLimits =>
      'EPUB и FB2 преобразуются на телефоне в AZW3. Готовые AZW3 передаются без изменений. Размер книги — до 32 МиБ. Защищённые DRM книги не поддерживаются.';

  @override
  String get aboutPrivacy => 'Передача и безопасность';

  @override
  String get aboutUsbCompletion =>
      'После завершения безопасно отключите ридер и откройте книги в его библиотеке. Если передана только часть набора, уберите переданные книги из выбора перед повтором, чтобы не создавать дубликаты. Это не удаляет книги на ридере.';

  @override
  String get selectBooksFirst => 'Сначала выберите книги';

  @override
  String get selectWifiFirst => 'Подключитесь к Wi-Fi';

  @override
  String get selectUsbFirst => 'Выберите USB-ридер';

  @override
  String get transferVerified => 'Файл передан и проверен';

  @override
  String get revokeReader => 'Отключить ридер';

  @override
  String get readerNoBooks => 'Выберите книги на телефоне';

  @override
  String get readerNoBooksHint => 'Готовые книги появятся здесь автоматически.';

  @override
  String get wifiAddressTitle => 'Введите в браузере ридера';

  @override
  String get usbReaderTitle => 'USB-ридер';

  @override
  String get booksTitle => 'Книги';

  @override
  String get journeyConnect => 'Познакомим устройства';

  @override
  String get journeyChoose => 'Соберём книжную посылку';

  @override
  String get journeySending => 'Книги уже в пути';

  @override
  String get journeyDone => 'Посылка доставлена!';

  @override
  String get journeyConnectionStep => 'Связь';

  @override
  String get journeyBooksStep => 'Книги';

  @override
  String get journeyTransferStep => 'Передача';

  @override
  String get journeyHowSend => 'Как отправим книги?';

  @override
  String get journeyContinue => 'Выбрать книги';

  @override
  String get journeyAdd => 'Добавить книги';

  @override
  String get journeySend => 'Отправить книги';

  @override
  String get journeyAgain => 'Отправить ещё книги';

  @override
  String get journeyEnd => 'Завершить подключение';

  @override
  String get journeyHelp => 'Как подключить?';

  @override
  String get journeyChange => 'Изменить';

  @override
  String get journeyConnected => 'Ридер подключён';

  @override
  String get journeyCompare => 'Сверьте код на ридере';

  @override
  String get journeyApprove => 'Код совпадает';

  @override
  String get journeyDownload =>
      'На ридере нажмите «Скачать книгу» или «Скачать весь набор».';

  @override
  String get journeyKeepOpen => 'Держите приложение открытым';

  @override
  String get journeyCheckLibrary => 'Проверьте книги в библиотеке ридера';

  @override
  String get journeyWaiting => 'Ожидаем скачивания на ридере';

  @override
  String get journeyStop => 'Остановить';

  @override
  String get journeyBack => 'Назад';

  @override
  String get journeyReconnect => 'Подключить ридер снова';

  @override
  String get journeyEmpty => 'Добавьте книги в посылку';

  @override
  String get journeyChooseReason => 'Сначала подключите ридер';

  @override
  String readerFormats(String formats) {
    return 'Оригиналы без преобразования: $formats';
  }

  @override
  String get readerFormatUnsupported =>
      'Ридер не открывает этот формат, а автоматическое преобразование для него пока недоступно. Выберите книгу в одном из поддерживаемых форматов или другой ридер.';

  @override
  String readerOriginal(String format) {
    return '$format · Оригинал, без преобразования';
  }

  @override
  String readerConverted(String source, String target) {
    return '$source → $target';
  }

  @override
  String get windowsFormatsHelp =>
      'USB-ридер определяется по локальному профилю устройства. Kindle принимает AZW3, MOBI без защиты, PDF и TXT; EPUB и FB2 преобразуются в AZW3. NOOK принимает EPUB и PDF; FB2, AZW3, MOBI без защиты и TXT UTF-8 преобразуются в EPUB. Преобразование TXT ограничено 1,33 МиБ. Конвертация требует книгу без DRM. До 10 книг по 32 МиБ. Wi-Fi пока использует профиль Kindle AZW3. Другие модели и форматы требуют отдельной проверки.';

  @override
  String get usbWindowsNotice =>
      'Передача по USB работает локально. Оставьте BRIZFI открытым до завершения записи и проверки. Обнаружение использует известные профили устройств; совместимость неизвестной модели не предполагается.';

  @override
  String get wifiReaderType => 'Тип ридера';

  @override
  String get readerOther => 'Другой';

  @override
  String get wifiReaderTypeHint =>
      'Выберите свой ридер, чтобы BRIZFI подготовил нужный формат.';

  @override
  String get usbNookChooseFolder =>
      'Выберите My Files → Books на USB-накопителе NOOK';

  @override
  String get usbNookFolderMissing =>
      'Выберите My Files → Books на USB-накопителе NOOK. Если Android не показывает этот накопитель, проверьте поддержку OTG или используйте Wi-Fi.';

  @override
  String get androidFormatsHelp =>
      'По USB определяются известные Kindle и NOOK; для Wi-Fi выберите тип ридера. Поддерживаемые оригиналы передаются без изменений. Kindle: AZW3, MOBI без защиты, PDF и TXT UTF-8; EPUB и FB2 преобразуются в AZW3. NOOK: EPUB/PDF; FB2, AZW3, MOBI без защиты и TXT UTF-8 преобразуются в EPUB. Преобразование TXT ограничено 1,33 МиБ. До 10 книг по 32 МиБ. DRM и неизвестные профили устройств не поддерживаются. Для доступа к папке NOOK Android должен подключить его USB-накопитель.';

  @override
  String adsRemove(String price) {
    return 'Отключить рекламу · $price';
  }

  @override
  String get adsPurchasing => 'Ожидаем оплату…';

  @override
  String get adsPurchaseFailed =>
      'Покупка не завершена. Реклама пока остаётся включённой.';

  @override
  String get adsPrivacy =>
      'В Android показывается реклама Яндекса. Для рекламы и покупки отключения нужен интернет; передача книг работает локально. Рекламный и платёжный сервисы обрабатывают технические данные устройства и операций. Содержимое книг и их названия не передаются рекламной сети.';

  @override
  String get readerConfirmHint =>
      'Проверьте определённую марку или выберите другую.';

  @override
  String get readerSaved => 'Выбор ридера сохранён';

  @override
  String get readerConfirm => 'Подтвердить ридер';

  @override
  String readerModel(String model) {
    return 'Модель: $model';
  }

  @override
  String get readerUnknownFormats =>
      'Книги передаются в исходном формате. Возможность открыть файл зависит от устройства.';

  @override
  String get readerSaveFailed =>
      'Не удалось сохранить выбор ридера. Повторите подтверждение.';

  @override
  String get usbNoFileProtocol => 'Нет файлового доступа по USB';
}
