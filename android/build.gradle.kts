allprojects {
    repositories {
        google()
        mavenCentral()
    }

    configurations.configureEach {
        // Custom RemoteViews 위젯만 사용하므로 Glance UI/action은 필요 없다.
        // 그래도 home_widget의 병합 의존성이 Glance를 끌어올 경우를 대비해
        // trampoline target-intent 크래시가 수정된 버전을 고정한다.
        resolutionStrategy.force("androidx.glance:glance-appwidget:1.1.1")
        // google_sign_in 6.x otherwise resolves the crash-trace version 21.0.0;
        // keep the Play Services Auth API on the compatible 21.x maintenance line.
        resolutionStrategy.force("com.google.android.gms:play-services-auth:21.5.1")
    }
}

val newBuildDir = rootProject.layout.projectDirectory.dir("../build")
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val subprojectBuildDir = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(subprojectBuildDir)
    plugins.withId("com.android.library") {
        extensions.configure<com.android.build.gradle.LibraryExtension>("android") {
            compileOptions {
                sourceCompatibility = JavaVersion.VERSION_17
                targetCompatibility = JavaVersion.VERSION_17
            }
        }
        extensions.configure<com.android.build.api.variant.LibraryAndroidComponentsExtension>(
            "androidComponents",
        ) {
            finalizeDsl { extension ->
                if (project.name == "home_widget") {
                    extension.compileOptions {
                        sourceCompatibility = JavaVersion.VERSION_11
                        targetCompatibility = JavaVersion.VERSION_11
                    }
                }
            }
        }
    }
    afterEvaluate {
        tasks.withType<JavaCompile>().configureEach {
            sourceCompatibility = JavaVersion.VERSION_17.toString()
            targetCompatibility = JavaVersion.VERSION_17.toString()
        }
        tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
            compilerOptions {
                val java8KotlinProjects = setOf(
                    "flutter_naver_map",
                    "flutter_tts",
                    "in_app_update",
                )
                val java11KotlinProjects = setOf(
                    "home_widget",
                    "in_app_review",
                    "speech_to_text",
                )
                val target = when (project.name) {
                    in java8KotlinProjects ->
                        org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_1_8
                    in java11KotlinProjects ->
                        org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_11
                    else ->
                        org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
                }
                jvmTarget.set(target)
            }
        }
    }
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
