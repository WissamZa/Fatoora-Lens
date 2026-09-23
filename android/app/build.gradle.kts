import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    id("dev.flutter.flutter-gradle-plugin")
}

fun gitTagVersion(): String? {
    val output = try {
        ProcessBuilder("git", "describe", "--tags", "--abbrev=0", "--match", "v[0-9]*")
            .directory(rootProject.projectDir.parentFile)
            .redirectErrorStream(true)
            .start()
    } catch (_: Exception) {
        return null
    }

    val tag = output.inputStream.bufferedReader().use { it.readText().trim() }
    return tag.takeIf { output.waitFor() == 0 && it.isNotBlank() }
}

val releaseTag = System.getenv("RELEASE_TAG")?.trim()?.takeIf { it.isNotEmpty() } ?: gitTagVersion()
val releaseVersion = releaseTag?.let { tag ->
    require(tag.startsWith("v")) {
        "RELEASE_TAG must start with v, but was: $tag"
    }
    tag.removePrefix("v").also {
        require(Regex("^[0-9]+\\.[0-9]+\\.[0-9]+([+-][0-9A-Za-z.-]+)?$").matches(it)) {
            "RELEASE_TAG must contain a semantic version such as v1.0.6, but was: $releaseTag"
        }
    }
}
val releaseVersionCode = releaseVersion?.substringBefore('-')?.substringBefore('+')?.let { version ->
    val parts = version.split('.').map { it.toInt() }
    val code = parts[0].toLong() * 1_000_000 + parts[1] * 1_000 + parts[2]
    require(code in 1..2_147_483_647) {
        "Release version is too large for an Android version code: $releaseVersion"
    }
    code.toInt()
}

val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties()
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.fatooralens.app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.fatooralens.app"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = releaseVersionCode ?: flutter.versionCode
        versionName = releaseVersion ?: flutter.versionName
    }

    signingConfigs {
        create("release") {
            val keyAliasProp = keystoreProperties.getProperty("keyAlias") ?: System.getenv("KEY_ALIAS")
            val keyPasswordProp = keystoreProperties.getProperty("keyPassword") ?: System.getenv("KEY_PASSWORD")
            val storeFileProp = keystoreProperties.getProperty("storeFile") ?: System.getenv("KEYSTORE_FILE")
            val storePasswordProp = keystoreProperties.getProperty("storePassword") ?: System.getenv("KEYSTORE_PASSWORD")

            if (!storeFileProp.isNullOrBlank() && !keyAliasProp.isNullOrBlank()) {
                val resolvedFile = file(storeFileProp)
                if (resolvedFile.exists()) {
                    keyAlias = keyAliasProp
                    keyPassword = keyPasswordProp
                    storeFile = resolvedFile
                    storePassword = storePasswordProp
                }
            }
        }
    }

    buildTypes {
        release {
            val releaseSigning = signingConfigs.getByName("release")
            signingConfig = if (releaseSigning.storeFile != null && releaseSigning.storeFile!!.exists()) {
                releaseSigning
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
