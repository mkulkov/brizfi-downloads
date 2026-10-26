import java.util.Base64
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val brizfiDefines = providers.gradleProperty("dart-defines").orNull
    ?.split(',')?.mapNotNull { encoded ->
        runCatching { String(Base64.getDecoder().decode(encoded), Charsets.UTF_8) }
            .getOrNull()?.split('=', limit = 2)?.takeIf { it.size == 2 }
            ?.let { it[0] to it[1] }
    }?.toMap().orEmpty()
val brizfiStoreId = brizfiDefines["BRIZFI_RUSTORE_APP_ID"] ?: "2063767962"
val brizfiRemoveAdsProduct = brizfiDefines["BRIZFI_REMOVE_ADS_PRODUCT"] ?: "donate_499"
val brizfiPayEnabled = brizfiStoreId.isNotEmpty() &&
    brizfiRemoveAdsProduct.isNotEmpty() &&
    brizfiDefines["BRIZFI_ADS"] != "false"
require(brizfiStoreId.isEmpty() || brizfiStoreId.matches(Regex("[0-9]+"))) {
    "BRIZFI_RUSTORE_APP_ID must be the numeric console application ID"
}
val releaseSigning = Properties()
val releaseSigningFile = rootProject.file("key.properties")
if (releaseSigningFile.isFile) {
    releaseSigningFile.inputStream().use { releaseSigning.load(it) }
}

android {
    buildFeatures { resValues = true }
    namespace = "ru.mkulkov.brizfi"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion
    // Optional diagnostic built by poc/usb-native-probe/build.ps1; never packaged in release.
    sourceSets.getByName("debug").jniLibs.srcDir("../../artifacts/usb-probe-jni")
    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "ru.mkulkov.brizfi"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 29
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        resValue("string", "brizfi_rustore_app_id", brizfiStoreId)
        resValue("string", "brizfi_pay_scheme", "ru.mkulkov.brizfi.pay")
        resValue("bool", "brizfi_pay_enabled", brizfiPayEnabled.toString())
        manifestPlaceholders["brizfiPayEnabled"] = brizfiPayEnabled.toString()
    }

    signingConfigs {
        create("release") {
            // Local, ignored credentials; missing configuration fails release signing.
            if (releaseSigningFile.isFile) {
                storeFile = file(requireNotNull(releaseSigning.getProperty("storeFile")))
                storePassword = requireNotNull(releaseSigning.getProperty("storePassword"))
                keyAlias = requireNotNull(releaseSigning.getProperty("keyAlias"))
                keyPassword = requireNotNull(releaseSigning.getProperty("keyPassword"))
            }
        }
    }

    buildTypes {
        debug {
            // Opt-in isolated emulator/device tests cannot replace the user's app.
            // Flutter reliably forwards dart-defines as a Gradle property;
            // environment-derived properties can be absent in an existing daemon.
            val isolatedDartDefine = providers.gradleProperty("dart-defines").orNull
                ?.split(',')?.any { encoded ->
                    runCatching {
                        String(Base64.getDecoder().decode(encoded), Charsets.UTF_8)
                    }.getOrNull() == "BRIZFI_ISOLATED_TEST=true"
                } == true
            if (providers.gradleProperty("brizfiIsolatedTest").orNull == "true" || isolatedDartDefine) {
                applicationIdSuffix = ".isolated"
                resValue("string", "brizfi_pay_scheme", "ru.mkulkov.brizfi.isolated.pay")
            }
        }
        release {
            signingConfig = signingConfigs.getByName("release")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    testImplementation("junit:junit:4.13.2")
}
