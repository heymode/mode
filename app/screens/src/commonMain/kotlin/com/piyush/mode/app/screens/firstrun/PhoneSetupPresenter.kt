package com.piyush.mode.app.screens.firstrun

import com.piyush.mode.app.screens.common.Presenter
import com.piyush.mode.core.common.AppLog
import com.piyush.mode.core.platform.AppLifecycle
import com.piyush.mode.core.platform.Permission
import com.piyush.mode.core.platform.PermissionStatus
import com.piyush.mode.core.platform.Permissions
import com.piyush.mode.feature.connection.domain.CheckState
import com.piyush.mode.feature.connection.domain.DeviceStatus
import com.piyush.mode.feature.connection.domain.PhoneCheckId
import com.piyush.mode.feature.connection.domain.PhoneChecks
import com.piyush.mode.feature.settings.data.SettingsRepository
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.job
import kotlinx.coroutines.launch

/** One thing phone control needs, on the "Let Mode use your phone" page. */
public enum class PhoneSetupKind {
    /** The accessibility switch: required. */
    PhoneControl,
    /** Questions and progress in notifications. */
    Notifications,
    /** Start by voice: the "Ask Mode" entry the user's own assistant opens. Optional, and can be turned off. */
    Assistant,
    /** Asked the first time the user speaks. */
    Microphone,
    /** Unrestricted battery, so a task is not cut off: optional. */
    Battery,
    /** Samsung's "Never sleeping apps": Mode can't read it, the user confirms it. Optional. */
    Sleeping,
    /** Xiaomi's (and others') Autostart list: confirmed by the user. Optional. */
    Autostart,
    /** Xiaomi's "Display pop-up windows while running in the background": confirmed by the user. Optional. */
    Popups,
    /** The accessibility shortcut (button, gesture, volume keys) opens Mode over any app. Optional. */
    Shortcut,
}

/** A page that walks the user through one Android setting, then sends them there. */
public enum class PhoneSetupGuide {
    /** Android 13+ locks the accessibility switch of an app not from a store: App info › ⋮ › Allow restricted settings. */
    RestrictedSettings,
    /** Settings › Accessibility › Mode › on. */
    PhoneControl,
    /** Default apps › Digital assistant › Mode. */
    Assistant,
    /** App info › Battery › Unrestricted. */
    Battery,
    /** Battery › Background usage limits › Never sleeping apps › add Mode (board D03). */
    Sleeping,
    /** The maker's Autostart list › Mode on (board D04). */
    Autostart,
    /** Mode's permissions › Other permissions › pop-up windows in the background (board D05). */
    Popups,
    /** Point the phone's accessibility shortcut at Mode. */
    Shortcut,
}

public data class PhoneSetupRow(
    val kind: PhoneSetupKind,
    val status: PermissionStatus,
    /** Not needed for Continue. */
    val optional: Boolean,
    /** Asked later, by itself (the microphone): nothing to do here. */
    val later: Boolean = false,
    /** Mode can't read this one back: the user does it and confirms ("I've done this"). */
    val manual: Boolean = false,
)

/**
 * Unlocking phone control on a phone that locked it (an APK from a download), in the order Android needs: the
 * locked switch is tried once first, because only then does App info show "Allow restricted settings" (seen on
 * Android 17: before that try, App info has no ⋮ menu at all); then the switch is turned on.
 */
public enum class UnlockStep {
    /** Accessibility › Mode: Android answers "App was denied access"; Close. */
    TryTheSwitch,
    /** Mode's App info › ⋮ › Allow restricted settings, confirmed with the screen lock. */
    AllowRestricted,
    /** Mode's switch in Accessibility, then Allow. */
    TurnOn,
}

public data class PhoneSetupUiState(
    val rows: List<PhoneSetupRow> = emptyList(),
    /** The guide page open now, or none. */
    val guide: PhoneSetupGuide? = null,
    /** Phone control is on: Continue works. */
    val ready: Boolean = false,
    /** Android locks the switch until restricted settings are allowed (the guide for that comes first). */
    val locked: Boolean = false,
    /** Where the unlock guide is; it moves on each time the user comes back from the page a step opened. */
    val unlockStep: UnlockStep = UnlockStep.TryTheSwitch,
    /** The unlock guide's overview is open: every step at once, with what each Android screen looks like. */
    val unlockOverview: Boolean = false,
)

