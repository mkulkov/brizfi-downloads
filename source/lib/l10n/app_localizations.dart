import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_ru.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations? of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations);
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('ru'),
  ];

  /// No description provided for @intro.
  ///
  /// In en, this message translates to:
  /// **'Select EPUB, FB2 or AZW3 up to 32 MiB. Books are converted on the phone. Keep BRIZFI open.'**
  String get intro;

  /// No description provided for @stopped.
  ///
  /// In en, this message translates to:
  /// **'Connection stopped'**
  String get stopped;

  /// No description provided for @waiting.
  ///
  /// In en, this message translates to:
  /// **'Waiting for a reader'**
  String get waiting;

  /// No description provided for @pending.
  ///
  /// In en, this message translates to:
  /// **'Visitor requests access. Confirm only your reader.'**
  String get pending;

  /// No description provided for @allowed.
  ///
  /// In en, this message translates to:
  /// **'Reader access allowed'**
  String get allowed;

  /// No description provided for @transferred.
  ///
  /// In en, this message translates to:
  /// **'File transferred'**
  String get transferred;

  /// No description provided for @noBook.
  ///
  /// In en, this message translates to:
  /// **'Choose a DRM-free EPUB, FB2 or AZW3 book'**
  String get noBook;

  /// No description provided for @converting.
  ///
  /// In en, this message translates to:
  /// **'Converting EPUB to AZW3…'**
  String get converting;

  /// No description provided for @convertingFb2.
  ///
  /// In en, this message translates to:
  /// **'Converting FB2 to AZW3…'**
  String get convertingFb2;

  /// No description provided for @cancelling.
  ///
  /// In en, this message translates to:
  /// **'Cancellation requested. Waiting for conversion to finish…'**
  String get cancelling;

  /// No description provided for @cancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel conversion'**
  String get cancel;

  /// No description provided for @cancelled.
  ///
  /// In en, this message translates to:
  /// **'Conversion cancelled. Your source book is unchanged.'**
  String get cancelled;

  /// No description provided for @retryConversion.
  ///
  /// In en, this message translates to:
  /// **'Retry conversion'**
  String get retryConversion;

  /// No description provided for @conversionError.
  ///
  /// In en, this message translates to:
  /// **'Could not convert this book. It may be damaged. Retry or choose another book.'**
  String get conversionError;

  /// No description provided for @protectedBook.
  ///
  /// In en, this message translates to:
  /// **'Protected or encrypted books are not supported. Choose a DRM-free book.'**
  String get protectedBook;

  /// No description provided for @conversionLimit.
  ///
  /// In en, this message translates to:
  /// **'This book exceeds conversion limits. Choose a smaller or simpler book.'**
  String get conversionLimit;

  /// No description provided for @unsupportedEncoding.
  ///
  /// In en, this message translates to:
  /// **'This text encoding is not supported. Choose a book encoded in UTF-8 or Windows-1251.'**
  String get unsupportedEncoding;

  /// No description provided for @unsupportedBook.
  ///
  /// In en, this message translates to:
  /// **'This book contains unsupported content. Choose another EPUB or FB2.'**
  String get unsupportedBook;

  /// No description provided for @pick.
  ///
  /// In en, this message translates to:
  /// **'Choose book'**
  String get pick;

  /// No description provided for @shareDeferred.
  ///
  /// In en, this message translates to:
  /// **'A new book is waiting. Wait for the current operation or stop the download page.'**
  String get shareDeferred;

  /// No description provided for @shareBusy.
  ///
  /// In en, this message translates to:
  /// **'One book is already waiting for import. Wait until it is ready, then share the next book again.'**
  String get shareBusy;

  /// No description provided for @shareMultiple.
  ///
  /// In en, this message translates to:
  /// **'Send one book at a time. Select one EPUB, FB2 or AZW3 and share it again.'**
  String get shareMultiple;

  /// No description provided for @shareInvalid.
  ///
  /// In en, this message translates to:
  /// **'Could not receive the file. Share an EPUB, FB2 or AZW3 from a file app, or use Choose book.'**
  String get shareInvalid;

  /// No description provided for @clearBook.
  ///
  /// In en, this message translates to:
  /// **'Remove selected book'**
  String get clearBook;

  /// No description provided for @cacheFull.
  ///
  /// In en, this message translates to:
  /// **'There is not enough room for a temporary copy. Remove the selected book and retry. Old copies left after a crash expire automatically.'**
  String get cacheFull;

  /// No description provided for @storageUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Could not save the temporary book. Free some space on your phone and retry.'**
  String get storageUnavailable;

  /// No description provided for @importTooLarge.
  ///
  /// In en, this message translates to:
  /// **'The book exceeds 32 MiB. Choose a smaller file.'**
  String get importTooLarge;

  /// No description provided for @importUnsupported.
  ///
  /// In en, this message translates to:
  /// **'Choose a DRM-free EPUB, FB2, AZW3, MOBI, PDF or TXT book. This input format is not supported.'**
  String get importUnsupported;

  /// No description provided for @invalidBook.
  ///
  /// In en, this message translates to:
  /// **'The file is empty or damaged. Choose another book.'**
  String get invalidBook;

  /// No description provided for @network.
  ///
  /// In en, this message translates to:
  /// **'Connection setup: select your Wi-Fi address'**
  String get network;

  /// No description provided for @noNetwork.
  ///
  /// In en, this message translates to:
  /// **'Not connected to Wi-Fi'**
  String get noNetwork;

  /// No description provided for @start.
  ///
  /// In en, this message translates to:
  /// **'Open download page'**
  String get start;

  /// No description provided for @startReason.
  ///
  /// In en, this message translates to:
  /// **'Choose a book and a local address to continue.'**
  String get startReason;

  /// No description provided for @instructions.
  ///
  /// In en, this message translates to:
  /// **'Open the complete address from the app in the Kindle browser, including http:// and the port. Tap Connect reader, compare the three-digit code and approve on your phone. When the list appears, tap Download book or Download all books. If the list does not appear, refresh the page. Access expires after 15 minutes.'**
  String get instructions;

  /// No description provided for @approve.
  ///
  /// In en, this message translates to:
  /// **'Allow this reader'**
  String get approve;

  /// No description provided for @bytes.
  ///
  /// In en, this message translates to:
  /// **'Sent to HTTP response: {count} bytes'**
  String bytes(int count);

  /// No description provided for @stop.
  ///
  /// In en, this message translates to:
  /// **'Stop and revoke access'**
  String get stop;

  /// No description provided for @backgroundInterrupted.
  ///
  /// In en, this message translates to:
  /// **'Transfer stopped when the app moved to the background. Your book is retained: open the download page again and allow the reader access.'**
  String get backgroundInterrupted;

  /// No description provided for @networkInterrupted.
  ///
  /// In en, this message translates to:
  /// **'The network changed or is unavailable. Your book is retained: connect to the same Wi-Fi network, open the page again, and use the new address on Kindle.'**
  String get networkInterrupted;

  /// No description provided for @error.
  ///
  /// In en, this message translates to:
  /// **'Could not complete the operation. Choose an EPUB, FB2 or AZW3 up to 32 MiB, check Wi-Fi, and try again.'**
  String get error;

  /// No description provided for @notice.
  ///
  /// In en, this message translates to:
  /// **'Use a trusted network: HTTP is not encrypted. After downloading, check the book on your Kindle. Keep this app open during transfer.'**
  String get notice;

  /// No description provided for @wifiMode.
  ///
  /// In en, this message translates to:
  /// **'Wi-Fi'**
  String get wifiMode;

  /// No description provided for @usbMode.
  ///
  /// In en, this message translates to:
  /// **'USB'**
  String get usbMode;

  /// No description provided for @usbInstructions.
  ///
  /// In en, this message translates to:
  /// **'Connect the device to your phone using a data/OTG cable. Connection is not restricted by brand. For USB storage and standard MTP devices, choose a destination folder in the system picker. For Kindle, allow USB access; if asked for a folder, choose Kindle → documents. For NOOK, choose its USB drive → My Files → Books → Use this folder. The folder is reused until disconnection. If Android does not mount the NOOK drive, use Wi-Fi. Some phones require enabling OTG.'**
  String get usbInstructions;

  /// No description provided for @usbWindowsInstructions.
  ///
  /// In en, this message translates to:
  /// **'Connect Kindle or NOOK to the computer with a USB data cable. Click Find USB reader, check the detected reader and choose books. BRIZFI keeps supported originals and converts other supported inputs automatically. Safely eject the reader after transfer, then check that the books open.'**
  String get usbWindowsInstructions;

  /// No description provided for @usbFind.
  ///
  /// In en, this message translates to:
  /// **'Find USB reader'**
  String get usbFind;

  /// No description provided for @usbNoReader.
  ///
  /// In en, this message translates to:
  /// **'No USB reader found'**
  String get usbNoReader;

  /// No description provided for @usbSend.
  ///
  /// In en, this message translates to:
  /// **'Send by USB'**
  String get usbSend;

  /// No description provided for @usbSendReason.
  ///
  /// In en, this message translates to:
  /// **'Prepare a book and select a connected USB reader to send.'**
  String get usbSendReason;

  /// No description provided for @usbConnecting.
  ///
  /// In en, this message translates to:
  /// **'Connecting to USB reader…'**
  String get usbConnecting;

  /// No description provided for @usbWriting.
  ///
  /// In en, this message translates to:
  /// **'Writing book to reader…'**
  String get usbWriting;

  /// No description provided for @usbVerifying.
  ///
  /// In en, this message translates to:
  /// **'Verifying the written file…'**
  String get usbVerifying;

  /// No description provided for @usbCancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel transfer'**
  String get usbCancel;

  /// No description provided for @usbCancelling.
  ///
  /// In en, this message translates to:
  /// **'Cancellation requested. Waiting for the USB operation to finish…'**
  String get usbCancelling;

  /// No description provided for @usbCompleted.
  ///
  /// In en, this message translates to:
  /// **'File written and verified: {count} bytes, {name}. Disconnect the cable, check the Kindle library and open the book.'**
  String usbCompleted(int count, String name);

  /// No description provided for @usbNotFound.
  ///
  /// In en, this message translates to:
  /// **'Reader disconnected. Check the cable and search for the USB reader again. The phone copy is retained.'**
  String get usbNotFound;

  /// No description provided for @usbPermission.
  ///
  /// In en, this message translates to:
  /// **'USB reader access was denied. Send again and accept the system permission request.'**
  String get usbPermission;

  /// No description provided for @usbUnsupported.
  ///
  /// In en, this message translates to:
  /// **'The reader does not provide the MTP operations needed to write and verify files. Use Wi-Fi transfer.'**
  String get usbUnsupported;

  /// No description provided for @usbOpenFailed.
  ///
  /// In en, this message translates to:
  /// **'Android could not open the USB connection to the reader. Reconnect the cable and try again. You can transfer the book over Wi-Fi.'**
  String get usbOpenFailed;

  /// No description provided for @usbChooseFolder.
  ///
  /// In en, this message translates to:
  /// **'Choose the documents folder on Kindle'**
  String get usbChooseFolder;

  /// No description provided for @usbReaderBusy.
  ///
  /// In en, this message translates to:
  /// **'Another app is using the USB reader. Close the file manager and try again. You can transfer the book over Wi-Fi.'**
  String get usbReaderBusy;

  /// No description provided for @usbDocumentsMissing.
  ///
  /// In en, this message translates to:
  /// **'The reader\'s book folder is unavailable. Reconnect the reader and search again.'**
  String get usbDocumentsMissing;

  /// No description provided for @usbFull.
  ///
  /// In en, this message translates to:
  /// **'Not enough free space on the reader. Free up space and try again.'**
  String get usbFull;

  /// No description provided for @usbVerificationFailed.
  ///
  /// In en, this message translates to:
  /// **'The written book failed verification. Check the cable and send again. The phone copy is retained.'**
  String get usbVerificationFailed;

  /// No description provided for @usbTransferFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not write the book. Check the cable, free space and reader connection, then try again.'**
  String get usbTransferFailed;

  /// No description provided for @usbCancelled.
  ///
  /// In en, this message translates to:
  /// **'USB transfer cancelled. The phone copy is retained.'**
  String get usbCancelled;

  /// No description provided for @usbUncertain.
  ///
  /// In en, this message translates to:
  /// **'Transfer interrupted; a new incomplete brizfi- file may remain on the reader. Check it before retrying. The source copy is retained.'**
  String get usbUncertain;

  /// No description provided for @usbNotice.
  ///
  /// In en, this message translates to:
  /// **'USB mode requires a direct phone-to-reader connection. Keep BRIZFI open until writing and verification finish. Kindle uses MTP; NOOK requires Android to mount its USB drive and a folder permission. Support depends on the phone and reader.'**
  String get usbNotice;

  /// No description provided for @usbBusy.
  ///
  /// In en, this message translates to:
  /// **'A USB operation or cleanup is still running. Wait for it to finish and send again.'**
  String get usbBusy;

  /// No description provided for @pairingCodeTitle.
  ///
  /// In en, this message translates to:
  /// **'Pairing code'**
  String get pairingCodeTitle;

  /// No description provided for @pairingCodeCheck.
  ///
  /// In en, this message translates to:
  /// **'Compare the code with your reader'**
  String get pairingCodeCheck;

  /// No description provided for @pairingCodeApproved.
  ///
  /// In en, this message translates to:
  /// **'Access is allowed for the reader with this code.'**
  String get pairingCodeApproved;

  /// No description provided for @pairingCodeSpoken.
  ///
  /// In en, this message translates to:
  /// **'Pairing code: {code}'**
  String pairingCodeSpoken(String code);

  /// No description provided for @batchPrepared.
  ///
  /// In en, this message translates to:
  /// **'Books prepared: {done} of {total}'**
  String batchPrepared(int done, int total);

  /// No description provided for @batchPreparing.
  ///
  /// In en, this message translates to:
  /// **'Preparing book {current} of {total}'**
  String batchPreparing(int current, int total);

  /// No description provided for @batchBookReady.
  ///
  /// In en, this message translates to:
  /// **'Ready to send'**
  String get batchBookReady;

  /// No description provided for @batchBookWaiting.
  ///
  /// In en, this message translates to:
  /// **'Waiting for preparation'**
  String get batchBookWaiting;

  /// No description provided for @batchBookFailed.
  ///
  /// In en, this message translates to:
  /// **'Not prepared. Retry conversion or remove this book.'**
  String get batchBookFailed;

  /// No description provided for @removeOneBook.
  ///
  /// In en, this message translates to:
  /// **'Remove this book'**
  String get removeOneBook;

  /// No description provided for @batchUsbProgress.
  ///
  /// In en, this message translates to:
  /// **'USB: book {current} of {total}'**
  String batchUsbProgress(int current, int total);

  /// No description provided for @batchUsbVerified.
  ///
  /// In en, this message translates to:
  /// **'Written and verified on reader'**
  String get batchUsbVerified;

  /// No description provided for @batchUsbResult.
  ///
  /// In en, this message translates to:
  /// **'Books written and verified: {done} of {total}'**
  String batchUsbResult(int done, int total);

  /// No description provided for @batchHttpResult.
  ///
  /// In en, this message translates to:
  /// **'Files transferred: {done} of {total}'**
  String batchHttpResult(int done, int total);

  /// No description provided for @removeSentBooks.
  ///
  /// In en, this message translates to:
  /// **'Remove completed books from selection'**
  String get removeSentBooks;

  /// No description provided for @batchLimit.
  ///
  /// In en, this message translates to:
  /// **'Select up to 10 books at a time. Choose fewer files.'**
  String get batchLimit;

  /// No description provided for @invalidSelection.
  ///
  /// In en, this message translates to:
  /// **'Could not access the selected files. Select EPUB, FB2 or AZW3 again.'**
  String get invalidSelection;

  /// No description provided for @batchIntro.
  ///
  /// In en, this message translates to:
  /// **'Choose up to 10 EPUB, FB2 or AZW3 books, up to 32 MiB each. Keep BRIZFI open.'**
  String get batchIntro;

  /// No description provided for @pickBooks.
  ///
  /// In en, this message translates to:
  /// **'Choose books'**
  String get pickBooks;

  /// No description provided for @clearBooks.
  ///
  /// In en, this message translates to:
  /// **'Remove all selected books'**
  String get clearBooks;

  /// No description provided for @bookConverting.
  ///
  /// In en, this message translates to:
  /// **'Converting…'**
  String get bookConverting;

  /// No description provided for @bookCancelling.
  ///
  /// In en, this message translates to:
  /// **'Cancelling…'**
  String get bookCancelling;

  /// No description provided for @bookCancelled.
  ///
  /// In en, this message translates to:
  /// **'Cancelled'**
  String get bookCancelled;

  /// No description provided for @readerSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Local book transfer'**
  String get readerSubtitle;

  /// No description provided for @readerConnection.
  ///
  /// In en, this message translates to:
  /// **'Connection'**
  String get readerConnection;

  /// No description provided for @readerInitialTitle.
  ///
  /// In en, this message translates to:
  /// **'Connect your reader'**
  String get readerInitialTitle;

  /// No description provided for @readerInitialHint.
  ///
  /// In en, this message translates to:
  /// **'Tap the button, then approve the connection in BRIZFI on your phone.'**
  String get readerInitialHint;

  /// No description provided for @readerConnect.
  ///
  /// In en, this message translates to:
  /// **'Connect reader'**
  String get readerConnect;

  /// No description provided for @readerWaitingTitle.
  ///
  /// In en, this message translates to:
  /// **'Compare the code'**
  String get readerWaitingTitle;

  /// No description provided for @readerWaitingHint.
  ///
  /// In en, this message translates to:
  /// **'The same code must appear on your phone. If it matches, approve the connection in BRIZFI.'**
  String get readerWaitingHint;

  /// No description provided for @readerCodeLabel.
  ///
  /// In en, this message translates to:
  /// **'Your reader code'**
  String get readerCodeLabel;

  /// No description provided for @readerPendingStatus.
  ///
  /// In en, this message translates to:
  /// **'Waiting for approval on your phone'**
  String get readerPendingStatus;

  /// No description provided for @readerRefresh.
  ///
  /// In en, this message translates to:
  /// **'Refresh page'**
  String get readerRefresh;

  /// No description provided for @readerPause.
  ///
  /// In en, this message translates to:
  /// **'Stop automatic updates'**
  String get readerPause;

  /// No description provided for @readerPairExpired.
  ///
  /// In en, this message translates to:
  /// **'The request expired or the connection was interrupted. Refresh this page to continue.'**
  String get readerPairExpired;

  /// No description provided for @readerPaused.
  ///
  /// In en, this message translates to:
  /// **'Automatic updates stopped. After approval, tap Refresh page.'**
  String get readerPaused;

  /// No description provided for @readerAutoHint.
  ///
  /// In en, this message translates to:
  /// **'Your books will appear here after approval.'**
  String get readerAutoHint;

  /// No description provided for @readerReadyTitle.
  ///
  /// In en, this message translates to:
  /// **'Ready to download'**
  String get readerReadyTitle;

  /// No description provided for @readerReadyHint.
  ///
  /// In en, this message translates to:
  /// **'Download the books, then open them in your Kindle library.'**
  String get readerReadyHint;

  /// No description provided for @readerConnected.
  ///
  /// In en, this message translates to:
  /// **'Reader connected'**
  String get readerConnected;

  /// No description provided for @readerDownloadAll.
  ///
  /// In en, this message translates to:
  /// **'Download all books'**
  String get readerDownloadAll;

  /// No description provided for @readerDownloadBook.
  ///
  /// In en, this message translates to:
  /// **'Download book'**
  String get readerDownloadBook;

  /// No description provided for @readerDownloadOne.
  ///
  /// In en, this message translates to:
  /// **'Download'**
  String get readerDownloadOne;

  /// No description provided for @readerBooks.
  ///
  /// In en, this message translates to:
  /// **'Books · {count}'**
  String readerBooks(int count);

  /// No description provided for @readerStarting.
  ///
  /// In en, this message translates to:
  /// **'Starting downloads…'**
  String get readerStarting;

  /// No description provided for @readerFailed.
  ///
  /// In en, this message translates to:
  /// **'Queue stopped. Download books individually, or retry.'**
  String get readerFailed;

  /// No description provided for @readerComplete.
  ///
  /// In en, this message translates to:
  /// **'Files transferred. Check the books in the Kindle library.'**
  String get readerComplete;

  /// No description provided for @readerStopped.
  ///
  /// In en, this message translates to:
  /// **'Queue stopped. The current file may still be downloading.'**
  String get readerStopped;

  /// No description provided for @readerStop.
  ///
  /// In en, this message translates to:
  /// **'Stop queue'**
  String get readerStop;

  /// No description provided for @readerDownloading.
  ///
  /// In en, this message translates to:
  /// **'Downloading book {current} of {total}…'**
  String readerDownloading(String current, String total);

  /// No description provided for @readerFallback.
  ///
  /// In en, this message translates to:
  /// **'If the download does not start, tap Download next to a book.'**
  String get readerFallback;

  /// No description provided for @readerPrivacy.
  ///
  /// In en, this message translates to:
  /// **'No cloud. Just your local Wi-Fi network.'**
  String get readerPrivacy;

  /// No description provided for @aboutTitle.
  ///
  /// In en, this message translates to:
  /// **'About'**
  String get aboutTitle;

  /// No description provided for @aboutDescription.
  ///
  /// In en, this message translates to:
  /// **'BRIZFI transfers books locally from your phone to a reader, without registration, cloud services or internet access.'**
  String get aboutDescription;

  /// No description provided for @aboutWifi.
  ///
  /// In en, this message translates to:
  /// **'Wi-Fi: on your phone'**
  String get aboutWifi;

  /// No description provided for @aboutPhoneSteps.
  ///
  /// In en, this message translates to:
  /// **'1. Connect your phone and reader to the same Wi-Fi network.\n2. Choose books — ready files appear on the reader page automatically.\n3. Compare the code with your reader and approve the connection.'**
  String get aboutPhoneSteps;

  /// No description provided for @aboutReader.
  ///
  /// In en, this message translates to:
  /// **'On the reader'**
  String get aboutReader;

  /// No description provided for @aboutFormats.
  ///
  /// In en, this message translates to:
  /// **'Formats and limits'**
  String get aboutFormats;

  /// No description provided for @aboutBatchLimits.
  ///
  /// In en, this message translates to:
  /// **'EPUB and FB2 are converted to AZW3 on your phone. Existing AZW3 files are transferred unchanged. Select up to 10 books, up to 32 MiB each. If storage is full, choose fewer books. DRM-protected books are not supported.'**
  String get aboutBatchLimits;

  /// No description provided for @aboutSingleLimits.
  ///
  /// In en, this message translates to:
  /// **'EPUB and FB2 are converted to AZW3 on your phone. Existing AZW3 files are transferred unchanged. Books can be up to 32 MiB. DRM-protected books are not supported.'**
  String get aboutSingleLimits;

  /// No description provided for @aboutPrivacy.
  ///
  /// In en, this message translates to:
  /// **'Transfer and security'**
  String get aboutPrivacy;

  /// No description provided for @aboutUsbCompletion.
  ///
  /// In en, this message translates to:
  /// **'When finished, safely disconnect the reader and open the books in its library. If only some books were transferred, remove completed books from the selection before retrying to avoid duplicates. This does not delete books on the reader.'**
  String get aboutUsbCompletion;

  /// No description provided for @selectBooksFirst.
  ///
  /// In en, this message translates to:
  /// **'Choose books first'**
  String get selectBooksFirst;

  /// No description provided for @selectWifiFirst.
  ///
  /// In en, this message translates to:
  /// **'Connect to Wi-Fi'**
  String get selectWifiFirst;

  /// No description provided for @selectUsbFirst.
  ///
  /// In en, this message translates to:
  /// **'Select a USB reader'**
  String get selectUsbFirst;

  /// No description provided for @transferVerified.
  ///
  /// In en, this message translates to:
  /// **'File transferred and verified'**
  String get transferVerified;

  /// No description provided for @revokeReader.
  ///
  /// In en, this message translates to:
  /// **'Disconnect reader'**
  String get revokeReader;

  /// No description provided for @readerNoBooks.
  ///
  /// In en, this message translates to:
  /// **'Choose books on your phone'**
  String get readerNoBooks;

  /// No description provided for @readerNoBooksHint.
  ///
  /// In en, this message translates to:
  /// **'Ready books will appear here automatically.'**
  String get readerNoBooksHint;

  /// No description provided for @wifiAddressTitle.
  ///
  /// In en, this message translates to:
  /// **'Enter in your reader’s browser'**
  String get wifiAddressTitle;

  /// No description provided for @usbReaderTitle.
  ///
  /// In en, this message translates to:
  /// **'USB reader'**
  String get usbReaderTitle;

  /// No description provided for @booksTitle.
  ///
  /// In en, this message translates to:
  /// **'Books'**
  String get booksTitle;

  /// No description provided for @journeyConnect.
  ///
  /// In en, this message translates to:
  /// **'Let’s connect your devices'**
  String get journeyConnect;

  /// No description provided for @journeyChoose.
  ///
  /// In en, this message translates to:
  /// **'Pack a book parcel'**
  String get journeyChoose;

  /// No description provided for @journeySending.
  ///
  /// In en, this message translates to:
  /// **'Your books are on their way'**
  String get journeySending;

  /// No description provided for @journeyDone.
  ///
  /// In en, this message translates to:
  /// **'Parcel delivered!'**
  String get journeyDone;

  /// No description provided for @journeyConnectionStep.
  ///
  /// In en, this message translates to:
  /// **'Connection'**
  String get journeyConnectionStep;

  /// No description provided for @journeyBooksStep.
  ///
  /// In en, this message translates to:
  /// **'Books'**
  String get journeyBooksStep;

  /// No description provided for @journeyTransferStep.
  ///
  /// In en, this message translates to:
  /// **'Transfer'**
  String get journeyTransferStep;

  /// No description provided for @journeyHowSend.
  ///
  /// In en, this message translates to:
  /// **'How shall we send them?'**
  String get journeyHowSend;

  /// No description provided for @journeyContinue.
  ///
  /// In en, this message translates to:
  /// **'Choose books'**
  String get journeyContinue;

  /// No description provided for @journeyAdd.
  ///
  /// In en, this message translates to:
  /// **'Add books'**
  String get journeyAdd;

  /// No description provided for @journeySend.
  ///
  /// In en, this message translates to:
  /// **'Send books'**
  String get journeySend;

  /// No description provided for @journeyAgain.
  ///
  /// In en, this message translates to:
  /// **'Send more books'**
  String get journeyAgain;

  /// No description provided for @journeyEnd.
  ///
  /// In en, this message translates to:
  /// **'End connection'**
  String get journeyEnd;

  /// No description provided for @journeyHelp.
  ///
  /// In en, this message translates to:
  /// **'How do I connect?'**
  String get journeyHelp;

  /// No description provided for @journeyChange.
  ///
  /// In en, this message translates to:
  /// **'Change'**
  String get journeyChange;

  /// No description provided for @journeyConnected.
  ///
  /// In en, this message translates to:
  /// **'Reader connected'**
  String get journeyConnected;

  /// No description provided for @journeyCompare.
  ///
  /// In en, this message translates to:
  /// **'Compare the code on your reader'**
  String get journeyCompare;

  /// No description provided for @journeyApprove.
  ///
  /// In en, this message translates to:
  /// **'The codes match'**
  String get journeyApprove;

  /// No description provided for @journeyDownload.
  ///
  /// In en, this message translates to:
  /// **'On your reader, tap “Download book” or “Download all books”.'**
  String get journeyDownload;

  /// No description provided for @journeyKeepOpen.
  ///
  /// In en, this message translates to:
  /// **'Keep the app open'**
  String get journeyKeepOpen;

  /// No description provided for @journeyCheckLibrary.
  ///
  /// In en, this message translates to:
  /// **'Check the books in your reader’s library'**
  String get journeyCheckLibrary;

  /// No description provided for @journeyWaiting.
  ///
  /// In en, this message translates to:
  /// **'Waiting for the reader to download'**
  String get journeyWaiting;

  /// No description provided for @journeyStop.
  ///
  /// In en, this message translates to:
  /// **'Stop'**
  String get journeyStop;

  /// No description provided for @journeyBack.
  ///
  /// In en, this message translates to:
  /// **'Back'**
  String get journeyBack;

  /// No description provided for @journeyReconnect.
  ///
  /// In en, this message translates to:
  /// **'Reconnect your reader'**
  String get journeyReconnect;

  /// No description provided for @journeyEmpty.
  ///
  /// In en, this message translates to:
  /// **'Add books to your parcel'**
  String get journeyEmpty;

  /// No description provided for @journeyChooseReason.
  ///
  /// In en, this message translates to:
  /// **'Connect your reader first'**
  String get journeyChooseReason;

  /// No description provided for @readerFormats.
  ///
  /// In en, this message translates to:
  /// **'Supported originals: {formats}'**
  String readerFormats(String formats);

  /// No description provided for @readerFormatUnsupported.
  ///
  /// In en, this message translates to:
  /// **'This reader cannot open this format and automatic conversion is not available for it. Choose a book in one of the reader\'s supported formats or select a different reader.'**
  String get readerFormatUnsupported;

  /// No description provided for @readerOriginal.
  ///
  /// In en, this message translates to:
  /// **'{format} · Original, no conversion'**
  String readerOriginal(String format);

  /// No description provided for @readerConverted.
  ///
  /// In en, this message translates to:
  /// **'{source} → {target}'**
  String readerConverted(String source, String target);

  /// No description provided for @windowsFormatsHelp.
  ///
  /// In en, this message translates to:
  /// **'USB readers are identified using local device profiles. Kindle accepts AZW3, unprotected MOBI, PDF and TXT; EPUB and FB2 are converted to AZW3. NOOK accepts EPUB and PDF; FB2, AZW3, unprotected MOBI and UTF-8 TXT are converted to EPUB. TXT conversion is limited to 1.33 MiB. Conversion requires a DRM-free book. Up to 10 books, 32 MiB each. Wi-Fi currently uses the Kindle AZW3 profile. Other models and formats require separate verification.'**
  String get windowsFormatsHelp;

  /// No description provided for @usbWindowsNotice.
  ///
  /// In en, this message translates to:
  /// **'USB transfer works locally. Keep BRIZFI open until writing and verification finish. Reader detection uses known device profiles; an unknown model is not assumed compatible.'**
  String get usbWindowsNotice;

  /// No description provided for @wifiReaderType.
  ///
  /// In en, this message translates to:
  /// **'Reader type'**
  String get wifiReaderType;

  /// No description provided for @readerOther.
  ///
  /// In en, this message translates to:
  /// **'Other'**
  String get readerOther;

  /// No description provided for @wifiReaderTypeHint.
  ///
  /// In en, this message translates to:
  /// **'Choose your reader so BRIZFI prepares the right format.'**
  String get wifiReaderTypeHint;

  /// No description provided for @usbNookChooseFolder.
  ///
  /// In en, this message translates to:
  /// **'Choose My Files → Books on the NOOK USB drive'**
  String get usbNookChooseFolder;

  /// No description provided for @usbNookFolderMissing.
  ///
  /// In en, this message translates to:
  /// **'Choose My Files → Books on the NOOK USB drive. If Android does not show that drive, check OTG support or use Wi-Fi.'**
  String get usbNookFolderMissing;

  /// No description provided for @androidFormatsHelp.
  ///
  /// In en, this message translates to:
  /// **'USB identifies known Kindle and NOOK devices; choose the reader type for Wi-Fi. Supported originals are kept unchanged. Kindle: AZW3, unprotected MOBI, PDF and UTF-8 TXT; EPUB and FB2 are converted to AZW3. NOOK: EPUB/PDF; FB2, AZW3, unprotected MOBI and UTF-8 TXT are converted to EPUB. TXT conversion is limited to 1.33 MiB. Up to 10 books, 32 MiB each. DRM and unknown device profiles are not supported. Android must mount the NOOK USB drive for folder access.'**
  String get androidFormatsHelp;

  /// No description provided for @adsRemove.
  ///
  /// In en, this message translates to:
  /// **'Remove ads · {price}'**
  String adsRemove(String price);

  /// No description provided for @adsPurchasing.
  ///
  /// In en, this message translates to:
  /// **'Waiting for payment…'**
  String get adsPurchasing;

  /// No description provided for @adsPurchaseFailed.
  ///
  /// In en, this message translates to:
  /// **'The purchase was not completed. Ads are still enabled.'**
  String get adsPurchaseFailed;

  /// No description provided for @adsPrivacy.
  ///
  /// In en, this message translates to:
  /// **'Android includes Yandex ads. Ads and ad removal purchases need internet; book transfers work locally. Ad and payment services process technical device and transaction data. Book contents and names are not sent to the ad network.'**
  String get adsPrivacy;

  /// No description provided for @readerConfirmHint.
  ///
  /// In en, this message translates to:
  /// **'Check the detected brand or choose another.'**
  String get readerConfirmHint;

  /// No description provided for @readerSaved.
  ///
  /// In en, this message translates to:
  /// **'Reader choice saved'**
  String get readerSaved;

  /// No description provided for @readerConfirm.
  ///
  /// In en, this message translates to:
  /// **'Confirm reader'**
  String get readerConfirm;

  /// No description provided for @readerModel.
  ///
  /// In en, this message translates to:
  /// **'Model: {model}'**
  String readerModel(String model);

  /// No description provided for @readerUnknownFormats.
  ///
  /// In en, this message translates to:
  /// **'Books are sent in their original format. Whether they can be opened depends on the device.'**
  String get readerUnknownFormats;

  /// No description provided for @readerSaveFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not save the reader choice. Try confirming again.'**
  String get readerSaveFailed;

  /// No description provided for @usbNoFileProtocol.
  ///
  /// In en, this message translates to:
  /// **'No USB file access'**
  String get usbNoFileProtocol;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'ru'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'ru':
      return AppLocalizationsRu();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
