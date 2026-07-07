plugins {
    id("com.android.application")
    kotlin("android")
}

android {
    namespace = "se.denied.bastion"
    compileSdk = 35

    defaultConfig {
        applicationId = "se.denied.bastion"
        minSdk = 26
        targetSdk = 35
        versionCode = 1
        versionName = "0.1"

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }
}

dependencies {
    // SSH-motorn — samma princip som SSHCore (Swift-sidan) bygger på
    // swift-nio-ssh istället för att implementera SSH-protokollet från
    // grunden: Apache MINA SSHD är en mogen, väl underhållen Java/Kotlin-
    // SSH-implementation (klient OCH server, den senare används bara i
    // testerna nedan för en riktig, självständig round-trip-verifiering
    // utan att röra systemets egna sshd).
    implementation("org.apache.sshd:sshd-core:2.14.0")
    implementation("org.apache.sshd:sshd-common:2.14.0")

    testImplementation("org.apache.sshd:sshd-scp:2.14.0")
    testImplementation(kotlin("test"))
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.bouncycastle:bcprov-jdk18on:1.79")
}