/**
 * "Let Mode use your phone" (Android): what phone control needs, each with its state, and a guide page for
 * the ones the user turns on in Settings. Everything is read again when Mode comes back to the front, so a
 * switch turned on in Settings shows at once, and a guide whose setting is done closes itself.
 */
public class PhoneSetupPresenter(
    parent: CoroutineScope,
    private val checks: PhoneChecks,
    private val permissions: Permissions,
    lifecycle: AppLifecycle,
    /** Where the steps the user confirmed are kept; null: no manual steps on this phone. */
    private val settings: SettingsRepository? = null,
) : Presenter<PhoneSetupUiState>(parent, PhoneSetupUiState()) {

    init {
        refresh()
        val stop = lifecycle.watchForeground { refresh() }
        scope.coroutineContext.job.invokeOnCompletion { stop() }
    }

    /** The unlock step whose Android page the user went to; coming back from it moves the guide on. */
    private var awayOn: UnlockStep? = null

    /** Reads every setting again (also on returning from Settings). */
    public fun refresh() {
        comeBack()
        scope.launch {
            val status = checks.status().associate { it.id to it.state }
            val control = status[PhoneCheckId.Engine]
            val locked = status[PhoneCheckId.RestrictedSettings] is CheckState.Failed
            val battery = status[PhoneCheckId.Battery]
            val rows = (listOf(
                PhoneSetupRow(PhoneSetupKind.PhoneControl, if (control is CheckState.Passed) PermissionStatus.Allowed else PermissionStatus.NotAsked, optional = false),
                PhoneSetupRow(PhoneSetupKind.Notifications, permissions.status(Permission.Notifications), optional = true),
                PhoneSetupRow(PhoneSetupKind.Assistant, permissions.status(Permission.Assistant), optional = true),
                PhoneSetupRow(PhoneSetupKind.Battery, if (battery is CheckState.Passed) PermissionStatus.Allowed else PermissionStatus.NotAsked, optional = true),
            ) + manualRows(status) + listOf(
                PhoneSetupRow(PhoneSetupKind.Microphone, permissions.status(Permission.Microphone), optional = true, later = true),
            )).filter { it.status != PermissionStatus.Unavailable }
            val ready = control is CheckState.Passed
            mutableState.value = mutableState.value.let { s ->
                val done = s.guide != null && guideDone(s.guide, rows, locked)
                if (done) AppLog.log("setup", "${s.guide} done")
                s.copy(rows = rows, ready = ready, locked = locked, guide = if (done) null else s.guide)
            }
        }
    }

    /** The maker's steps only the user can confirm, in the order the checks list them (none on a plain phone). */
    private fun manualRows(status: Map<PhoneCheckId, CheckState>): List<PhoneSetupRow> = MANUAL.mapNotNull { (id, kind) ->
        val state = status[id] as? CheckState.Unverifiable ?: return@mapNotNull null
        PhoneSetupRow(kind, if (state.confirmed) PermissionStatus.Allowed else PermissionStatus.NotAsked, optional = true, manual = true)
    }

    /** "I've done this" on a manual guide: remembered, and the row reads as done. */
    public fun done(kind: PhoneSetupKind) {
        val step = MANUAL.entries.firstOrNull { it.value == kind }?.key?.let(DeviceStatus::step) ?: return
        AppLog.log("setup", "$kind confirmed by the user")
        settings?.update { it.copy(deviceSteps = it.deviceSteps + step.name) }
        mutableState.value = mutableState.value.copy(guide = null)
        refresh()
    }

    /** The row's button: a prompt for notifications, else the guide for that setting. */
    public fun allow(kind: PhoneSetupKind) {
        when (kind) {
            PhoneSetupKind.Notifications -> scope.launch {
                permissions.request(Permission.Notifications)
                refresh()
            }
            PhoneSetupKind.Microphone -> scope.launch {
                permissions.request(Permission.Microphone)
                refresh()
            }
            PhoneSetupKind.PhoneControl -> open(if (state.value.locked) PhoneSetupGuide.RestrictedSettings else PhoneSetupGuide.PhoneControl)
            PhoneSetupKind.Assistant -> open(PhoneSetupGuide.Assistant)
            PhoneSetupKind.Battery -> open(PhoneSetupGuide.Battery)
            PhoneSetupKind.Sleeping -> open(PhoneSetupGuide.Sleeping)
            PhoneSetupKind.Autostart -> open(PhoneSetupGuide.Autostart)
            PhoneSetupKind.Popups -> open(PhoneSetupGuide.Popups)
            PhoneSetupKind.Shortcut -> open(PhoneSetupGuide.Shortcut)
        }
    }

    /**
     * The app is about to open Android's page for [guide]. On the unlock guide, coming back from it counts as that
     * step done: Android 17 keeps "Allow restricted settings" to the system (apps can't read it), so the guide
     * follows the user, and the switch turning on is what closes it.
     */
    public fun leaving(guide: PhoneSetupGuide) {
        if (guide == PhoneSetupGuide.RestrictedSettings) awayOn = state.value.unlockStep
    }

    private fun comeBack() {
        val step = awayOn ?: return
        awayOn = null
        val s = mutableState.value
        if (s.guide != PhoneSetupGuide.RestrictedSettings || s.unlockStep != step) return
        val next = UnlockStep.entries.getOrNull(step.ordinal + 1) ?: return
        AppLog.log("setup", "unlock: back from $step, on to $next")
        mutableState.value = s.copy(unlockStep = next)
    }

    /**
     * The unlock guide's second button: "I've done this" on the first step, and back a step on the others (no
     * Allow restricted settings in App info means the switch wasn't tried; still "denied" means it wasn't allowed).
     */
    public fun unlockAlternative() {
        val s = mutableState.value
        val to = when (s.unlockStep) {
            UnlockStep.TryTheSwitch -> UnlockStep.AllowRestricted
            UnlockStep.AllowRestricted -> UnlockStep.TryTheSwitch
            UnlockStep.TurnOn -> UnlockStep.AllowRestricted
        }
        AppLog.log("setup", "unlock: ${s.unlockStep} → $to by hand")
        mutableState.value = s.copy(unlockStep = to)
    }

    /** The "i" on the unlock guide: every step at once, with the Android screens. */
    public fun showUnlockSteps(show: Boolean) {
        mutableState.value = mutableState.value.copy(unlockOverview = show)
    }

    public fun closeGuide() {
        awayOn = null
        mutableState.value = mutableState.value.copy(guide = null, unlockOverview = false)
    }

    private fun open(guide: PhoneSetupGuide) {
        AppLog.log("setup", "guide $guide")
        // The unlock guide always starts from its first step: the order is what makes it work.
        mutableState.value = mutableState.value.copy(guide = guide, unlockStep = UnlockStep.TryTheSwitch, unlockOverview = false)
    }

    private fun guideDone(guide: PhoneSetupGuide, rows: List<PhoneSetupRow>, locked: Boolean): Boolean {
        fun allowed(kind: PhoneSetupKind) = rows.first { it.kind == kind }.status == PermissionStatus.Allowed
        return when (guide) {
            // Unlocking can't be read directly; the switch being on proves it.
            PhoneSetupGuide.RestrictedSettings -> allowed(PhoneSetupKind.PhoneControl) || !locked
            PhoneSetupGuide.PhoneControl -> allowed(PhoneSetupKind.PhoneControl)
            PhoneSetupGuide.Assistant -> allowed(PhoneSetupKind.Assistant)
            PhoneSetupGuide.Battery -> allowed(PhoneSetupKind.Battery)
            // Manual guides close on "I've done this", never by themselves.
            PhoneSetupGuide.Sleeping, PhoneSetupGuide.Autostart, PhoneSetupGuide.Popups -> false
            // The button or gesture set to Mode is read back; the volume keys only by "I've done this".
            PhoneSetupGuide.Shortcut -> allowed(PhoneSetupKind.Shortcut)
        }
    }

    private companion object {
        val MANUAL = linkedMapOf(
            PhoneCheckId.Sleeping to PhoneSetupKind.Sleeping,
            PhoneCheckId.Autostart to PhoneSetupKind.Autostart,
            PhoneCheckId.Popups to PhoneSetupKind.Popups,
            PhoneCheckId.Shortcut to PhoneSetupKind.Shortcut,
        )
    }
}
