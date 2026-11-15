package com.piyush.mode.app

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.longOrNull

/**
 * Debug builds only: the checks behind DevProbe's `signin` and `answer` ops, which the emulator's real-task
 * job uses (emulator-tasks-plan.md, slice 2). Pure, so it is unit-tested; DevProbe does the I/O.
 *
 * Nothing here may put a token, an answer file's contents or an exception's message into a log: every
 * refusal is a [ProbeRefused] with a fixed reason.
 */
internal object ProbeCi {
    /** The file the script writes into Mode's private folder (files/) for `signin`; the op deletes it. */
    const val SIGNIN_FILE = "probe-signin.json"

    /** Never a real refresh token: every 401 sends this to Claude's sign-in server, which refuses it. */
    const val PLACEHOLDER_REFRESH = "ci-placeholder-no-refresh"

    private const val DAY_MS = 24L * 60 * 60 * 1000

    /** What `signin` saves. Not data classes: toString must never show the secret. */
    sealed class Signin(val maxSteps: Int, val fullAccess: Boolean) {
        class Claude(val token: String, val expiresAtMs: Long, maxSteps: Int, fullAccess: Boolean) : Signin(maxSteps, fullAccess) {
            override fun toString() = "Claude(expiresAtMs=$expiresAtMs, maxSteps=$maxSteps, fullAccess=$fullAccess)"
        }
        class OpenRouter(val key: String, maxSteps: Int, fullAccess: Boolean) : Signin(maxSteps, fullAccess) {
            override fun toString() = "OpenRouter(maxSteps=$maxSteps, fullAccess=$fullAccess)"
        }
    }

    /**
     * Reads the signin file: `provider` (claude or openrouter), `token`, `expires_at_ms` (claude only; at
     * least a day ahead of [nowMs]), `max_steps` (1 to 200) and `full_access` (optional, false).
     */
    fun parseSignin(json: String, nowMs: Long): Signin {
        val o = runCatching { Json.parseToJsonElement(json) as JsonObject }.getOrNull() ?: throw ProbeRefused("not a JSON object")
        val token = (o["token"] as? JsonPrimitive)?.takeIf { it.isString }?.content?.trim()
        if (token.isNullOrEmpty()) throw ProbeRefused("token missing")
        val maxSteps = (o["max_steps"] as? JsonPrimitive)?.intOrNull?.takeIf { it in 1..200 } ?: throw ProbeRefused("max_steps missing or not 1 to 200")
        val fullAccess = when (val f = o["full_access"]) {
            null -> false
            else -> (f as? JsonPrimitive)?.booleanOrNull ?: throw ProbeRefused("full_access not true or false")
        }
        return when ((o["provider"] as? JsonPrimitive)?.content) {
            "claude" -> {
                val expires = (o["expires_at_ms"] as? JsonPrimitive)?.longOrNull ?: throw ProbeRefused("expires_at_ms missing")
                // Mode refreshes a token that is about to expire, which fails on the placeholder: a stale date
                // would look exactly like a revoked token, so it is refused here instead.
                if (expires < nowMs + DAY_MS) throw ProbeRefused("expires_at_ms less than a day ahead")
                Signin.Claude(token, expires, maxSteps, fullAccess)
            }
            "openrouter" -> Signin.OpenRouter(token, maxSteps, fullAccess)
            else -> throw ProbeRefused("provider not claude or openrouter")
        }
    }

    /** True on an emulator: the probe receiver is exported, so these ops refuse everywhere else. */
    fun isEmulator(prop: (String) -> String?): Boolean =
        prop("ro.kernel.qemu")?.trim() == "1" || prop("ro.boot.qemu")?.trim() == "1"

    /** The kind of a pending question, named as the notifier names it (QuestionKind). */
    fun kind(yesNo: Boolean, allowAlways: Boolean, yourTurn: Boolean, options: Int): String = when {
        yourTurn -> "YourTurn"
        yesNo && allowAlways -> "YesNoAlways"
        yesNo -> "YesNo"
        options >= 2 -> "Choice"
        else -> "Text"
    }

    /**
     * The answer `answer` may give: exactly "yes" or "no", only to a pending yes/no question. Never "always"
     * ("Yes, and don't ask again" turns full access on for the rest of the run).
     */
    fun answerFor(text: String?, pendingKind: String?): String {
        if (text != "yes" && text != "no") throw ProbeRefused("text must be yes or no")
        if (pendingKind == null) throw ProbeRefused("nothing pending")
        if (pendingKind != "YesNo" && pendingKind != "YesNoAlways") throw ProbeRefused("not a yes/no question ($pendingKind)")
        return text
    }
}

/** A refusal with a fixed reason: DevProbe logs it as "failed <ms>ms ProbeRefused: <reason>". */
internal class ProbeRefused(reason: String) : Exception(reason)
