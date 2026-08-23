import java.util.Base64
import java.util.Properties
import java.security.MessageDigest
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
} else {
    throw GradleException(
        "Missing android/key.properties. Restore the PlanFlow signing files before building.",
    )
}

val releaseStoreFile = keystoreProperties["storeFile"] as String?
    ?: throw GradleException(
        "android/key.properties is missing storeFile. Restore the PlanFlow signing files before building.",
    )
if (releaseStoreFile.isBlank()) {
    throw GradleException(
        "android/key.properties storeFile is blank. Restore the PlanFlow signing files before building.",
    )
}
if (!file(releaseStoreFile).exists()) {
    throw GradleException(
        "Release keystore file does not exist at $releaseStoreFile. Restore the PlanFlow signing files before building.",
    )
}

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

fun isPlaceholderDartDefineValue(value: String): Boolean {
    val normalized = value.trim().lowercase()
    return normalized.isBlank() ||
        normalized.startsWith("your-") ||
        normalized.startsWith("your_") ||
        normalized == "changeme" ||
        normalized == "replace-me"
}

val requestedTasks = gradle.startParameter.taskNames
    .filter { taskName ->
        !taskName.startsWith("-") &&
            !taskName.contains("\\") &&
            !taskName.contains("/")
    }
    .map { taskName -> taskName.substringAfterLast(":").lowercase() }
val publishLikeTaskRequested = requestedTasks.any { taskName ->
    taskName.contains("publish") ||
        taskName.contains("upload") ||
        taskName.contains("promote")
}
val releaseArtifactRequested = requestedTasks.any { taskName ->
    val isRelease = taskName.contains("release")
    val isArtifactTask = taskName.contains("assemble") ||
        taskName.contains("bundle") ||
        taskName.contains("package")
    val isPublishLikeTask = taskName.contains("publish") ||
        taskName.contains("upload") ||
        taskName.contains("promote")
    isRelease && isArtifactTask && !isPublishLikeTask
}
val releasePublishRequested = publishLikeTaskRequested
val planflowPlayTrack = providers.gradleProperty("planflowPlayTrack")
    .orNull
    ?.trim()
    ?.lowercase()
    ?: "internal"

if (releasePublishRequested && planflowPlayTrack !in setOf("internal", "alpha", "production")) {
    throw GradleException(
        "Release publish blocked: unsupported PlanFlow Play track '$planflowPlayTrack'. " +
            "Use internal, alpha, or production through an explicit release wrapper.",
    )
}

val productionRolloutToken = providers.gradleProperty("planflowProductionRolloutToken")
    .orNull
    ?.trim()
    ?: ""
val productionRolloutReceiptPath = providers.gradleProperty("planflowProductionRolloutReceipt")
    .orNull
    ?.trim()
    ?: ""
if (releasePublishRequested && planflowPlayTrack == "production") {
    if (productionRolloutToken.isBlank() || productionRolloutReceiptPath.isBlank()) {
        throw GradleException(
            "Production publish blocked: use scripts/deploy-play-production.ps1 " +
                "-ConfirmProductionRollout so the wrapper can issue a one-time rollout receipt.",
        )
    }

    val receiptFile = file(productionRolloutReceiptPath)
    val workspaceRoot = rootProject.projectDir.parentFile.canonicalFile
    val receiptRoot = workspaceRoot.resolve("build").canonicalFile
    val receiptCanonical = receiptFile.canonicalFile
    if (!receiptFile.isFile || !receiptCanonical.toPath().startsWith(receiptRoot.toPath())) {
        throw GradleException(
            "Production publish blocked: rollout receipt is missing or outside the workspace build directory.",
        )
    }
    val receiptValues = receiptFile.readLines(Charsets.UTF_8)
        .mapNotNull { line ->
            val separator = line.indexOf('=')
            if (separator <= 0) null else line.substring(0, separator) to line.substring(separator + 1)
        }
        .toMap()
    val issuedAt = receiptValues["issuedAtEpochMillis"]?.toLongOrNull() ?: 0L
    val now = System.currentTimeMillis()
    if (receiptValues["token"] != productionRolloutToken ||
        receiptValues["track"] != "production" ||
        receiptValues["workspace"] != workspaceRoot.path ||
        issuedAt <= 0L || kotlin.math.abs(now - issuedAt) > 5 * 60 * 1000L
    ) {
        throw GradleException("Production publish blocked: rollout receipt is invalid, stale, or not issued by the wrapper.")
    }
    if (!receiptFile.delete()) {
        throw GradleException("Production publish blocked: rollout receipt could not be consumed exactly once.")
    }
}

