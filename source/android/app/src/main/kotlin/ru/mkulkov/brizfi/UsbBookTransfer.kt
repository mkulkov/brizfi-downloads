package ru.mkulkov.brizfi

import android.app.PendingIntent
import android.app.Activity
import android.net.Uri
import android.provider.DocumentsContract
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbManager
import android.mtp.MtpDevice
import android.mtp.MtpObjectInfo
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.os.Environment
import android.os.storage.StorageManager
import android.util.Log
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.UUID
import java.util.concurrent.Executors

/** Android USB-host MTP session. Cancellation waits for blocking native calls and cleanup. */
internal class UsbBookTransfer(private val context: Activity, private val channel: MethodChannel) {
    private val manager = context.getSystemService(Context.USB_SERVICE) as UsbManager
    private val worker = Executors.newSingleThreadExecutor()
    private val ui = Handler(Looper.getMainLooper())
    private val permissionAction = "${context.packageName}.USB_PERMISSION.${UUID.randomUUID()}"
    private var active: Job? = null
    private var disposed = false
    private var destination: Triple<Int, String, Uri>? = null

    private class Job(val device: UsbDevice, val path: String, val result: MethodChannel.Result,
                      val profile: UsbReaderProfile, val documents: Boolean = false) {
        val token = UUID.randomUUID().toString()
        @Volatile var cancelled = false
        @Volatile var detached = false
        var running = false
        var permission: PendingIntent? = null
        var tree: Uri? = null
        var folderPending = false
        val cancelResults = mutableListOf<MethodChannel.Result>()
    }

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action == UsbManager.ACTION_USB_DEVICE_DETACHED ||
                intent.action == UsbManager.ACTION_USB_DEVICE_ATTACHED) destination = null
            val job = active ?: return
            if (intent.action == permissionAction) {
                if (runCatching { intent.getStringExtra(REQUEST_TOKEN) }.getOrNull() != job.token || job.running) return
                job.permission?.cancel()
                job.permission = null
                val current = runCatching { attachedDevice(job) }.getOrNull()
                if (job.cancelled) finish(job, null, "usb_cancelled")
                else if (current == null || current.deviceName != job.device.deviceName) finish(job, null, "usb_not_found")
                else if (!runCatching { manager.hasPermission(current) }.getOrDefault(false)) finish(job, null, "usb_permission")
                else start(job)
            } else if (intent.action == UsbManager.ACTION_USB_DEVICE_DETACHED) {
                val detached = try {
                    if (Build.VERSION.SDK_INT >= 33) intent.getParcelableExtra(UsbManager.EXTRA_DEVICE, UsbDevice::class.java)
                    else {
                        @Suppress("DEPRECATION")
                        intent.getParcelableExtra<UsbDevice>(UsbManager.EXTRA_DEVICE)
                    }
                } catch (_: Exception) { null }
                if (detached?.deviceId != job.device.deviceId) return
                job.detached = true
                job.cancelled = true
                if (!job.running) finish(job, null, "usb_not_found")
            }
        }
    }

    init {
        val filter = IntentFilter(permissionAction).apply {
            addAction(UsbManager.ACTION_USB_DEVICE_DETACHED)
            addAction(UsbManager.ACTION_USB_DEVICE_ATTACHED)
        }
        if (Build.VERSION.SDK_INT >= 33) context.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        else {
            @Suppress("DEPRECATION")
            context.registerReceiver(receiver, filter)
        }
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "listDevices" -> {
                    try {
                        result.success(manager.deviceList.values.map {
                            val descriptor = descriptor(it)
                            val reader = UsbReaderIdentification.discover(descriptor, profile(it))
                            val identity = readerIdentity(it, descriptor)
                            mapOf("id" to it.deviceId, "name" to reader.name,
                                "brand" to reader.brand, "profile" to reader.profile,
                                "transport" to reader.transport, "formats" to reader.formats,
                                "model" to null, "identityKey" to identity.first,
                                "identityIsUnique" to identity.second)
                        })
                    } catch (_: Exception) { error(result, "usb_not_found") }
                }
                "sendBook", "sendBookViaDocuments" -> {
                    val arguments = call.arguments as? Map<*, *>
                    val id = arguments?.get("deviceId") as? Int
                    val path = arguments?.get("path") as? String
                    if (id == null || path == null) error(result, "usb_invalid_file")
                    else send(id, path, result, call.method == "sendBookViaDocuments")
                }
                "cancel" -> cancel(result)
                else -> result.notImplemented()
            }
        }
    }

    private fun descriptor(device: UsbDevice) = UsbReaderIdentification.Descriptor(
        device.vendorId, device.productId,
        runCatching { device.manufacturerName }.getOrNull(),
        runCatching { device.productName }.getOrNull(),
        (0 until device.interfaceCount).map { index ->
            device.getInterface(index).let {
                UsbReaderIdentification.Interface(it.interfaceClass, it.interfaceSubclass, it.interfaceProtocol)
            }
        })

    private fun readerIdentity(device: UsbDevice,
                               descriptor: UsbReaderIdentification.Descriptor): Pair<String, Boolean> {
        // Identification must never request access or open the USB device.
        val serial = if (manager.hasPermission(device))
            runCatching { device.serialNumber }.getOrNull() else null
        return UsbReaderIdentification.identity(descriptor, serial)
    }

    private fun profile(device: UsbDevice): UsbReaderProfile? {
        val known = UsbReaderProfile.forUsb(device.vendorId, device.productId)
        val interfaces = descriptor(device).interfaces
        if (known != null && interfaces.any {
            if (known == UsbReaderProfile.KINDLE) isKindleMtpInterface(device.vendorId, device.productId,
                it.deviceClass, it.subclass, it.protocol)
            else isNookMassStorageInterface(device.vendorId, device.productId,
                it.deviceClass, it.subclass, it.protocol)
        }) return known
        return when {
            interfaces.any { it == UsbReaderIdentification.Interface(8, 6, 80) } -> UsbReaderProfile.GENERIC_STORAGE
            interfaces.any { it == UsbReaderIdentification.Interface(6, 1, 1) } -> UsbReaderProfile.GENERIC_MTP
            else -> null
        }
    }

    private fun supported(device: UsbDevice): Boolean = profile(device) != null

    private fun matchingDevice(id: Int): UsbDevice? = manager.deviceList.values.firstOrNull {
        it.deviceId == id && supported(it)
    }

    private fun attachedDevice(job: Job): UsbDevice? = matchingDevice(job.device.deviceId)?.takeIf {
        it.deviceName == job.device.deviceName && it.vendorId == job.device.vendorId &&
            it.productId == job.device.productId && profile(it) == job.profile
    }

    private fun send(id: Int, path: String, result: MethodChannel.Result, documents: Boolean = false) {
        if (disposed) { error(result, "usb_cancelled"); return }
        if (active != null) { error(result, "busy"); return }
        val device = runCatching { matchingDevice(id) }.getOrNull()
        if (device == null) { error(result, "usb_not_found"); return }
        if (!lease.claim(path)) { error(result, "busy"); return }
        val profile = profile(device) ?: run { lease.release(path); error(result, "usb_unsupported"); return }
        // A NOOK never enters raw USB permission/open/recovery paths: Android's
        // storage provider owns mass storage, authorized only by the SAF picker.
        val job = Job(device, path, result, profile, documents || profile.usesSaf)
        active = job
        channel.invokeMethod("phase", "connecting")
        try {
            if (job.documents) {
                job.tree = destination?.takeIf { it.first == id && it.second == device.deviceName }?.third
                if (job.tree != null) start(job)
                else {
                    job.folderPending = true
                    channel.invokeMethod("phase", "selectingFolder")
                    context.startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
                    }, PICK_USB_FOLDER)
                }
            } else if (manager.hasPermission(device)) start(job)
            else {
                val permission = PendingIntent.getBroadcast(context, id,
                    Intent(permissionAction).setPackage(context.packageName).putExtra(REQUEST_TOKEN, job.token),
                    PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_CANCEL_CURRENT)
                job.permission = permission
                manager.requestPermission(device, permission)
            }
        } catch (_: Exception) { finish(job, null, "usb_permission") }
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != PICK_USB_FOLDER) return false
        val job = active?.takeIf { it.documents && it.folderPending } ?: return true
        job.folderPending = false
        if (job.cancelled || resultCode != Activity.RESULT_OK) {
            finish(job, null, "usb_cancelled")
            return true
        }
        val tree = data?.data
        val permissions = Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
        if (tree == null || ((data?.flags ?: 0) and permissions) != permissions ||
            !runCatching { validTree(job.profile, tree) }.getOrDefault(false)) {
            finish(job, null, "usb_documents_missing")
            return true
        }
        val device = runCatching { attachedDevice(job) }.getOrNull()
        if (device == null || device.deviceName != job.device.deviceName) {
            finish(job, null, "usb_not_found")
            return true
        }
        job.tree = tree
        destination = Triple(device.deviceId, device.deviceName, tree)
        start(job)
        return true
    }

    private fun validTree(profile: UsbReaderProfile, tree: Uri): Boolean {
        if (tree.scheme != "content" || tree.query != null || tree.fragment != null ||
            !DocumentsContract.isTreeUri(tree)) return false
        val id = DocumentsContract.getTreeDocumentId(tree)
        val volumes = if (profile.usesSystemStorage) {
            val storage = context.getSystemService(Context.STORAGE_SERVICE) as StorageManager
            // API 24+ methods: valid for the project's API 29 minimum. UUIDs and
            // labels cannot establish which USB device backs a public SAF tree.
            storage.storageVolumes.map {
                UsbSafFolderPolicy.Volume(it.uuid, it.isRemovable, it.isPrimary, it.state == Environment.MEDIA_MOUNTED)
            }
        } else emptyList()
        return UsbSafFolderPolicy.accepts(profile, tree.authority, id, volumes)
    }

    private fun start(job: Job) {
        if (active !== job || job.running) return
        job.running = true
        worker.execute {
            var closePort: (() -> Unit)? = null
            var receipt: UsbTransferCore.Receipt? = null
            var code: String? = null
            try {
                if (job.cancelled) throw UsbTransferFailure("usb_cancelled")
                val source = UsbBookSource.inspect(File(context.cacheDir.canonicalFile, "brizfi_imports"), job.path, job.profile) {
                    job.cancelled
                }
                if (job.cancelled) throw UsbTransferFailure("usb_cancelled")
                val device = attachedDevice(job) ?: throw UsbTransferFailure("usb_not_found")
                if (job.documents) {
                    val tree = job.tree ?: throw UsbTransferFailure("usb_documents_missing")
                    val guard = {
                        if (job.cancelled) throw UsbTransferFailure("usb_cancelled")
                        val attached = attachedDevice(job)
                        if (attached == null) {
                            throw UsbTransferFailure("usb_not_found")
                        }
                        if (!validTree(job.profile, tree)) throw UsbTransferFailure("usb_documents_missing")
                    }
                    guard()
                    receipt = UsbDocumentTransfer(AndroidUsbDocumentPort(context.contentResolver,
                        tree, job.profile, guard),
                        { job.cancelled }, { value ->
                            ui.post { if (!disposed && active === job) channel.invokeMethod("phase", value) }
                        }, job.profile).transfer(source)
                    guard()
                } else {
                    if (!manager.hasPermission(device)) throw UsbTransferFailure("usb_permission")
                    if (UsbRecovery.applies(device)) {
                        val recovery = UsbRecovery.prepare(manager, device) { job.cancelled }
                        if (context.applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE != 0) {
                            Log.w("BrizfiUsb", "preflight result=$recovery")
                        }
                    }
                    val connection = manager.openDevice(device) ?: throw UsbTransferFailure("usb_permission")
                    val vendorMtp = device.vendorId == 0x1949 && device.productId == 0x9981 &&
                        (0 until device.interfaceCount).any { index ->
                            device.getInterface(index).let {
                                it.interfaceClass == 255 && it.interfaceSubclass == 255 && it.interfaceProtocol == 0
                            }
                        }
                    val port: UsbMtpPort = if (vendorMtp) {
                        // This factory owns the connection, including failures. No STRING probing.
                        val diagnostic: (Int, String) -> Unit = { operation, stage ->
                            if (context.applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE != 0) {
                                Log.w("BrizfiUsb", "MTP op=${operation.toString(16)} phase=$stage")
                            }
                        }
                        val direct = try {
                            UsbBulkMtpPort.open(device, connection, diagnostic) { job.cancelled }
                        } catch (failure: UsbTransferFailure) {
                            if (failure.code == "usb_transfer_failed") throw UsbTransferFailure("usb_open_failed")
                            throw failure
                        }
                        direct.also { closePort = it::close }
                    } else {
                        val mtp = try { MtpDevice(device) } catch (_: Exception) {
                            connection.close()
                            throw UsbTransferFailure("usb_open_failed")
                        }
                        closePort = mtp::close
                        // Android open owns/also closes the connection even on failure.
                        if (!mtp.open(connection)) throw UsbTransferFailure("usb_open_failed")
                        AndroidMtpPort(mtp)
                    }
                    receipt = UsbTransferCore(port, { job.cancelled }, { value ->
                        ui.post { if (!disposed && active === job) channel.invokeMethod("phase", value) }
                    }).transfer(source)
                }
            } catch (failure: UsbTransferFailure) { code = failure.code }
            catch (_: Exception) { code = if (job.cancelled) "usb_cancelled" else "usb_transfer_failed" }
            finally {
                // No cancellation result is delivered until MTP and every source descriptor have closed.
                try { closePort?.invoke() } catch (_: Exception) { if (receipt != null) code = "usb_uncertain" }
                ui.post { finish(job, receipt, code) }
            }
        }
    }

    private fun cancel(result: MethodChannel.Result) {
        val job = active
        if (job == null) { result.success(null); return }
        job.cancelResults.add(result)
        job.cancelled = true
        if (!job.running) finish(job, null, "usb_cancelled")
        // sendObject/getPartialObject cannot be interrupted through public MTP APIs.
    }

    private fun finish(job: Job, receipt: UsbTransferCore.Receipt?, code: String?) {
        if (active !== job) return
        if (job.folderPending) {
            job.folderPending = false
            runCatching { context.finishActivity(PICK_USB_FOLDER) }
        }
        active = null
        if (job.documents && code != null) destination = null
        lease.release(job.path)
        job.permission?.cancel()
        job.permission = null
        if (code != null) error(job.result, code)
        else if (receipt != null) job.result.success(mapOf("bytes" to receipt.bytes, "name" to receipt.name))
        else error(job.result, "usb_transfer_failed")
        job.cancelResults.forEach { it.success(null) }
        job.cancelResults.clear()
    }

    /** Prevent the import channel from releasing the source directory while native reads may still run. */
    fun usesImport(path: String): Boolean {
        return lease.usesImport(path)
    }

    fun collectImportsIfIdle(operation: () -> Unit): Boolean = lease.collectIfIdle(operation)

    fun dispose() {
        if (disposed) return
        disposed = true
        channel.setMethodCallHandler(null)
        runCatching { context.unregisterReceiver(receiver) }
        active?.let { job ->
            job.cancelled = true
            job.permission?.cancel()
            if (!job.running) finish(job, null, "usb_cancelled")
        }
        // Running MTP calls finish and close on the worker before sendBook/cancel resolve.
        worker.shutdown()
    }

    private fun error(result: MethodChannel.Result, code: String) {
        result.error(code, "USB book transfer could not complete.", null)
    }

    private class AndroidMtpPort(private val device: MtpDevice) : UsbMtpPort {
        override fun operations() = device.deviceInfo?.operationsSupported
        override fun storages() = device.storageIds
        override fun freeBytes(storage: Int) = device.getStorageInfo(storage)?.freeSpace
        override fun handles(storage: Int, parent: Int) = device.getObjectHandles(storage, 0, parent)
        override fun info(handle: Int) = device.getObjectInfo(handle)?.toInfo()
        override fun create(storage: Int, parent: Int, name: String, bytes: Long) = device.sendObjectInfo(
            MtpObjectInfo.Builder().setStorageId(storage).setParent(parent).setName(name)
                .setFormat(0x3000).setProtectionStatus(0).setCompressedSize(bytes).build()
        )?.toInfo()
        override fun send(handle: Int, source: UsbBookSource.Source): Boolean =
            ParcelFileDescriptor.open(source.file, ParcelFileDescriptor.MODE_READ_ONLY).use { descriptor ->
                device.sendObject(handle, source.bytes, descriptor)
            }
        override fun read(handle: Int, offset: Long, length: Int, buffer: ByteArray) =
            device.getPartialObject(handle, offset, length.toLong(), buffer)
        override fun delete(handle: Int) = device.deleteObject(handle)
        private fun MtpObjectInfo.toInfo() = UsbMtpPort.ObjectInfo(objectHandle, storageId, parent,
            format, protectionStatus, name, compressedSizeLong)
    }

    companion object {
        private const val PICK_USB_FOLDER = 60041
        private const val REQUEST_TOKEN = "brizfi.usb_request"
        private val lease = UsbTransferLease()
    }
}
