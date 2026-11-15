package com.piyush.mode.tools.claudecheck

import com.piyush.mode.llm.ChatMessage
import com.piyush.mode.llm.ClaudeOAuthClient
import io.ktor.client.HttpClient
import io.ktor.client.engine.okhttp.OkHttp
import io.ktor.client.plugins.HttpSend
import io.ktor.client.plugins.plugin
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.JsonArray

/**
 * Sends one model request with the Claude token in CLAUDE_CODE_OAUTH_TOKEN, the way Mode sends it
 * (ClaudeOAuthClient), and prints exactly one line:
 * - `accepted`: Claude answered with a success status;
 * - `refused HTTP <code>`: it answered with any other status;
 * - otherwise only the class name of the error (no token, no network, …).
 * The status comes from the HTTP client itself, never from Mode's error message, which can quote the
 * server's reply. Nothing else is printed: not the token, not the reply, no stack trace.
 */
fun main() {
    println(runBlocking { check() })
}

private suspend fun check(): String {
    var status: Int? = null
    return try {
        val token = System.getenv("CLAUDE_CODE_OAUTH_TOKEN")?.takeIf { it.isNotBlank() } ?: throw NoToken()
        HttpClient(OkHttp).use { http ->
            // The status of the last response, whatever Mode's client then makes of it.
            http.plugin(HttpSend).intercept { request -> execute(request).also { status = it.response.status.value } }
            ClaudeOAuthClient(http, token = { token })
                .chat(ClaudeOAuthClient.MAIN_MODEL, listOf(ChatMessage("user", "Reply with OK.")), JsonArray(emptyList()))
        }
        "accepted"
    } catch (e: Throwable) {
        when (val code = status) {
            null -> e::class.simpleName ?: "Error"
            in 200..299 -> "accepted" // Claude took the token; only reading its answer failed, which is Mode's side.
            else -> "refused HTTP $code"
        }
    }
}

private class NoToken : Exception()
