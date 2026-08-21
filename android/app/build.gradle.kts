import java.util.Base64
import java.util.Properties
import org.gradle.api.GradleException

plugins {
    id("com.android.application")
    id("com.google.gms.google-services")
    id("com.google.firebase.crashlytics")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
    id("com.github.triplet.play") version "3.12.2"
}

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystorePropertiesFile.inputStream().use { keystoreProperties.load(it) }
}

val releaseStoreFile = keystoreProperties["storeFile"] as String?

val playServiceAccountPath = (
    providers.gradleProperty("planflowPlayServiceAccountJson").orNull?.trim()
        ?: providers.environmentVariable("ANDROID_PUBLISHER_CREDENTIALS").orNull?.trim()
        ?: ""
)

val playPublishRequested = gradle.startParameter.taskNames.any { taskName ->
    taskName.contains("publish", ignoreCase = true) ||
        taskName.contains("upload", ignoreCase = true) ||
        taskName.contains("promote", ignoreCase = true)
}

if (playPublishRequested && playServiceAccountPath.isBlank()) {
    throw GradleException(
        "Missing Google Play service account path. Set -PplanflowPlayServiceAccountJson=... or ANDROID_PUBLISHER_CREDENTIALS before publishing.",
    )
}

fun readDartDefineValue(key: String): String {
    val dartDefines = project.findProperty("dart-defines") as String? ?: return ""
    return dartDefines
        .split(",")
        .asSequence()
        .mapNotNull { encoded ->
            runCatching {
                String(Base64.getUrlDecoder().decode(encoded))
            }.getOrNull()
        }
        .firstOrNull { decoded -> decoded.startsWith("$key=") }
        ?.substringAfter("=")
        ?.trim()
        ?: ""
}

fun isPlaceholderMapDefine(value: String): Boolean {
    val normalized = value.trim().lowercase()
    return normalized.startsWith("your-") ||
        normalized.contains("your-google-maps-api-key") ||
        normalized.contains("your-tmap-api-key") ||
        normalized.contains("your-naver-map-client-id")
}

val releaseBuildRequested = gradle.startParameter.taskNames.any { taskName ->
    taskName.contains("release", ignoreCase = true)
}

if (releaseBuildRequested) {
    // Flutter passes --dart-define values to Gradle as base64-encoded
    // `dart-defines`. An Android environment variable can populate the
    // manifest placeholder, but cannot configure the Dart runtime. Require
    // the defines themselves so raw Flutter release commands fail closed.
    val missingMapDartDefines = listOf(
        "GOOGLE_MAPS_API_KEY",
        "TMAP_API_KEY",
        "NAVER_MAP_CLIENT_ID",
    ).filter { key ->
        val value = readDartDefineValue(key)
        value.isBlank() || isPlaceholderMapDefine(value)
    }
    if (missingMapDartDefines.isNotEmpty()) {
        throw GradleException(
            "Release map dart-defines are missing or placeholders: " +
                missingMapDartDefines.joinToString(", ") +
                ". Pass non-placeholder values with --dart-define-from-file or --dart-define.",
        )
    }
}

val releaseStoreFilePath = releaseStoreFile?.takeIf { it.isNotBlank() }
    ?: throw GradleException(
        "android/key.properties is missing storeFile. Restore the PlanFlow signing files before building.",
    )
if (!file(releaseStoreFilePath).exists()) {
    throw GradleException(
        "Release keystore file does not exist at $releaseStoreFilePath. Restore the PlanFlow signing files before building.",
    )
}

android {
    namespace = "com.fluxstudio.planflow"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "com.fluxstudio.planflow"
        minSdk = maxOf(flutter.minSdkVersion, 23)
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        manifestPlaceholders["googleMapsApiKey"] =
            readDartDefineValue("GOOGLE_MAPS_API_KEY")
                .ifEmpty { System.getenv("GOOGLE_MAPS_API_KEY") ?: "" }
    }

    signingConfigs {
        create("release") {
            keyAlias = keystoreProperties["keyAlias"] as String?
            keyPassword = keystoreProperties["keyPassword"] as String?
            storeFile = file(releaseStoreFilePath)
            storePassword = keystoreProperties["storePassword"] as String?
        }
    }

    buildTypes {
        debug {
            signingConfig = signingConfigs.getByName("release")
        }

        release {
            signingConfig = signingConfigs.getByName("release")
            isMinifyEnabled = true
            // shrinkResources를 켜면 리소스 이름이 난독화/제거되어,
            // flutter_local_notifications가 문자열 이름(getIdentifier)으로 찾는
            // 알림 아이콘 ic_stat_planflow가 'could not be found'로 실패한다.
            // 알림 정상 동작을 위해 리소스 축소는 끈다(코드 minify는 유지).
            isShrinkResources = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }
}

flutter {
    source = "../.."
}

play {
    track.set("internal")
    artifactDir.set(file("../../build/app/outputs/bundle/release"))
    if (playServiceAccountPath.isNotBlank()) {
        serviceAccountCredentials.set(file(playServiceAccountPath))
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
}
