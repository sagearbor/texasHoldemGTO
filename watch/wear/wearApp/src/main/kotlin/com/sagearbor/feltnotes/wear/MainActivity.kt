package com.sagearbor.feltnotes.wear

import android.content.Intent
import android.os.Bundle
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import androidx.wear.compose.material.Button
import androidx.wear.compose.material.ButtonDefaults
import androidx.wear.compose.material.MaterialTheme
import androidx.wear.compose.material.Scaffold
import androidx.wear.compose.material.Text
import androidx.wear.compose.material.TimeText
import androidx.wear.ambient.AmbientLifecycleObserver
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * v1 Pulse runs while this activity is on screen (no foreground service, see
 * PulseController): the screen is kept on during a session, and ambient
 * support lets it dim instead of leaving the app, while MeasureClient keeps
 * measuring and samples keep going to the phone. Leaving the app stops Pulse.
 */
class MainActivity : ComponentActivity() {

    private val ambient = mutableStateOf(false)

    private val askPermissions = registerForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions(),
    ) {
        if (HrPermission.granted(this)) {
            PulseController.start(this)
        } else {
            PulseController.publishState(this, running = false, err = PulseErr.NO_PERMISSION)
        }
    }

    private val ambientObserver = AmbientLifecycleObserver(
        this,
        object : AmbientLifecycleObserver.AmbientLifecycleCallback {
            override fun onEnterAmbient(ambientDetails: AmbientLifecycleObserver.AmbientDetails) {
                ambient.value = true
            }
            override fun onExitAmbient() {
                ambient.value = false
            }
            override fun onUpdateAmbient() = Unit
        },
    )

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        lifecycle.addObserver(ambientObserver)
        setContent {
            val ui by PulseBus.ui.collectAsStateWithLifecycle()
            PulseScreen(ui, ambient.value, onToggle = { if (ui.running) stopPulse() else startPulse() })
        }
        // Screen stays on while a session runs (dims to ambient, never sleeps
        // away from the app, which would stop the measurement).
        lifecycleScope.launch {
            PulseBus.ui.collectLatest { ui ->
                if (ui.running) window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                else window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            }
        }
        // "Phone connected" line: re-check every few seconds while visible.
        lifecycleScope.launch {
            repeatOnLifecycle(Lifecycle.State.STARTED) {
                while (true) {
                    PhoneLink.refresh(this@MainActivity)
                    delay(5_000)
                }
            }
        }
        handleAutostart(intent)
    }

    override fun onStart() {
        super.onStart()
        PulseController.activityVisible = true
    }

    override fun onStop() {
        PulseController.activityVisible = false
        // No foreground service in v1: off screen we can't keep measuring.
        if (PulseController.running && !isChangingConfigurations) {
            PulseController.stop(this, PulseErr.APP_CLOSED)
        }
        super.onStop()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleAutostart(intent)
    }

    /** Opened from the "Tap to start" notification (phone asked to start). */
    private fun handleAutostart(intent: Intent?) {
        if (intent?.getBooleanExtra(PulseController.EXTRA_AUTOSTART, false) == true) {
            intent.removeExtra(PulseController.EXTRA_AUTOSTART)
            PulseController.clearTapToStart(this)
            startPulse()
        }
    }

    private fun startPulse() {
        // Asked every Start: heart rate (BODY_SENSORS, or READ_HEART_RATE on
        // Wear OS 6) plus notifications. Already-granted ones don't prompt.
        askPermissions.launch(HrPermission.toRequest())
    }

    private fun stopPulse() = PulseController.stop(this)
}

@Composable
private fun PulseScreen(ui: PulseUi, ambient: Boolean, onToggle: () -> Unit) {
    MaterialTheme {
        Scaffold(timeText = { if (!ambient) TimeText() }) {
            Column(
                modifier = Modifier.fillMaxSize().padding(horizontal = 14.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.Center,
            ) {
                Spacer(Modifier.height(10.dp))
                Text(
                    text = ui.bpm?.toString() ?: "--",
                    fontSize = 52.sp,
                    fontWeight = FontWeight.Bold,
                    color = when {
                        ambient -> Color.Gray
                        ui.running -> Color(0xFFFF5A5F)
                        else -> MaterialTheme.colors.onBackground
                    },
                )
                Text("bpm", fontSize = 12.sp, color = MaterialTheme.colors.onSurfaceVariant)
                Spacer(Modifier.height(6.dp))
                Button(
                    onClick = onToggle,
                    enabled = !ambient,
                    modifier = Modifier.size(ButtonDefaults.DefaultButtonSize),
                    colors = if (ui.running) ButtonDefaults.secondaryButtonColors() else ButtonDefaults.primaryButtonColors(),
                ) {
                    Text(if (ui.running) "Stop" else "Start")
                }
                Spacer(Modifier.height(6.dp))
                Text(
                    text = statusLine(ui),
                    fontSize = 12.sp,
                    textAlign = TextAlign.Center,
                    color = MaterialTheme.colors.onSurfaceVariant,
                )
            }
        }
    }
}

private fun statusLine(ui: PulseUi): String = when {
    ui.err == PulseErr.NO_PERMISSION -> "Allow heart rate to start"
    ui.err == PulseErr.UNSUPPORTED -> "No heart-rate sensor"
    ui.err == PulseErr.SENSOR_ERROR -> "Heart rate stopped"
    !ui.phoneConnected -> "Phone not connected"
    ui.running -> "Sending to your phone"
    else -> "Phone connected"
}
