buildscript {
    repositories {
        google()
        // JetBrains CDN mirror of Maven Central — avoids 403s from GitHub Actions runners
        maven { url = uri("https://cache-redirector.jetbrains.com/maven-central") }
        mavenCentral()
    }
    dependencies {
        classpath("com.android.tools.build:gradle:8.11.0")
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:1.9.25")
    }
}

allprojects {
    repositories {
        google()
        maven { url = uri("https://cache-redirector.jetbrains.com/maven-central") }
        mavenCentral()
    }
}

tasks.register("clean").configure {
    delete("build")
}