if (releaseArtifactRequested) {
    val requiredMapDefines = listOf(
        "GOOGLE_MAPS_API_KEY",
        "TMAP_API_KEY",
        "NAVER_MAP_CLIENT_ID",
    )
    val missingMapDefines = requiredMapDefines.filter { key ->
        isPlaceholderDartDefineValue(readDartDefineValue(key))
    }
    if (missingMapDefines.isNotEmpty()) {
        throw GradleException(
            "Release build blocked: missing or placeholder dart-defines " +
                "(${missingMapDefines.joinToString(", ")}). " +
                "Run the build through scripts/flutter-local.ps1 so env/local.json is injected.",
        )
    }
}

if (releasePublishRequested) {
    val markerPath = providers.gradleProperty("planflowMapArtifactMarker").orNull?.trim().orEmpty()
    if (markerPath.isBlank()) {
        throw GradleException(
            "Release publish blocked: missing PlanFlow map artifact marker. " +
                "Run scripts/deploy-play-internal.ps1 so the verified AAB marker is passed.",
        )
    }

    val markerFile = file(markerPath)
    if (!markerFile.isFile) {
        throw GradleException(
            "Release publish blocked: PlanFlow map artifact marker was not found. " +
                "Run scripts/deploy-play-internal.ps1 to rebuild and verify the AAB.",
        )
    }
    val markerValues = markerFile.readLines(Charsets.UTF_8)
        .mapNotNull { line ->
            val separator = line.indexOf('=')
            if (separator <= 0) null else line.substring(0, separator) to line.substring(separator + 1)
        }
        .toMap()
    val markerAabPath = markerValues["aabPath"]?.trim().orEmpty()
    val markerSha256 = markerValues["sha256"]?.trim()?.lowercase().orEmpty()
    val markerAab = if (markerAabPath.isBlank()) null else file(markerAabPath)
    if (markerAab == null || !markerAab.isFile || !markerSha256.matches(Regex("[0-9a-f]{64}"))) {
        throw GradleException(
            "Release publish blocked: PlanFlow map artifact marker is invalid. " +
                "Run scripts/deploy-play-internal.ps1 to rebuild the AAB.",
        )
    }
    val digest = MessageDigest.getInstance("SHA-256")
    markerAab.inputStream().use { input ->
        val buffer = ByteArray(1024 * 1024)
        var read = input.read(buffer)
        while (read >= 0) {
            if (read > 0) digest.update(buffer, 0, read)
            read = input.read(buffer)
        }
    }
    val actualSha256 = digest.digest().joinToString("") { byte -> "%02x".format(byte.toInt() and 0xff) }
    if (actualSha256 != markerSha256) {
        throw GradleException(
            "Release publish blocked: PlanFlow map artifact marker does not match the AAB. " +
                "Run scripts/deploy-play-internal.ps1 to rebuild the AAB.",
        )
    }
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
            storeFile = file(releaseStoreFile)
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
    track.set(planflowPlayTrack)
    artifactDir.set(file("../../build/app/outputs/bundle/release"))
    if (playServiceAccountPath.isNotBlank()) {
        serviceAccountCredentials.set(file(playServiceAccountPath))
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
}
