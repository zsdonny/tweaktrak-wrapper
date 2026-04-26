plugins {
    `kotlin-dsl`
}

gradlePlugin {
    plugins {
        create("pluginsForCoolKids") {
            id = "rust"
            implementationClass = "RustPlugin"
        }
    }
}

repositories {
    google()
    // JetBrains CDN mirror of Maven Central — avoids 403s from GitHub Actions runners
    maven { url = uri("https://cache-redirector.jetbrains.com/maven-central") }
    mavenCentral()
}

dependencies {
    compileOnly(gradleApi())
    implementation("com.android.tools.build:gradle:8.11.0")
}

