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
            isShrinkResources = true
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
