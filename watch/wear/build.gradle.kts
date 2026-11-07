// Felt Notes Pulse, the Wear OS app. Standalone Gradle project (not part of the
// Flutter android/ build) so `flutter build` never has to know about it.
// Versions match android/settings.gradle (AGP + Kotlin) so one Gradle cache
// serves both.
plugins {
    id("com.android.application") version "8.11.1" apply false
    id("org.jetbrains.kotlin.android") version "2.3.20" apply false
    id("org.jetbrains.kotlin.plugin.compose") version "2.3.20" apply false
}
