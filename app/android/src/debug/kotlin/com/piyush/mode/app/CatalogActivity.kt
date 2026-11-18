package com.piyush.mode.app

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.systemBarsPadding
import com.piyush.mode.design.ModeCatalog
import com.piyush.mode.design.ModeTheme

/**
 * Debug builds only: the design system's catalogue, or one unlock guide page to look at without a locked install.
 *     adb shell am start -n app.heymode.mode/com.piyush.mode.app.CatalogActivity --ez dark true
 *     adb shell am start -n app.heymode.mode/com.piyush.mode.app.CatalogActivity --es unlock 1|2|3|all
 */
class CatalogActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        val dark = intent.getBooleanExtra("dark", false)
        val unlock = intent.getStringExtra("unlock")
        setContent {
            ModeTheme(dark = dark) {
                if (unlock == null) ModeCatalog() else {
                    val state = com.piyush.mode.app.screens.firstrun.PhoneSetupUiState(
                        guide = com.piyush.mode.app.screens.firstrun.PhoneSetupGuide.RestrictedSettings, locked = true,
                        unlockStep = com.piyush.mode.app.screens.firstrun.UnlockStep.entries[(unlock.toIntOrNull() ?: 1).coerceIn(1, 3) - 1],
                        unlockOverview = unlock == "all",
                    )
                    androidx.compose.foundation.layout.Box(
                        androidx.compose.ui.Modifier.fillMaxSize().background(com.piyush.mode.design.Mode.colors.page).systemBarsPadding(),
                    ) { com.piyush.mode.app.firstrun.PhoneSetupScreen(state, dots = null) { } }
                }
            }
        }
    }
}
