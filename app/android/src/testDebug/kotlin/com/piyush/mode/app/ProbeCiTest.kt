package com.piyush.mode.app

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertTrue

class ProbeCiTest {
    private val now = 1_800_000_000_000L
    private val year = now + 365L * 24 * 60 * 60 * 1000
    private val secret = "sk-ant-oat01-FAKE-not-a-real-token-0123456789"

    private fun refusal(json: String): String = assertFailsWith<ProbeRefused> { ProbeCi.parseSignin(json, now) }.message!!

    @Test
    fun readsAClaudeSignin() {
        val s = ProbeCi.parseSignin("""{"provider":"claude","token":"$secret","expires_at_ms":$year,"max_steps":15}""", now)
        assertIs<ProbeCi.Signin.Claude>(s)
        assertEquals(secret, s.token)
        assertEquals(year, s.expiresAtMs)
        assertEquals(15, s.maxSteps)
        assertFalse(s.fullAccess, "full access is off unless the file says so")
    }

    @Test
    fun readsAnOpenRouterSigninWithFullAccess() {
        val s = ProbeCi.parseSignin("""{"provider":"openrouter","token":"sk-or-x","max_steps":15,"full_access":true}""", now)
        assertIs<ProbeCi.Signin.OpenRouter>(s)
        assertEquals("sk-or-x", s.key)
        assertTrue(s.fullAccess)
    }

    @Test
    fun refusesWithAFixedReasonThatNeverQuotesTheInput() {
        val cases = listOf(
            """{"provider":"claude","token":"$secret","expires_at_ms":$year""" to "not a JSON object",
            "[\"$secret\"]" to "not a JSON object",
            """{"provider":"claude","expires_at_ms":$year,"max_steps":15}""" to "token missing",
            """{"provider":"claude","token":"  ","expires_at_ms":$year,"max_steps":15}""" to "token missing",
            """{"provider":"claude","token":42,"expires_at_ms":$year,"max_steps":15}""" to "token missing",
            """{"provider":"claude","token":"$secret","max_steps":15}""" to "expires_at_ms missing",
            """{"provider":"claude","token":"$secret","expires_at_ms":"$secret","max_steps":15}""" to "expires_at_ms missing",
            """{"provider":"claude","token":"$secret","expires_at_ms":$year}""" to "max_steps missing or not 1 to 200",
            """{"provider":"claude","token":"$secret","expires_at_ms":$year,"max_steps":0}""" to "max_steps missing or not 1 to 200",
            """{"provider":"claude","token":"$secret","expires_at_ms":$year,"max_steps":201}""" to "max_steps missing or not 1 to 200",
            """{"provider":"claude","token":"$secret","expires_at_ms":$year,"max_steps":15,"full_access":"$secret"}""" to "full_access not true or false",
            """{"provider":"$secret","token":"$secret","max_steps":15}""" to "provider not claude or openrouter",
            """{"token":"$secret","max_steps":15}""" to "provider not claude or openrouter",
        )
        for ((json, reason) in cases) {
            val message = refusal(json)
            assertEquals(reason, message, json)
            assertFalse(secret in message || "FAKE" in message, "the refusal quotes the input: $message")
        }
    }

    @Test
    fun refusesAClaudeExpiryLessThanADayAhead() {
        val day = 24L * 60 * 60 * 1000
        for (expires in listOf(now - 1, now, now + 60_000, now + day - 1)) {
            assertEquals("expires_at_ms less than a day ahead", refusal("""{"provider":"claude","token":"t","expires_at_ms":$expires,"max_steps":15}"""))
        }
        ProbeCi.parseSignin("""{"provider":"claude","token":"t","expires_at_ms":${now + day},"max_steps":15}""", now)
    }

    @Test
    fun aSigninNeverPrintsItsSecret() {
        val claude = ProbeCi.parseSignin("""{"provider":"claude","token":"$secret","expires_at_ms":$year,"max_steps":15}""", now)
        val openRouter = ProbeCi.parseSignin("""{"provider":"openrouter","token":"$secret","max_steps":15}""", now)
        assertFalse(secret in claude.toString(), claude.toString())
        assertFalse(secret in openRouter.toString(), openRouter.toString())
    }

    @Test
    fun anEmulatorIsQemuOne() {
        assertTrue(ProbeCi.isEmulator { if (it == "ro.kernel.qemu") "1\n" else "" })
        assertTrue(ProbeCi.isEmulator { if (it == "ro.boot.qemu") "1" else null })
        assertFalse(ProbeCi.isEmulator { "" }, "a real phone")
        assertFalse(ProbeCi.isEmulator { null }, "getprop failed")
        assertFalse(ProbeCi.isEmulator { "0" })
    }

    @Test
    fun namesQuestionKindsAsTheNotifierDoes() {
        assertEquals("YourTurn", ProbeCi.kind(yesNo = true, allowAlways = true, yourTurn = true, options = 0))
        assertEquals("YesNoAlways", ProbeCi.kind(yesNo = true, allowAlways = true, yourTurn = false, options = 0))
        assertEquals("YesNo", ProbeCi.kind(yesNo = true, allowAlways = false, yourTurn = false, options = 0))
        assertEquals("Choice", ProbeCi.kind(yesNo = false, allowAlways = false, yourTurn = false, options = 2))
        assertEquals("Text", ProbeCi.kind(yesNo = false, allowAlways = false, yourTurn = false, options = 1))
    }

    @Test
    fun answersOnlyYesOrNoToAYesNoQuestion() {
        assertEquals("yes", ProbeCi.answerFor("yes", "YesNo"))
        assertEquals("no", ProbeCi.answerFor("no", "YesNoAlways"))
        for (text in listOf("always", "Yes", "yes ", "y", "", null)) {
            assertEquals("text must be yes or no", assertFailsWith<ProbeRefused> { ProbeCi.answerFor(text, "YesNoAlways") }.message, "text=$text")
        }
        assertEquals("nothing pending", assertFailsWith<ProbeRefused> { ProbeCi.answerFor("yes", null) }.message)
        for (kind in listOf("YourTurn", "Choice", "Text")) {
            assertEquals("not a yes/no question ($kind)", assertFailsWith<ProbeRefused> { ProbeCi.answerFor("yes", kind) }.message)
        }
    }
}
