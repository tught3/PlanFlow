pluginManagement {
    val flutterSdkPath = run {
        val properties = java.util.Properties()
        val localPropertiesFile = File(rootDir, "local.properties")
        if (localPropertiesFile.exists()) {
            localPropertiesFile.inputStream().use { properties.load(it) }
        }
        properties.getProperty("flutter.sdk")
            ?: error("Flutter SDK not configured. Set flutter.sdk in android/local.properties.")
    }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "8.3.2" apply false
    id("org.jetbrains.kotlin.android") version "2.0.21" apply false
}

include(":app")
