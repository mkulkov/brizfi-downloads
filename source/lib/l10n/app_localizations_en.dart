// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get intro =>
      'Select EPUB, FB2 or AZW3 up to 32 MiB. Books are converted on the phone. Keep BRIZFI open.';

  @override
  String get stopped => 'Connection stopped';

  @override
  String get waiting => 'Waiting for a reader';

  @override
  String get pending => 'Visitor requests access. Confirm only your reader.';

  @override
  String get allowed => 'Reader access allowed';

  @override
  String get transferred => 'File transferred';

  @override
  String get noBook => 'Choose a DRM-free EPUB, FB2 or AZW3 book';

  @override
  String get converting => 'Converting EPUB to AZW3…';

  @override
  String get convertingFb2 => 'Converting FB2 to AZW3…';

  @override
  String get cancelling =>
      'Cancellation requested. Waiting for conversion to finish…';

  @override
  String get cancel => 'Cancel conversion';

  @override
  String get cancelled =>
      'Conversion cancelled. Your source book is unchanged.';

  @override
  String get retryConversion => 'Retry conversion';

  @override
  String get conversionError =>
      'Could not convert this book. It may be damaged. Retry or choose another book.';

  @override
  String get protectedBook =>
      'Protected or encrypted books are not supported. Choose a DRM-free book.';

  @override
  String get conversionLimit =>
      'This book exceeds conversion limits. Choose a smaller or simpler book.';

  @override
  String get unsupportedEncoding =>
      'This text encoding is not supported. Choose a book encoded in UTF-8 or Windows-1251.';

  @override
  String get unsupportedBook =>
      'This book contains unsupported content. Choose another EPUB or FB2.';

  @override
  String get pick => 'Choose book';

  @override
  String get shareDeferred =>
      'A new book is waiting. Wait for the current operation or stop the download page.';

  @override
  String get shareBusy =>
      'One book is already waiting for import. Wait until it is ready, then share the next book again.';

  @override
  String get shareMultiple =>
      'Send one book at a time. Select one EPUB, FB2 or AZW3 and share it again.';

  @override
  String get shareInvalid =>
      'Could not receive the file. Share an EPUB, FB2 or AZW3 from a file app, or use Choose book.';

  @override
  String get clearBook => 'Remove selected book';

  @override
  String get cacheFull =>
      'There is not enough room for a temporary copy. Remove the selected book and retry. Old copies left after a crash expire automatically.';

  @override
  String get storageUnavailable =>
      'Could not save the temporary book. Free some space on your phone and retry.';

  @override
  String get importTooLarge =>
      'The book exceeds 32 MiB. Choose a smaller file.';

  @override
  String get importUnsupported =>
      'Choose a DRM-free EPUB, FB2, AZW3, MOBI, PDF or TXT book. This input format is not supported.';

  @override
  String get invalidBook =>
      'The file is empty or damaged. Choose another book.';

  @override
  String get network => 'Connection setup: select your Wi-Fi address';

  @override
  String get noNetwork => 'Not connected to Wi-Fi';

  @override
  String get start => 'Open download page';

  @override
  String get startReason => 'Choose a book and a local address to continue.';

  @override
  String get instructions =>
      'Open the complete address from the app in the Kindle browser, including http:// and the port. Tap Connect reader, compare the three-digit code and approve on your phone. When the list appears, tap Download book or Download all books. If the list does not appear, refresh the page. Access expires after 15 minutes.';

  @override
  String get approve => 'Allow this reader';

  @override
  String bytes(int count) {
    return 'Sent to HTTP response: $count bytes';
  }

  @override
  String get stop => 'Stop and revoke access';

  @override
  String get backgroundInterrupted =>
      'Transfer stopped when the app moved to the background. Your book is retained: open the download page again and allow the reader access.';

  @override
  String get networkInterrupted =>
      'The network changed or is unavailable. Your book is retained: connect to the same Wi-Fi network, open the page again, and use the new address on Kindle.';

  @override
  String get error =>
      'Could not complete the operation. Choose an EPUB, FB2 or AZW3 up to 32 MiB, check Wi-Fi, and try again.';

  @override
  String get notice =>
      'Use a trusted network: HTTP is not encrypted. After downloading, check the book on your Kindle. Keep this app open during transfer.';

  @override
  String get wifiMode => 'Wi-Fi';

  @override
  String get usbMode => 'USB';

  @override
  String get usbInstructions =>
      'Connect the device to your phone using a data/OTG cable. Connection is not restricted by brand. For USB storage and standard MTP devices, choose a destination folder in the system picker. For Kindle, allow USB access; if asked for a folder, choose Kindle → documents. For NOOK, choose its USB drive → My Files → Books → Use this folder. The folder is reused until disconnection. If Android does not mount the NOOK drive, use Wi-Fi. Some phones require enabling OTG.';

  @override
  String get usbWindowsInstructions =>
      'Connect Kindle or NOOK to the computer with a USB data cable. Click Find USB reader, check the detected reader and choose books. BRIZFI keeps supported originals and converts other supported inputs automatically. Safely eject the reader after transfer, then check that the books open.';

  @override
  String get usbFind => 'Find USB reader';

  @override
  String get usbNoReader => 'No USB reader found';

  @override
  String get usbSend => 'Send by USB';

  @override
  String get usbSendReason =>
      'Prepare a book and select a connected USB reader to send.';

  @override
  String get usbConnecting => 'Connecting to USB reader…';

  @override
  String get usbWriting => 'Writing book to reader…';

  @override
  String get usbVerifying => 'Verifying the written file…';

  @override
  String get usbCancel => 'Cancel transfer';

  @override
  String get usbCancelling =>
      'Cancellation requested. Waiting for the USB operation to finish…';

  @override
  String usbCompleted(int count, String name) {
    return 'File written and verified: $count bytes, $name. Disconnect the cable, check the Kindle library and open the book.';
  }

  @override
  String get usbNotFound =>
      'Reader disconnected. Check the cable and search for the USB reader again. The phone copy is retained.';

  @override
  String get usbPermission =>
      'USB reader access was denied. Send again and accept the system permission request.';

  @override
  String get usbUnsupported =>
      'The reader does not provide the MTP operations needed to write and verify files. Use Wi-Fi transfer.';

  @override
  String get usbOpenFailed =>
      'Android could not open the USB connection to the reader. Reconnect the cable and try again. You can transfer the book over Wi-Fi.';

  @override
  String get usbChooseFolder => 'Choose the documents folder on Kindle';

  @override
  String get usbReaderBusy =>
      'Another app is using the USB reader. Close the file manager and try again. You can transfer the book over Wi-Fi.';

  @override
  String get usbDocumentsMissing =>
      'The reader\'s book folder is unavailable. Reconnect the reader and search again.';

  @override
  String get usbFull =>
      'Not enough free space on the reader. Free up space and try again.';

  @override
  String get usbVerificationFailed =>
      'The written book failed verification. Check the cable and send again. The phone copy is retained.';

  @override
  String get usbTransferFailed =>
      'Could not write the book. Check the cable, free space and reader connection, then try again.';

  @override
  String get usbCancelled =>
      'USB transfer cancelled. The phone copy is retained.';

  @override
  String get usbUncertain =>
      'Transfer interrupted; a new incomplete brizfi- file may remain on the reader. Check it before retrying. The source copy is retained.';

  @override
  String get usbNotice =>
      'USB mode requires a direct phone-to-reader connection. Keep BRIZFI open until writing and verification finish. Kindle uses MTP; NOOK requires Android to mount its USB drive and a folder permission. Support depends on the phone and reader.';

  @override
  String get usbBusy =>
      'A USB operation or cleanup is still running. Wait for it to finish and send again.';

  @override
  String get pairingCodeTitle => 'Pairing code';

  @override
  String get pairingCodeCheck => 'Compare the code with your reader';

  @override
  String get pairingCodeApproved =>
      'Access is allowed for the reader with this code.';

  @override
  String pairingCodeSpoken(String code) {
    return 'Pairing code: $code';
  }

  @override
  String batchPrepared(int done, int total) {
    return 'Books prepared: $done of $total';
  }

  @override
  String batchPreparing(int current, int total) {
    return 'Preparing book $current of $total';
  }

  @override
  String get batchBookReady => 'Ready to send';

  @override
  String get batchBookWaiting => 'Waiting for preparation';

  @override
  String get batchBookFailed =>
      'Not prepared. Retry conversion or remove this book.';

  @override
  String get removeOneBook => 'Remove this book';

  @override
  String batchUsbProgress(int current, int total) {
    return 'USB: book $current of $total';
  }

  @override
  String get batchUsbVerified => 'Written and verified on reader';

  @override
  String batchUsbResult(int done, int total) {
    return 'Books written and verified: $done of $total';
  }

  @override
  String batchHttpResult(int done, int total) {
    return 'Files transferred: $done of $total';
  }

  @override
  String get removeSentBooks => 'Remove completed books from selection';

  @override
  String get batchLimit =>
      'Select up to 10 books at a time. Choose fewer files.';

  @override
  String get invalidSelection =>
      'Could not access the selected files. Select EPUB, FB2 or AZW3 again.';

  @override
  String get batchIntro =>
      'Choose up to 10 EPUB, FB2 or AZW3 books, up to 32 MiB each. Keep BRIZFI open.';

  @override
  String get pickBooks => 'Choose books';

  @override
  String get clearBooks => 'Remove all selected books';

  @override
  String get bookConverting => 'Converting…';

  @override
  String get bookCancelling => 'Cancelling…';

  @override
  String get bookCancelled => 'Cancelled';

  @override
  String get readerSubtitle => 'Local book transfer';

  @override
  String get readerConnection => 'Connection';

  @override
  String get readerInitialTitle => 'Connect your reader';

  @override
  String get readerInitialHint =>
      'Tap the button, then approve the connection in BRIZFI on your phone.';

  @override
  String get readerConnect => 'Connect reader';

  @override
  String get readerWaitingTitle => 'Compare the code';

  @override
  String get readerWaitingHint =>
      'The same code must appear on your phone. If it matches, approve the connection in BRIZFI.';

  @override
  String get readerCodeLabel => 'Your reader code';

  @override
  String get readerPendingStatus => 'Waiting for approval on your phone';

  @override
  String get readerRefresh => 'Refresh page';

  @override
  String get readerPause => 'Stop automatic updates';

  @override
  String get readerPairExpired =>
      'The request expired or the connection was interrupted. Refresh this page to continue.';

  @override
  String get readerPaused =>
      'Automatic updates stopped. After approval, tap Refresh page.';

  @override
  String get readerAutoHint => 'Your books will appear here after approval.';

  @override
  String get readerReadyTitle => 'Ready to download';

  @override
  String get readerReadyHint =>
      'Download the books, then open them in your Kindle library.';

  @override
  String get readerConnected => 'Reader connected';

  @override
  String get readerDownloadAll => 'Download all books';

  @override
  String get readerDownloadBook => 'Download book';

  @override
  String get readerDownloadOne => 'Download';

  @override
  String readerBooks(int count) {
    return 'Books · $count';
  }

  @override
  String get readerStarting => 'Starting downloads…';

  @override
  String get readerFailed =>
      'Queue stopped. Download books individually, or retry.';

  @override
  String get readerComplete =>
      'Files transferred. Check the books in the Kindle library.';

  @override
  String get readerStopped =>
      'Queue stopped. The current file may still be downloading.';

  @override
  String get readerStop => 'Stop queue';

  @override
  String readerDownloading(String current, String total) {
    return 'Downloading book $current of $total…';
  }

  @override
  String get readerFallback =>
      'If the download does not start, tap Download next to a book.';

  @override
  String get readerPrivacy => 'No cloud. Just your local Wi-Fi network.';

  @override
  String get aboutTitle => 'About';

  @override
  String get aboutDescription =>
      'BRIZFI transfers books locally from your phone to a reader, without registration, cloud services or internet access.';

  @override
  String get aboutWifi => 'Wi-Fi: on your phone';

  @override
  String get aboutPhoneSteps =>
      '1. Connect your phone and reader to the same Wi-Fi network.\n2. Choose books — ready files appear on the reader page automatically.\n3. Compare the code with your reader and approve the connection.';

  @override
  String get aboutReader => 'On the reader';

  @override
  String get aboutFormats => 'Formats and limits';

  @override
  String get aboutBatchLimits =>
      'EPUB and FB2 are converted to AZW3 on your phone. Existing AZW3 files are transferred unchanged. Select up to 10 books, up to 32 MiB each. If storage is full, choose fewer books. DRM-protected books are not supported.';

  @override
  String get aboutSingleLimits =>
      'EPUB and FB2 are converted to AZW3 on your phone. Existing AZW3 files are transferred unchanged. Books can be up to 32 MiB. DRM-protected books are not supported.';

  @override
  String get aboutPrivacy => 'Transfer and security';

  @override
  String get aboutUsbCompletion =>
      'When finished, safely disconnect the reader and open the books in its library. If only some books were transferred, remove completed books from the selection before retrying to avoid duplicates. This does not delete books on the reader.';

  @override
  String get selectBooksFirst => 'Choose books first';

  @override
  String get selectWifiFirst => 'Connect to Wi-Fi';

  @override
  String get selectUsbFirst => 'Select a USB reader';

  @override
  String get transferVerified => 'File transferred and verified';

  @override
  String get revokeReader => 'Disconnect reader';

  @override
  String get readerNoBooks => 'Choose books on your phone';

  @override
  String get readerNoBooksHint => 'Ready books will appear here automatically.';

  @override
  String get wifiAddressTitle => 'Enter in your reader’s browser';

  @override
  String get usbReaderTitle => 'USB reader';

  @override
  String get booksTitle => 'Books';

  @override
  String get journeyConnect => 'Let’s connect your devices';

  @override
  String get journeyChoose => 'Pack a book parcel';

  @override
  String get journeySending => 'Your books are on their way';

  @override
  String get journeyDone => 'Parcel delivered!';

  @override
  String get journeyConnectionStep => 'Connection';

  @override
  String get journeyBooksStep => 'Books';

  @override
  String get journeyTransferStep => 'Transfer';

  @override
  String get journeyHowSend => 'How would you like to send your books?';

  @override
  String get journeyContinue => 'Choose books';

  @override
  String get journeyAdd => 'Add books';

  @override
  String get journeySend => 'Send books';

  @override
  String get journeyAgain => 'Send more books';

  @override
  String get journeyEnd => 'End connection';

  @override
  String get journeyHelp => 'How do I connect?';

  @override
  String get journeyChange => 'Change';

  @override
  String get journeyConnected => 'Reader connected';

  @override
  String get journeyCompare => 'Compare the code on your reader';

  @override
  String get journeyApprove => 'The codes match';

  @override
  String get journeyDownload =>
      'On your reader, tap “Download book” or “Download all books”.';

  @override
  String get journeyKeepOpen => 'Keep the app open';

  @override
  String get journeyCheckLibrary => 'Check the books in your reader’s library';

  @override
  String get journeyWaiting => 'Waiting for the reader to download';

  @override
  String get journeyStop => 'Stop';

  @override
  String get journeyBack => 'Back';

  @override
  String get journeyReconnect => 'Reconnect your reader';

  @override
  String get journeyEmpty => 'Add books to your parcel';

  @override
  String get journeyChooseReason => 'Connect your reader first';

  @override
  String readerFormats(String formats) {
    return 'Formats sent without conversion: $formats';
  }

  @override
  String get readerFormatUnsupported =>
      'This reader cannot open this format and automatic conversion is not available for it. Choose a book in one of the reader\'s supported formats or select a different reader.';

  @override
  String readerOriginal(String format) {
    return '$format · Original, no conversion';
  }

  @override
  String readerConverted(String source, String target) {
    return '$source → $target';
  }

  @override
  String get windowsFormatsHelp =>
      'USB readers are identified using local device profiles. Kindle accepts AZW3, unprotected MOBI, PDF and TXT; EPUB and FB2 are converted to AZW3. NOOK accepts EPUB and PDF; FB2, AZW3, unprotected MOBI and UTF-8 TXT are converted to EPUB. TXT conversion is limited to 1.33 MiB. Conversion requires a DRM-free book. Up to 10 books, 32 MiB each. Wi-Fi currently uses the Kindle AZW3 profile. Other models and formats require separate verification.';

  @override
  String get usbWindowsNotice =>
      'USB transfer works locally. Keep BRIZFI open until writing and verification finish. Reader detection uses known device profiles; an unknown model is not assumed compatible.';

  @override
  String get wifiReaderType => 'Reader type';

  @override
  String get readerOther => 'Other';

  @override
  String get wifiReaderTypeHint =>
      'Choose your reader so BRIZFI prepares the right format.';

  @override
  String get usbNookChooseFolder =>
      'Choose My Files → Books on the NOOK USB drive';

  @override
  String get usbNookFolderMissing =>
      'Choose My Files → Books on the NOOK USB drive. If Android does not show that drive, check OTG support or use Wi-Fi.';

  @override
  String get androidFormatsHelp =>
      'USB identifies known Kindle and NOOK devices; choose the reader type for Wi-Fi. Supported originals are kept unchanged. Kindle: AZW3, unprotected MOBI, PDF and UTF-8 TXT; EPUB and FB2 are converted to AZW3. NOOK: EPUB/PDF; FB2, AZW3, unprotected MOBI and UTF-8 TXT are converted to EPUB. TXT conversion is limited to 1.33 MiB. Up to 10 books, 32 MiB each. DRM and unknown device profiles are not supported. Android must mount the NOOK USB drive for folder access.';

  @override
  String adsRemove(String price) {
    return 'Remove ads · $price';
  }

  @override
  String get adsPurchasing => 'Waiting for payment…';

  @override
  String get adsPurchaseFailed =>
      'The purchase was not completed. Ads are still enabled.';

  @override
  String get adsPrivacy =>
      'Android includes Yandex ads. Ads and ad removal purchases need internet; book transfers work locally. Ad and payment services process technical device and transaction data. Book contents and names are not sent to the ad network.';

  @override
  String get readerConfirmHint => 'Check the detected brand or choose another.';

  @override
  String get readerSaved => 'Reader choice saved';

  @override
  String get readerConfirm => 'Confirm reader';

  @override
  String readerModel(String model) {
    return 'Model: $model';
  }

  @override
  String get readerUnknownFormats =>
      'Books are sent in their original format. Whether they can be opened depends on the device.';

  @override
  String get readerSaveFailed =>
      'Could not save the reader choice. Try confirming again.';

  @override
  String get usbNoFileProtocol => 'No USB file access';
}
