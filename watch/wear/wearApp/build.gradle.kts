import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

// The repo root (watch/wear/../..): pubspec.yaml, android/key.properties and
// the shared protocol test vectors live there.
val repoRoot: File = rootDir.resolve("../..").canonicalFile

// Version comes from the Flutter app's pubspec.yaml (`version: 0.3.3+54`).
// Phone and watch share ONE versionCode space in the Play listing and Play
// rejects any reuse forever, so the watch lives at 1_000_000 + build number.
val pubspecVersion: Pair<String, Int> = run {
    val text = repoRoot.resolve("pubspec.yaml").readText()
    val m = Regex("""(?m)^version:\s*([0-9A-Za-z.\-]+)\+(\d+)\s*$""").find(text)
        ?: throw GradleException("pubspec.yaml has no `version: x.y.z+n` line")
    m.groupValues[1] to m.groupValues[2].toInt()
}

// Release signing: the same upload key as the phone (android/app/build.gradle
// reads android/key.properties). Absent on most machines; then release builds
// fall back to debug signing, which Play rejects (on purpose: no accidents).
val keystorePropsFile: File = repoRoot.resolve("android/key.properties")
val keystoreProps = Properties().apply {
    if (keystorePropsFile.exists()) keystorePropsFile.inputStream().use { load(it) }
}
val hasUploadKey = keystoreProps.getProperty("storeFile") != null

android {
    // Kotlin package only; the installed app id is the phone's (see below).
    namespace = "com.sagearbor.feltnotes.wear"
    compileSdk = 36

    defaultConfig {
        // Same applicationId as the phone app: required for the Wear OS track
        // of the same Play listing AND for the Wearable Data Layer (messages
        // only flow between apps with the same package and signing key).
        // Debug keeps it too (no ".debug" suffix), so a debug watch build
        // talks to a debug phone build.
        applicationId = "com.sagearbor.feltnotes.app"
        minSdk = 30
        targetSdk = 36
        versionCode = 1_000_000 + pubspecVersion.second
        versionName = pubspecVersion.first
    }

    signingConfigs {
        if (hasUploadKey) {
            create("upload") {
                // android/app/build.gradle resolves storeFile relative to
                // android/app, so do the same here.
                storeFile = repoRoot.resolve("android/app").resolve(keystoreProps.getProperty("storeFile"))
                storePassword = keystoreProps.getProperty("storePassword")
                keyAlias = keystoreProps.getProperty("keyAlias")
                keyPassword = keystoreProps.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            signingConfig = if (hasUploadKey) signingConfigs.getByName("upload")
                            else signingConfigs.getByName("debug")
        }
    }

    sourceSets {
        // The watch<->phone JSON protocol, shared verbatim with the phone
        // bridge (android/app adds the same directory).
        getByName("main").java.srcDir("../protocol/src/main/kotlin")
    }

    buildFeatures {
        compose = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    packaging {
        resources { excludes += "/META-INF/{AL2.0,LGPL2.1}" }
    }

    testOptions {
        unitTests.all {
            // Lets the protocol test find test/pulse/protocol_vectors.json
            // whatever directory Gradle runs from.
            it.systemProperty("feltnotes.repoRoot", repoRoot.absolutePath)
        }
    }
}

kotlin {
    jvmToolchain(17)
}

dependencies {
    implementation(platform("androidx.compose:compose-bom:2025.12.00"))
    implementation("androidx.wear.compose:compose-material:1.5.6")
    implementation("androidx.wear.compose:compose-foundation:1.5.6")
    implementation("androidx.activity:activity-compose:1.12.4")
    implementation("androidx.core:core-ktx:1.17.0")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.9.4")
    // play-services-base drags in fragment 1.0, which breaks the
    // ActivityResult permission request (lint InvalidFragmentVersion...).
    implementation("androidx.fragment:fragment:1.8.5")

    implementation("androidx.health:health-services-client:1.1.0")
    // health-services-client returns ListenableFuture; real guava on the
    // compile classpath avoids the listenablefuture "empty" artifact trap.
    implementation("com.google.guava:guava:33.4.8-android")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-guava:1.10.2")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-play-services:1.10.2")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")

    implementation("com.google.android.gms:play-services-wearable:19.0.0")
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.9.0")

    testImplementation("junit:junit:4.13.2")
}
