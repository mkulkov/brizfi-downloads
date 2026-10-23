package ru.mkulkov.brizfi

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Parcelable
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.IOException
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val importer = Executors.newSingleThreadExecutor()
    private var pending: MethodChannel.Result? = null
    private var multiplePicker = false
    private var pickerResultIntent: Intent? = null
    private var pickerBatch: PickerImportBatch? = null
    private val sharedBooks = SharedBookInbox()
    private var pendingShareIntent: Intent? = null
    private var pendingShareResult: MethodChannel.Result? = null
    private var shareIntentConsumed = false
    private var channel: MethodChannel? = null
    private var usbTransfer: UsbBookTransfer? = null
    @Volatile private var disposed = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (savedInstanceState?.getBoolean(SHARE_CONSUMED) == true) {
            shareIntentConsumed = true
            clearShareIntent()
        } else {
            @Suppress("DEPRECATION")
            val savedIntent = savedInstanceState?.getParcelable<Intent>(PENDING_SHARE)
            receiveShare(savedIntent ?: intent)
        }
    }

    override fun onSaveInstanceState(outState: Bundle) {
        outState.putBoolean(SHARE_CONSUMED, shareIntentConsumed)
        pendingShareIntent?.let { outState.putParcelable(PENDING_SHARE, it) }
        super.onSaveInstanceState(outState)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        if (intent.action == Intent.ACTION_SEND || intent.action == Intent.ACTION_SEND_MULTIPLE) {
            receiveShare(intent)
        } else if (pendingShareIntent == null) {
            setIntent(intent)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        if (!resources.getBoolean(R.bool.brizfi_pay_enabled)) {
            // An uninitialized Pay plugin calls its SDK for *every* new intent,
            // including book shares. Remove its activity listener when unconfigured.
            flutterEngine.plugins.remove(ru.rustore.flutter_rustore_pay.FlutterRustorePayPlugin::class.java)
        }
        ReaderPreferences.register(this, flutterEngine.dartExecutor.binaryMessenger)
        MonetizationPreferences.register(this, flutterEngine.dartExecutor.binaryMessenger)
        usbTransfer = UsbBookTransfer(this,
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "ru.mkulkov.brizfi/usb"))
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "ru.mkulkov.brizfi/import")
        channel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "pickBook", "pickAzw3", "pickBooks" -> {
                    if (pending != null || sharedBooks.copying) {
                        result.error("busy", "An import is already pending.", null)
                    } else {
                        pending = result
                        multiplePicker = call.method == "pickBooks"
                        try {
                            startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                                addCategory(Intent.CATEGORY_OPENABLE)
                                type = "*/*"
                                putExtra(Intent.EXTRA_MIME_TYPES, SharedBookPolicy.mimeTypes.toTypedArray())
                                putExtra(Intent.EXTRA_ALLOW_MULTIPLE, multiplePicker)
                            }, PICK_BOOK)
                        } catch (_: Exception) {
                            completeError("unavailable")
                        }
                    }
                }
                "takeSharedBook" -> takeSharedBook(result)
                "reserveConversion", "finishConversion", "releaseImport", "clearExpiredImports" -> {
                    val path = (call.arguments as? Map<*, *>)?.get("path") as? String
                    if (call.method != "clearExpiredImports" && path == null) {
                        result.error("import_failed", "The managed copy is unavailable.", null)
                    } else if (call.method == "releaseImport" && usbTransfer?.usesImport(requireNotNull(path)) == true) {
                        result.error("busy", "The managed copy is still in use.", null)
                    } else runStorageOperation(result) { storage ->
                        when (call.method) {
                            "reserveConversion" -> storage.reserveConversion(requireNotNull(path))
                            "finishConversion" -> storage.finishConversion(requireNotNull(path))
                            "releaseImport" -> if (usbTransfer?.collectImportsIfIdle {
                                storage.releaseImport(requireNotNull(path))
                            } != true) {
                                throw ManagedImportStorage.Failure("busy")
                            }
                            else -> if (usbTransfer?.collectImportsIfIdle { storage.clearExpiredImports() } != true) {
                                throw ManagedImportStorage.Failure("busy")
                            }
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
        importer.execute {
            try { usbTransfer?.collectImportsIfIdle { storage().clearExpiredImports() } } catch (_: Exception) { }
        }
    }

    private fun receiveShare(incoming: Intent?) {
        if (incoming == null) return
        val selection = extractSharedBook(incoming) ?: return
        if (!sharedBooks.offer(selection)) {
            channel?.invokeMethod("shareRejected", "busy")
            return
        }
        // Retain the accepted Intent and its temporary content grant until consumption.
        pendingShareIntent = incoming
        shareIntentConsumed = false
        setIntent(incoming)
        channel?.invokeMethod("shareAvailable", null)
    }

    private fun extractSharedBook(incoming: Intent): SharedBookPolicy.Selection? {
        val action = incoming.action
        if (action == Intent.ACTION_SEND_MULTIPLE) {
            return SharedBookPolicy.Selection.Rejected("multiple_books")
        }
        if (action != Intent.ACTION_SEND) return null
        return try {
            val stream = if (Build.VERSION.SDK_INT >= 33) {
                incoming.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
            } else {
                @Suppress("DEPRECATION")
                val parcelable = incoming.getParcelableExtra<Parcelable>(Intent.EXTRA_STREAM)
                parcelable as? Uri
            }
            var malformed = incoming.hasExtra(Intent.EXTRA_STREAM) && stream == null
            val streamString = stream?.toString()
            val clipUris = mutableSetOf<String>()
            incoming.clipData?.let { clip ->
                if (clip.itemCount > SharedBookPolicy.MAX_CLIP_ITEMS) {
                    return SharedBookPolicy.Selection.Rejected("invalid_share")
                }
                for (index in 0 until clip.itemCount) {
                    val uri = clip.getItemAt(index).uri
                    if (uri == null) malformed = true else clipUris.add(uri.toString())
                    // More than one distinct URI is already sufficient to reject the share.
                    if (clipUris.size > 1 || (streamString != null && clipUris.any { it != streamString })) break
                }
            }
            SharedBookPolicy.select(action, incoming.type, streamString, clipUris.toList(), malformed)
        } catch (_: Exception) {
            SharedBookPolicy.Selection.Rejected("invalid_share")
        }
    }

    private fun takeSharedBook(result: MethodChannel.Result) {
        when (val taken = sharedBooks.take(pickerBusy = pending != null)) {
            SharedBookInbox.Take.Empty -> result.success(null)
            SharedBookInbox.Take.Busy -> result.error("busy", "An import is already pending.", null)
            is SharedBookInbox.Take.Ready -> {
                pendingShareIntent = null
                shareIntentConsumed = true
                // Activity recreation must not consume a completed or failed ACTION_SEND again.
                clearShareIntent()
                when (val selection = taken.selection) {
                    is SharedBookPolicy.Selection.Rejected ->
                        result.error(selection.code, "The shared book could not be imported.", null)
                    is SharedBookPolicy.Selection.Book -> {
                        pendingShareResult = result
                        importer.execute {
                            try {
                                val file = copyBook(Uri.parse(selection.uri))
                                runOnUiThread { if (!disposed) completeSharedBook(file.absolutePath, null) }
                            } catch (error: Exception) {
                                val code = if (error is SecurityException) "invalid_share" else errorCode(error)
                                runOnUiThread { if (!disposed) completeSharedBook(null, code) }
                            }
                        }
                    }
                }
            }
        }
    }

    private fun clearShareIntent() {
        setIntent(Intent(this, MainActivity::class.java).apply { action = Intent.ACTION_MAIN })
    }

    private fun completeSharedBook(path: String?, code: String?) {
        val result = pendingShareResult
        pendingShareResult = null
        sharedBooks.finishCopy()
        if (code == null) result?.success(path)
        else result?.error(code, "The shared book could not be imported.", null)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (usbTransfer?.onActivityResult(requestCode, resultCode, data) == true) return
        if (requestCode != PICK_BOOK || pending == null) return
        if (resultCode != Activity.RESULT_OK) {
            pending?.success(null)
            pending = null
            return
        }
        val selection = try {
            if ((data?.clipData?.itemCount ?: 0) > PickerSelection.MAX_CLIP_ITEMS) {
                completeError("too_many_books")
                return
            }
            val clips = data?.clipData?.let { clip ->
                (0 until clip.itemCount).map { clip.getItemAt(it).uri?.toString() }
            } ?: emptyList()
            PickerSelection.select(resultCode == Activity.RESULT_OK, data?.data?.toString(), clips, multiplePicker)
        } catch (_: Exception) {
            PickerSelection.Selection.Rejected("invalid_selection")
        }
        when (selection) {
            PickerSelection.Selection.Cancelled -> {
                pending?.success(null)
                pending = null
                return
            }
            is PickerSelection.Selection.Rejected -> {
                completeError(selection.code)
                return
            }
            is PickerSelection.Selection.Books -> Unit
        }
        // Keep the result Intent (and transient grants) alive throughout queued copying.
        pickerResultIntent = data
        val retainedIntent = data
        val batch = PickerImportBatch(storage())
        pickerBatch = batch
        val returnsList = multiplePicker
        importer.execute {
            try {
                val files = batch.copy(selection.uris, { copyBook(Uri.parse(it)) }) { disposed }
                runOnUiThread {
                    if (!disposed && pending != null) {
                        pending?.success(if (returnsList) files.map { it.absolutePath } else files.single().absolutePath)
                        batch.delivered()
                        pending = null
                        pickerBatch = null
                        pickerResultIntent = null
                    }
                }
            } catch (error: Exception) {
                batch.rollback()
                runOnUiThread { if (!disposed) completeError(errorCode(error)) }
            } finally {
                // A local strong reference covers the worker even during Activity teardown.
                java.lang.ref.Reference.reachabilityFence(retainedIntent)
            }
        }
    }

    private fun copyBook(uri: Uri): File {
        val name = contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use {
            if (it.moveToFirst()) it.getString(0) else null
        } ?: throw ImportFailure("unsupported_format")
        val extension = name.substringAfterLast('.', "").lowercase(java.util.Locale.ROOT)
        if (!SharedBookPolicy.supportsName(name)) throw ImportFailure("unsupported_format")
        val safeName = name.replace(Regex("[\\\\/\\p{Cntrl}:*?\"<>|]"), "_").take(180)
            .let { if (it.endsWith(".$extension", true)) it else it.take(174) + ".$extension" }
        return storage().importBook(safeName, {
            contentResolver.openInputStream(uri) ?: throw IOException()
        }) {
            disposed || Thread.currentThread().isInterrupted
        }
    }

    private fun storage() = ManagedImportStorage(File(cacheDir.canonicalFile, "brizfi_imports"))

    private fun runStorageOperation(result: MethodChannel.Result, operation: (ManagedImportStorage) -> Unit) {
        importer.execute {
            try {
                operation(storage())
                runOnUiThread { if (!disposed) result.success(null) }
            } catch (error: Exception) {
                val code = errorCode(error)
                runOnUiThread {
                    if (!disposed) result.error(code, "The managed copy is unavailable.", null)
                }
            }
        }
    }

    private fun errorCode(error: Exception) = when (error) {
        is ImportFailure -> error.code
        is ManagedImportStorage.Failure -> error.code
        is IOException, is SecurityException -> "storage_unavailable"
        else -> "import_failed"
    }

    private fun completeError(code: String) {
        pending?.error(code, "The selected book could not be imported.", null)
        pending = null
        pickerResultIntent = null
        pickerBatch = null
    }

    override fun onDestroy() {
        disposed = true
        usbTransfer?.dispose()
        channel?.setMethodCallHandler(null)
        val abandonedPicker = pickerBatch
        if (abandonedPicker != null) importer.execute { abandonedPicker.rollback() }
        completeError("cancelled")
        completeSharedBook(null, "cancelled")
        // Finish queued storage accounting. Process-wide Rust reservations survive teardown.
        importer.shutdown()
        super.onDestroy()
    }

    private class ImportFailure(val code: String) : IOException()

    companion object {
        private const val PICK_BOOK = 4701
        private const val SHARE_CONSUMED = "brizfi.share_consumed"
        private const val PENDING_SHARE = "brizfi.pending_share"
    }
}
