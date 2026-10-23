package ru.mkulkov.brizfi

/** Discovery only; Android MTP still validates descriptors and opens the session. */
internal fun isKindleMtpInterface(
    vendorId: Int,
    productId: Int,
    interfaceClass: Int,
    interfaceSubclass: Int,
    interfaceProtocol: Int,
): Boolean = vendorId == 0x1949 && productId == 0x9981 && (
    (interfaceClass == 6 && interfaceSubclass == 1 && interfaceProtocol == 1) ||
        (productId == 0x9981 && interfaceClass == 255 && interfaceSubclass == 255 && interfaceProtocol == 0)
    )

/** Only the observed NOOK USB mass-storage interface is eligible for SAF routing. */
internal fun isNookMassStorageInterface(
    vendorId: Int, productId: Int, interfaceClass: Int, interfaceSubclass: Int, interfaceProtocol: Int,
): Boolean = vendorId == 0x2080 && productId == 0x0003 &&
    interfaceClass == 8 && interfaceSubclass == 6 && interfaceProtocol == 0x50
