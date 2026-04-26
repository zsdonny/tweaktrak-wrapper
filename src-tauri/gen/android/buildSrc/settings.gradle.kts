// Explicit plugin management for buildSrc.
// Without this, Gradle resolves kotlin-dsl plugin dependencies only from
// pluginManagement.repositories in the root settings.gradle, which defaults
// to plugins.gradle.org -> Maven Central. On GitHub Actions runners Maven
// Central occasionally returns 403 for newer Kotlin artifacts. The JetBrains
// cache-redirector CDN mirrors Maven Central reliably from CI environments.
pluginManagement {
    repositories {
        maven { url = uri("https://cache-redirector.jetbrains.com/plugins.gradle.org") }
        gradlePluginPortal()
        google()
        maven { url = uri("https://cache-redirector.jetbrains.com/maven-central") }
        mavenCentral()
    }
}

dependencyResolutionManagement {
    repositories {
        google()
        maven { url = uri("https://cache-redirector.jetbrains.com/maven-central") }
        mavenCentral()
    }
}
