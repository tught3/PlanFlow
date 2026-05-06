plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}

fun readDotEnvValue(key: String): String {
    val envFile = rootProject.projectDir.parentFile.resolve(".env")
    if (!envFile.exists()) return ""
    return envFile.readLines()
        .firstOrNull { line ->
            val trimmed = line.trim()
            trimmed.startsWith("$key=") && !trimmed.startsWith("#")
        }
        ?.substringAfter("=")
        ?.trim()
        ?.trim('"')
        ?.trim('\'')
        ?: ""
}

android {
    namespace = "com.example.planflow"
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
        applicationId = "com.example.planflow"
        minSdk = maxOf(flutter.minSdkVersion, 23)
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        manifestPlaceholders["googleMapsApiKey"] =
            System.getenv("GOOGLE_MAPS_API_KEY") ?: readDotEnvValue("GOOGLE_MAPS_API_KEY")
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
}
