package ru.mkulkov.brizfi

/** Verified reader profiles plus generic file transports. Names do not grant capabilities. */
internal enum class UsbReaderProfile(
    val key: String, val label: String, val transport: String, val formats: Set<String>,
) {
    KINDLE("kindle", "Kindle", "mtp", setOf("azw3", "mobi", "pdf", "txt")),
    NOOK("nook", "NOOK", "massStorage", setOf("epub", "pdf")),
    GENERIC_STORAGE("generic-storage", "USB reader", "massStorage", setOf("azw3", "mobi", "epub", "pdf", "txt")),
    GENERIC_MTP("generic-mtp", "USB reader", "mtp", setOf("azw3", "mobi", "epub", "pdf", "txt"));

    val usesSystemStorage: Boolean get() = this == NOOK || this == GENERIC_STORAGE
    val usesSaf: Boolean get() = this != KINDLE
    val authority: String get() = if (usesSystemStorage) EXTERNAL_AUTHORITY else MTP_AUTHORITY

    companion object {
        const val MTP_AUTHORITY = "com.android.mtp.documents"
        const val EXTERNAL_AUTHORITY = "com.android.externalstorage.documents"
        fun forUsb(vendor: Int, product: Int): UsbReaderProfile? = when (vendor to product) {
            0x1949 to 0x9981 -> KINDLE
            0x2080 to 0x0003 -> NOOK
            else -> null
        }
    }
}

/** Public SAF does not expose a USB-device-to-volume association. The user must
 * explicitly choose the removable volume; UUID/name are not hardware proof. */
internal object UsbSafFolderPolicy {
    data class Volume(val uuid: String?, val removable: Boolean, val primary: Boolean, val mounted: Boolean)
    private val uuid = Regex("(?:[0-9a-fA-F]{4}-[0-9a-fA-F]{4}|[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12})")

    fun accepts(profile: UsbReaderProfile, authority: String?, id: String, volumes: List<Volume>): Boolean {
        if (authority != profile.authority || id.isEmpty() || id.length > 1024 || '\u0000' in id) return false
        if (!profile.usesSystemStorage) return true // Opaque MTP ID; folder name checked independently.
        val parts = id.split(':')
        if (parts.size != 2 || !uuid.matches(parts[0])) return false
        if (profile == UsbReaderProfile.NOOK) {
            if (parts[1] != "My Files/Books") return false
        } else if (!safeStoragePath(parts[1])) return false
        return volumes.singleOrNull { it.uuid.equals(parts[0], ignoreCase = true) }
            ?.let { it.removable && !it.primary && it.mounted } == true
    }

    private fun safeStoragePath(path: String): Boolean = path.isEmpty() ||
        path.split('/').all { it.isNotEmpty() && it != "." && it != ".." &&
            it.none { char -> char == '\\' || char == ':' || char.isISOControl() } }

    fun storageDocumentId(root: String, id: String): Boolean {
        val rootParts = root.split(':')
        if (root.length > 1024 || rootParts.size != 2 || !uuid.matches(rootParts[0]) ||
            !safeStoragePath(rootParts[1])) return false
        if (id.isEmpty() || id.length > 1024 || '\u0000' in id) return false
        if (id == root) return true
        val prefix = if (root.endsWith(':')) root else "$root/"
        if (!id.startsWith(prefix)) return false
        val child = id.removePrefix(prefix)
        return child.isNotEmpty() && '/' !in child && safeStoragePath(child)
    }

    fun folderName(profile: UsbReaderProfile, name: String): Boolean = when (profile) {
        UsbReaderProfile.NOOK -> name == "Books"
        UsbReaderProfile.KINDLE -> name.equals("documents", ignoreCase = true)
        else -> name.isNotBlank() && name.length <= 1024 && name.none { it.isISOControl() }
    }
}
