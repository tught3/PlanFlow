allprojects {
    repositories {
        google()
        mavenCentral()
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
                    "home_widget",
                )
                val target = when (project.name) {
                    in java8KotlinProjects ->
                        org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_1_8
                    "speech_to_text" ->
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
