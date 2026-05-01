allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir = rootProject.layout.buildDirectory.dir("../build").get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val subprojectBuildDir = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(subprojectBuildDir)
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
