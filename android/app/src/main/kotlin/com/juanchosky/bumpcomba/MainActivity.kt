package com.juanchosky.bumpcomba

import android.app.PendingIntent
import android.app.PictureInPictureParams
import android.app.RemoteAction
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.res.Configuration
import android.graphics.drawable.Icon
import android.os.Build
import android.util.Rational
import androidx.activity.enableEdgeToEdge
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterFragmentActivity() {
    private val CHANNEL = "com.juanchosky.bumpcomba/pip"
    private val ACTION_MEDIA_CONTROL = "media_control"
    private val EXTRA_CONTROL_TYPE = "control_type"
    private val CONTROL_TYPE_PLAY = 1
    private val CONTROL_TYPE_PAUSE = 2

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent == null || intent.action != ACTION_MEDIA_CONTROL) return
            
            val controlType = intent.getIntExtra(EXTRA_CONTROL_TYPE, 0)
            when (controlType) {
                CONTROL_TYPE_PLAY -> {
                    flutterEngine?.dartExecutor?.binaryMessenger?.let {
                        MethodChannel(it, CHANNEL).invokeMethod("pipPlay", null)
                    }
                    updatePiPActions(true)
                }
                CONTROL_TYPE_PAUSE -> {
                    flutterEngine?.dartExecutor?.binaryMessenger?.let {
                        MethodChannel(it, CHANNEL).invokeMethod("pipPause", null)
                    }
                    updatePiPActions(false)
                }
            }
        }
    }

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        // Enable edge-to-edge for Android 15 compatibility
        // This prevents the use of deprecated setStatusBarColor / setNavigationBarColor APIs
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(receiver, IntentFilter(ACTION_MEDIA_CONTROL), Context.RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(receiver, IntentFilter(ACTION_MEDIA_CONTROL))
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        unregisterReceiver(receiver)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "enterPiP") {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    val width = call.argument<Int>("width")
                    val height = call.argument<Int>("height")
                    val playing = call.argument<Boolean>("playing") ?: false
                    
                    val builder = PictureInPictureParams.Builder()
                    
                    if (width != null && height != null) {
                         val aspectRatio = Rational(width, height)
                         builder.setAspectRatio(aspectRatio)
                    } else {
                         val aspectRatio = Rational(16, 9)
                         builder.setAspectRatio(aspectRatio)
                    }

                    updatePiPActions(playing, builder)
                    
                    enterPictureInPictureMode(builder.build())
                    result.success(null)
                } else {
                    result.error("UNAVAILABLE", "PiP not supported on this Android version", null)
                }
            } else if (call.method == "isPiP") {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                    result.success(isInPictureInPictureMode)
                } else {
                    result.success(false)
                }
            } else if (call.method == "updatePiPState") {
                 val playing = call.argument<Boolean>("playing") ?: false
                 updatePiPActions(playing)
                 result.success(null)
            } else {
                result.notImplemented()
            }
        }
    }

    private fun updatePiPActions(playing: Boolean, builder: PictureInPictureParams.Builder? = null) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        
        val iconId = if (playing) android.R.drawable.ic_media_pause else android.R.drawable.ic_media_play
        val title = if (playing) "Pause" else "Play"
        val controlType = if (playing) CONTROL_TYPE_PAUSE else CONTROL_TYPE_PLAY
        val requestCode = if (playing) 2 else 1

        val intent = Intent(ACTION_MEDIA_CONTROL).apply {
            putExtra(EXTRA_CONTROL_TYPE, controlType)
            setPackage(packageName) 
        }
        
        val pendingIntent = PendingIntent.getBroadcast(
            this, 
            requestCode, 
            intent, 
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        
        val icon = Icon.createWithResource(this, iconId)
        val action = RemoteAction(icon, title, title, pendingIntent)
        val actions = arrayListOf(action)

        if (builder != null) {
            builder.setActions(actions)
        } else {
            val paramsBuilder = PictureInPictureParams.Builder()
            paramsBuilder.setActions(actions)
            setPictureInPictureParams(paramsBuilder.build())
        }
    }
}
