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

// --- PlanFlow isolated guide-QA opt-in (DEBUG ONLY) ---
// Reads Flutter-encoded --dart-define=PLANFLOW_ISOLATED_GUIDE_QA=true via
// readDartDefineValue(). On a debug artifact task only, this:
//   - sets applicationIdSuffix = ".guideqa" so the install has a distinct
//     applicationId (com.fluxstudio.planflow.guideqa) and may coexist with the
//     prod build on the same device,
//   - sets a debugAppLabel manifest placeholder so the debug manifest can
//     override android:label to "PlanFlowGuideQA" via tools:replace,
//   - flips the google-services plugin's built-in `disable` flag (via
//     reflection on its registered extension) so the plugin still applies
//     but skips google-services.json parsing and the package_name validation
//     that would otherwise reject the .guideqa applicationId. Crashlytics
//     stays applied per the directive (NOT release-skipped, only debug opt-in);
//     its FirebaseOptions lookup degrades gracefully in this build, matching
//     the existing QA manual-app fence (analytics disabled already).
// Plugin application timing for google-services and crashlytics is intentionally
// unchanged across debug, release, and opt-in — only `disable` flips.
// Namespace, default applicationId, and the release build path are untouched.
// When optin=false, manifestPlaceholders still resolve to the prod label so the
// merged manifest is identical to the baseline.
// Package isolation is on-device only. Existing QA manual flow already uses the
// dedicated QA Firebase project (not separate production data) plus dedicated
// Supabase UID, strict RLS, hard budget 0/3, analytics disabled — this change
// does NOT introduce a new backend.
val debugArtifactRequested = requestedTasks.any { taskName ->
    val isDebug = taskName.contains("debug")
    val isArtifact = taskName.contains("assemble") ||
        taskName.contains("install") ||
        taskName.contains("bundle") ||
        taskName.contains("package")
    isDebug && isArtifact
}
val isolatedGuideQaFlag = readDartDefineValue("PLANFLOW_ISOLATED_GUIDE_QA").lowercase()
val isolatedGuideQaRequested = isolatedGuideQaFlag == "true" ||
    isolatedGuideQaFlag == "1" ||
    isolatedGuideQaFlag == "yes"
val applyIsolatedGuideQaDebug = isolatedGuideQaRequested &&
    debugArtifactRequested &&
    !releaseArtifactRequested

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
        issuedAt <= 0L || Math.abs(now - issuedAt) > 5 * 60 * 1000L
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
            if (applyIsolatedGuideQaDebug) {
                // Debug-only opt-in: gives the install a distinct applicationId
                // so it can coexist with the prod build on the same device.
                // Release builds and default debug builds (no opt-in) keep the
                // baseline com.fluxstudio.planflow applicationId.
                applicationIdSuffix = ".guideqa"
            }
            // Even when optin=false, the placeholder resolves to the prod label
            // so the debug manifest override is a no-op for default debug builds.
            // When optin=true, this lets the debug <application> android:label
            // override main's "PlanFlow" with "PlanFlowGuideQA".
            manifestPlaceholders["debugAppLabel"] = if (applyIsolatedGuideQaDebug) {
                "PlanFlowGuideQA"
            } else {
                "PlanFlow"
            }
        }

        release {
            signingConfig = signingConfigs.getByName("release")
            isMinifyEnabled = true
            // res/raw/keep.xml이 문자열 이름으로 조회되는 동적 알림 아이콘을 보존한다.
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }

    // Isolated guide QA only: no google-services.json exists for the .guideqa
    // package, so skip the known debug google-services task. Default debug and
    // all release paths keep the static plugins and run the task normally.
    if (applyIsolatedGuideQaDebug) {
        project.tasks.configureEach {
            if (name == "processDebugGoogleServices") {
                enabled = false
            }
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
