// One request with a Claude token, sent by Mode's own ClaudeOAuthClient: the two proofs in the emulator
// ADR (emulator-ai-runs-adr.md, Option B). Opt-in: settings.gradle.kts includes this module only with
// -PclaudeCheck, so normal builds, the Tests workflow and the app never see it. Run by claude-check.yml.
plugins {
    alias(libs.plugins.kotlinMultiplatform)
}

kotlin {
    jvm()
    sourceSets {
        jvmMain.dependencies {
            implementation(projects.engine.llm)
            implementation(libs.ktor.client.okhttp)
        }
    }
}

// The check and everything it needs, in one folder, so the workflow runs it with plain `java` and the
// token reaches that process only, never Gradle (whose caches and daemon outlive the step).
tasks.register<Sync>("checkLibs") {
    from(tasks.named("jvmJar"))
    from(configurations.named("jvmRuntimeClasspath"))
    into(layout.buildDirectory.dir("check-libs"))
}
