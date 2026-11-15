package com.piyush.mode.app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import com.piyush.mode.ops.Op
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.jsonObject
import kotlin.time.TimeSource

/**
 * Debug builds only: drives the phone engine from adb, before there are screens to do it from.
 *
 *     adb shell am broadcast -n app.heymode.mode/com.piyush.mode.app.DevProbe --es op look
 *     adb shell am broadcast -n app.heymode.mode/com.piyush.mode.app.DevProbe --es op tap --ef x 180 --ef y 400
 *
 * Ops: look, text, tap, back, home, recents, notifications, quick, launch (--es name …), type (--es s …),
 * enter, scroll (--es dir down|up), checks, hold (--el ms …), stream and tone (--ef s seconds; a streamed line and a
 * plain one, to compare), signin and answer (the emulator's real-task job, emulators only; see ProbeCi). Results
 * go to logcat under the tag ModeProbe.
 */
class DevProbe : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val graph = ModeApplication.graph(context)
        val pending = goAsync()
        scope.launch {
            val started = TimeSource.Monotonic.markNow()
            val result = runCatching {
                when (val name = intent.getStringExtra("op") ?: "look") {
                    "hold" -> {
                        // The working service and wake locks, held for a few seconds, as a task holds them.
                        com.piyush.mode.core.platform.AndroidBackgroundWork(context).run { kotlinx.coroutines.delay(intent.getLongExtra("ms", 8000)) }
                        "held"
                    }
                    // Asks the launcher to add Mode's widget to the home screen.
                    "widget" -> {
                        val manager = context.getSystemService(android.appwidget.AppWidgetManager::class.java)
                        val asked = manager.requestPinAppWidget(android.content.ComponentName(context, com.piyush.mode.app.widget.ModeWidget::class.java), null, null)
                        "pin asked: $asked"
                    }
                    // The agent overlay over whatever app is in front: --es task "…" starts with that task.
                    "overlay" -> kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.Main) {
                        val app = context.applicationContext as android.app.Application
                        "summoned=${com.piyush.mode.app.overlay.OverlayController.summon(app, intent.getStringExtra("task"), "probe")}"
                    }
                    // Words for the overlay's conversation, as if said: --es text "…"
                    "heard" -> kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.Main) {
                        com.piyush.mode.app.overlay.OverlayController.say(intent.getStringExtra("text") ?: "")
                        "heard"
                    }
                    // What the overlay shows now (or that it's closed): --ez close true closes it.
                    "overlaystate" -> kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.Main) {
                        if (intent.getBooleanExtra("close", false)) com.piyush.mode.app.overlay.OverlayController.close("probe")
                        com.piyush.mode.app.overlay.OverlayController.describe()
                    }
                    // A streamed line (as Speechify sends one): a tone as 24 kHz PCM in chunks. --ez hush true stops it part-way.
                    "stream" -> {
                        val rate = 24_000
                        val seconds = intent.getFloatExtra("s", 1.5f)
                        val pcm = ByteArray((rate * seconds).toInt() * 2).also { bytes ->
                            for (i in 0 until bytes.size / 2) {
                                val v = (kotlin.math.sin(2 * Math.PI * 440 * i / rate) * 6000).toInt()
                                bytes[i * 2] = (v and 0xFF).toByte()
                                bytes[i * 2 + 1] = (v shr 8 and 0xFF).toByte()
                            }
                        }
                        if (intent.getBooleanExtra("hush", false)) scope.launch {
                            kotlinx.coroutines.delay(500)
                            com.piyush.mode.feature.settings.voice.DeviceVoice.hush()
                        }
                        val began = TimeSource.Monotonic.markNow()
                        val said = com.piyush.mode.feature.settings.voice.DeviceVoice.playStream(rate) { send ->
                            pcm.asList().chunked(4_800).forEach { send(it.toByteArray()); kotlinx.coroutines.delay(20) }
                        }
                        "stream said=$said after ${began.elapsedNow().inWholeMilliseconds} ms (${seconds} s of sound)"
                    }
                    // The same tone straight to the speaker in one blocking write: how long this phone takes to play it.
                    "tone" -> {
                        val rate = 24_000
                        val seconds = intent.getFloatExtra("s", 1.5f)
                        val pcm = ShortArray((rate * seconds).toInt()) { (kotlin.math.sin(2 * Math.PI * 440 * it / rate) * 6000).toInt().toShort() }
                        val track = android.media.AudioTrack.Builder()
                            .setAudioFormat(android.media.AudioFormat.Builder().setSampleRate(rate).setChannelMask(android.media.AudioFormat.CHANNEL_OUT_MONO).setEncoding(android.media.AudioFormat.ENCODING_PCM_16BIT).build())
                            .setTransferMode(android.media.AudioTrack.MODE_STREAM).build()
                        val began = TimeSource.Monotonic.markNow()
                        track.play()
                        track.write(pcm, 0, pcm.size, android.media.AudioTrack.WRITE_BLOCKING)
                        val wrote = began.elapsedNow().inWholeMilliseconds
                        track.stop()
                        while (track.playState == android.media.AudioTrack.PLAYSTATE_PLAYING && began.elapsedNow().inWholeMilliseconds < 20_000) kotlinx.coroutines.delay(10)
                        track.release()
                        "tone: written in $wrote ms, played in ${began.elapsedNow().inWholeMilliseconds} ms (${seconds} s of sound)"
                    }
                    // A question notification, as a task would post it (kind: YesNo, YesNoAlways, Choice, Text, YourTurn).
                    "ask" -> {
                        val kind = com.piyush.mode.core.platform.QuestionKind.valueOf(intent.getStringExtra("kind") ?: "YesNo")
                        val options = intent.getStringExtra("options")?.split("|").orEmpty()
                        graph.notifier.ask("probe", intent.getStringExtra("text") ?: "Pay ₹349 to Swiggy?", kind, options)
                        "asked"
                    }
                    // Walks setup past Connect your AI on a test phone: a key from the probe, or a stand-in.
                    "key" -> {
                        graph.settings.apiKey = intent.getStringExtra("value") ?: "sk-or-probe"
                        graph.settings.selectProvider(com.piyush.mode.llm.ModelProvider.OpenRouter)
                        "key set"
                    }
                    // The emulator's real-task job: saves a sign-in from files/probe-signin.json (ProbeCi), then
                    // deletes the file. Emulators only, write only. Logs the provider and expiry, never the token
                    // or an error's message. --ez as_phone true takes the real-phone path (to test the refusal).
                    "signin" -> ciOnly { signin(context, graph, asPhone = intent.getBooleanExtra("as_phone", false)) }
                    // Answers the pending yes/no question: --es text yes|no (never "always"). Emulators only.
                    "answer" -> ciOnly { answer(graph, intent.getStringExtra("text"), asPhone = intent.getBooleanExtra("as_phone", false)) }
                    // Looks at (and with x/y taps) another display, as background mode does: --ei display 2
                    "on" -> {
                        val service = com.piyush.mode.android.ServiceRegistry.service.value ?: error("phone control is off")
                        val d = intent.getIntExtra("display", 0)
                        val backend = com.piyush.mode.android.AccessibilityBackend(service, com.piyush.mode.android.AndroidImageTools(service::bitmapFor), displayId = d)
                        if (intent.hasExtra("x")) backend.send(Op.Tap(intent.getFloatExtra("x", 0f).toDouble(), intent.getFloatExtra("y", 0f).toDouble()))
                        intent.getStringExtra("launch")?.let { backend.send(Op.LaunchApp(it)); kotlinx.coroutines.delay(2000) }
                        val shot = backend.send(Op.ScreenCapture(maxSize = 1000)).jsonObject
                        val text = backend.send(Op.ScreenText()) as JsonArray
                        "display=$d bounds=${shot["bounds"]} private=${shot["private"]} jpeg=${shot["jpeg_b64"]?.toString()?.length} texts=${text.size}: " +
                            text.take(intent.getIntExtra("n", 12)).joinToString(" | ") { it.jsonObject["text"].toString() + "@" + it.jsonObject["x"] + "," + it.jsonObject["y"] }
                    }
                    // The text field typing would go to on a display: --ei display 2 (a tap with x/y first)
                    "focus" -> {
                        val service = com.piyush.mode.android.ServiceRegistry.service.value ?: error("phone control is off")
                        val d = intent.getIntExtra("display", 0)
                        if (intent.hasExtra("x")) {
                            val backend = com.piyush.mode.android.AccessibilityBackend(service, com.piyush.mode.android.AndroidImageTools(service::bitmapFor), displayId = d)
                            backend.send(Op.Tap(intent.getFloatExtra("x", 0f).toDouble(), intent.getFloatExtra("y", 0f).toDouble()))
                            kotlinx.coroutines.delay(800)
                        }
                        val global = service.findFocus(android.view.accessibility.AccessibilityNodeInfo.FOCUS_INPUT)
                        "front=${service.appInFront(d)} field=${service.focusedEditable(d)?.let { it.className + " '" + it.text + "'" }} " +
                            "global=${global?.className}@${global?.window?.displayId} editable=${global?.isEditable}"
                    }
                    // Background mode's link: --es code 123456 pairs (Wireless debugging's pairing window open),
                    // then connects and runs `id` as the shell user.
                    "adb" -> {
                        val link = adbLink ?: com.piyush.mode.adb.AdbLink(context).also { adbLink = it }
                        val code = intent.getStringExtra("code")
                        val paired = if (code != null) {
                            val port = intent.getIntExtra("port", 0)
                            "paired=${link.pair(code, port)} on $port ${link.lastError ?: ""}; "
                        } else ""
                        val connected = link.connect()
                        paired + "connected=$connected port=${link.port} " + (if (connected) link.run("id").trim() else "")
                    }
                    // Starts the helper over the link, makes a hidden display and opens Settings there.
                    "helper" -> {
                        val link = adbLink ?: com.piyush.mode.adb.AdbLink(context).also { adbLink = it }
                        check(link.connect()) { "not connected" }
                        helper?.close()
                        val session = com.piyush.mode.adb.HelperSession.start(link, context.applicationInfo.sourceDir).also { helper = it }
                        val m = context.resources.displayMetrics
                        val display = session.send(com.piyush.mode.adb.HelperCommand.display(m.widthPixels, m.heightPixels, m.densityDpi))
                        val id = com.piyush.mode.adb.HelperAnswer.displayId(display) ?: error(display)
                        "display=$id " + session.send(com.piyush.mode.adb.HelperCommand.start(id, intent.getStringExtra("component") ?: "com.android.settings/.Settings"))
                    }
                    // Text recognition on the current screen (what the fallback reads when the tree has nothing).
                    "ocr" -> {
                        val service = com.piyush.mode.android.ServiceRegistry.service.value ?: error("phone control is off")
                        val shot = service.screenshot(0) as? com.piyush.mode.android.Shot.Image ?: error("no screenshot")
                        val lines = com.piyush.mode.android.MlKitTextReader().read(shot.png)
                        "${lines.size} lines: " + lines.take(12).joinToString(" | ") { "${it.text}@${"%.2f".format(it.left)},${"%.2f".format(it.top)}" }
                    }
                    // Pretends a background task runs, so leaving Mode shows its small window.
                    "pip" -> {
                        (context.applicationContext as ModeApplication).backgroundTask.value = intent.getBooleanExtra("on", true)
                        "pip=${intent.getBooleanExtra("on", true)}"
                    }
                    // How the loopback search does on this phone: --ei threads 256 --ei ms 25
                    "scan" -> {
                        val t0 = System.currentTimeMillis()
                        val found = com.piyush.mode.adb.LoopbackPorts.open(
                            com.piyush.mode.adb.LoopbackPorts.EPHEMERAL, intent.getIntExtra("threads", 256), intent.getIntExtra("ms", 25),
                        )
                        "found $found in ${System.currentTimeMillis() - t0} ms"
                    }
                    "tls" -> runCatching {
                        Class.forName("org.conscrypt.OpenSSLProvider").getDeclaredConstructor().newInstance().toString()
                    }.fold({ "bundled conscrypt ok: $it" }, { e -> "bundled conscrypt failed: ${e::class.java.name}: ${e.message} / ${e.cause?.let { c -> c::class.java.name + ": " + c.message }}" })
                    // Turns background mode on or off (after pairing with op=adb), then the next look shows the route.
                    "background" -> {
                        val mode = com.piyush.mode.app.graph.background ?: error("no background mode in this build")
                        if (intent.getBooleanExtra("forget", false)) mode.turnOff()
                        else {
                            mode.enabled = intent.getBooleanExtra("on", true)
                            if (!mode.enabled) mode.stop()
                        }
                        "background=${mode.enabled}"
                    }
                    "bring" -> "brought=${com.piyush.mode.app.graph.background?.bringToUser()}"
                    "giveback" -> "back=${com.piyush.mode.app.graph.background?.giveBack()}"
                    "route" -> graph.session.phone().let { "state=${graph.session.state.value}" }
                    "helperstop" -> {
                        helper?.close()
                        helper = null
                        "stopped"
                    }
                    // Pretend this phone is another maker's, for its setup rows and guides: --es name samsung (empty: this phone)
                    "brand" -> {
                        com.piyush.mode.core.storage.SharedPrefsStore(context).putString(com.piyush.mode.feature.settings.domain.SettingsKeys.DEBUG_BRAND, intent.getStringExtra("name").orEmpty())
                        "brand=${com.piyush.mode.app.graph.brandOf(context)?.name ?: "none"}"
                    }
                    // What the quick settings read says now (no screenshot, no tap).
                    "status" -> graph.phoneChecks.status().joinToString(" ") { "${it.id}=${it.state}" }
                    "checks" -> buildString {
                        graph.phoneChecks.run { rows -> clear(); rows.forEach { append("${it.id}=${it.state} ") } }
                    }
                    else -> {
                        val phone = graph.session.phone()
                        when (name) {
                            "look" -> {
                                val shot = phone.send(Op.ScreenCapture(maxSize = 1000)).jsonObject
                                val text = phone.send(Op.ScreenText()) as JsonArray
                                "bounds=${shot["bounds"]} img=${shot["img_px"]} private=${shot["private"]} jpeg=${shot["jpeg_b64"]?.toString()?.length} texts=${text.size}: " +
                                    text.take(25).joinToString(" | ") { it.jsonObject["text"].toString() + "@" + it.jsonObject["x"] + "," + it.jsonObject["y"] + "/" + it.jsonObject["window"] }
                            }
                            "text" -> (phone.send(Op.ScreenText()) as JsonArray).joinToString("\n")
                            "tap" -> phone.send(Op.Tap(intent.getFloatExtra("x", 0f).toDouble(), intent.getFloatExtra("y", 0f).toDouble())).toString()
                            "back" -> phone.send(Op.Back).toString()
                            "home" -> phone.send(Op.Home).toString()
                            "recents" -> phone.send(Op.Recents).toString()
                            "notifications" -> phone.send(Op.OpenNotifications).toString()
                            "quick" -> phone.send(Op.OpenQuickSettings).toString()
                            "launch" -> phone.send(Op.LaunchApp(intent.getStringExtra("name").orEmpty(), fresh = intent.getBooleanExtra("fresh", false))).toString()
                            "type" -> phone.send(Op.TypeText(intent.getStringExtra("s").orEmpty())).toString()
                            "enter" -> phone.send(Op.PressKey("return")).toString()
                            "scroll" -> phone.send(Op.Scroll(180.0, 400.0, dy = if (intent.getStringExtra("dir") == "up") 300.0 else -300.0)).toString()
                            "current" -> phone.send(Op.CurrentApp).toString()
                            else -> "unknown op $name"
                        }
                    }
                }
            }
            val ms = started.elapsedNow().inWholeMilliseconds
            result.fold({ Log.i(TAG, "ok ${ms}ms $it") }, { Log.w(TAG, "failed ${ms}ms ${it::class.simpleName}: ${it.message}") })
            pending.finish()
        }
    }

    /**
     * Runs a CI op so that only a fixed reason can reach the log: whatever it throws becomes a [ProbeRefused]
     * (its own reason, or just the class name), never a message that could quote a token or the input file.
     */
    private suspend fun ciOnly(op: suspend () -> String): String =
        try { op() } catch (e: ProbeRefused) { throw e } catch (e: kotlinx.coroutines.CancellationException) { throw e } catch (e: Throwable) {
            throw ProbeRefused(e::class.simpleName ?: "Error")
        }

    private fun emulatorOrRefuse(asPhone: Boolean) {
        if (asPhone || !ProbeCi.isEmulator(::systemProperty)) throw ProbeRefused("not an emulator")
    }

    private fun signin(context: Context, graph: com.piyush.mode.app.graph.ModeGraph, asPhone: Boolean): String {
        val file = java.io.File(context.filesDir, ProbeCi.SIGNIN_FILE)
        try {
            emulatorOrRefuse(asPhone)
            if (!file.isFile) throw ProbeRefused("no ${ProbeCi.SIGNIN_FILE}")
            val r = ProbeCi.parseSignin(file.readText(), System.currentTimeMillis())
            val s = graph.settings
            val provider = when (r) {
                is ProbeCi.Signin.Claude -> {
                    s.claudeCredentials.save(com.piyush.mode.llm.ClaudeOAuth.Credentials(r.token, ProbeCi.PLACEHOLDER_REFRESH, r.expiresAtMs), newSignIn = true)
                    com.piyush.mode.llm.ModelProvider.ClaudeOAuth
                }
                is ProbeCi.Signin.OpenRouter -> {
                    s.apiKey = r.key
                    com.piyush.mode.llm.ModelProvider.OpenRouter
                }
            }
            s.selectProvider(provider)
            // This run's limits, set every time so a run never depends on what an earlier one left.
            s.update { it.copy(maxSteps = r.maxSteps, learnFromTasks = false, fullAccess = r.fullAccess) }
            if (!s.hasAccess(provider)) throw ProbeRefused("not connected after saving")
            val expires = (r as? ProbeCi.Signin.Claude)?.let { " expires=" + java.time.Instant.ofEpochMilli(it.expiresAtMs).toString().take(10) }.orEmpty()
            val name = if (r is ProbeCi.Signin.Claude) "claude" else "openrouter"
            return "signin provider=$name$expires maxSteps=${s.settings.value.maxSteps} fullAccess=${s.settings.value.fullAccess}"
        } finally {
            file.delete()
        }
    }

    private fun answer(graph: com.piyush.mode.app.graph.ModeGraph, text: String?, asPhone: Boolean): String {
        emulatorOrRefuse(asPhone)
        val q = graph.tasks.state.value.question
        val kind = q?.let { ProbeCi.kind(it.yesNo, it.allowAlways, it.yourTurn, it.options.size) }
        val reply = ProbeCi.answerFor(text, kind)
        graph.tasks.answer(q!!.id, reply)
        return "answered $reply to $kind: ${q.text}"
    }

    /** A system property, through `getprop` (android.os.SystemProperties is not public API). */
    private fun systemProperty(name: String): String? = runCatching {
        val p = ProcessBuilder("getprop", name).redirectErrorStream(true).start()
        p.inputStream.bufferedReader().use { it.readText() }.also { p.waitFor() }
    }.getOrNull()

    private companion object {
        const val TAG = "ModeProbe"
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        var adbLink: com.piyush.mode.adb.AdbLink? = null
        var helper: com.piyush.mode.adb.HelperSession? = null
    }
}
