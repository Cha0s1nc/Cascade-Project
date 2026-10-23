pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "Cascade"

// core is the pure Kotlin half (the CascadeKit of this app): no Android
// classes, so its tests run on a plain JVM in seconds. app is the Android
// application built on top of it.
include(":core")
include(":app")
