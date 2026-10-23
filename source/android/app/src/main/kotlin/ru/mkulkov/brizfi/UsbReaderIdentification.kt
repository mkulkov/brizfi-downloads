package ru.mkulkov.brizfi

import java.security.MessageDigest
import java.util.Locale

/** Discovery hints are deliberately separate from the hardware write allowlist. */
internal object UsbReaderIdentification {
    data class Interface(val deviceClass: Int, val subclass: Int, val protocol: Int)
    data class Descriptor(val vendor: Int, val product: Int, val manufacturer: String?,
                          val productName: String?, val interfaces: List<Interface>)
    data class Reader(val brand: String, val name: String, val profile: String,
                      val transport: String, val formats: List<String>)

    private fun normalized(value: String?): String = value.orEmpty().take(128)
        .replace(Regex("[\\p{Cntrl}]"), " ").trim().lowercase(Locale.ROOT)
    private fun token(value: String, token: String): Boolean =
        Regex("(?:^|[^a-z0-9])${Regex.escape(token)}(?:$|[^a-z0-9])").containsMatchIn(value)

    fun discover(descriptor: Descriptor, supported: UsbReaderProfile?): Reader {
        val storage = descriptor.interfaces.any { it == Interface(8, 6, 80) }
        val mtp = descriptor.interfaces.any { it == Interface(6, 1, 1) }
        val manufacturer = normalized(descriptor.manufacturer)
        val product = normalized(descriptor.productName)
        val tokens = "$manufacturer $product"
        val knownBrand = supported?.takeIf { it == UsbReaderProfile.KINDLE || it == UsbReaderProfile.NOOK }?.key
        val brand = knownBrand ?: when {
            token(tokens, "kindle") || token(manufacturer, "amazon") -> "kindle"
            token(tokens, "nook") || token(manufacturer, "barnes") && token(manufacturer, "noble") -> "nook"
            token(tokens, "kobo") -> "kobo"
            token(tokens, "pocketbook") || token(manufacturer, "obreey") &&
                Regex("^pb[0-9]+(?:[- ][a-z0-9]+)*$").matches(product) -> "pocketbook"
            token(tokens, "onyx") || token(tokens, "boox") -> "onyx"
            else -> "other"
        }
        val label = when (brand) {
            "kindle" -> "Kindle USB"
            "nook" -> "NOOK USB"
            "kobo" -> "Kobo USB"
            "pocketbook" -> "PocketBook USB"
            "onyx" -> "Onyx Boox USB"
            else -> "USB reader"
        }
        return Reader(brand, label, supported?.key ?: "unknown",
            supported?.transport ?: when { storage -> "massStorage"; mtp -> "mtp"; else -> "unsupported" },
            supported?.formats?.toList() ?: emptyList())
    }

    fun identity(descriptor: Descriptor, serial: String?): Pair<String, Boolean> {
        val uniqueSerial = serial?.takeIf { it.isNotBlank() && it.length <= 256 }
        // Length framing prevents ambiguous descriptor/serial separators.
        val parts = if (uniqueSerial != null)
            listOf(descriptor.vendor.toString(), descriptor.product.toString(), uniqueSerial)
        else listOf(descriptor.vendor.toString(), descriptor.product.toString(),
            normalized(descriptor.manufacturer), normalized(descriptor.productName))
        val identity = parts.joinToString("") { "${it.length}:$it" }
        val digest = MessageDigest.getInstance("SHA-256").digest(identity.toByteArray(Charsets.UTF_8))
        return ("usb:" + digest.joinToString("") { "%02x".format(it.toInt() and 255) }) to (uniqueSerial != null)
    }
}
