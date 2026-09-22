package dev.continuum.chat

import android.app.Activity
import android.content.Context
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Bundle
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.widget.LinearLayout
import android.widget.TextView

/// 闹钟响铃全屏页（v0.2.128 移植 Nudge RingingActivity.kt，纯代码 UI）：
/// 锁屏/息屏都会弹出来（showWhenLocked + turnScreenOn），大按钮关闭。
class RingingActivity : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        if (Build.VERSION.SDK_INT >= 27) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        } else {
            @Suppress("DEPRECATION")
            window.addFlags(
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON or
                WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON
            )
        }

        val title = intent.getStringExtra("title") ?: "闹钟"
        val note = intent.getStringExtra("note") ?: ""

        val bg = GradientDrawable().apply {
            setColor(Color.parseColor("#1A2233"))
        }
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            background = bg
            setPadding(40, 40, 40, 40)
        }

        root.addView(TextView(this).apply {
            text = "⏰"
            textSize = 64f
            gravity = Gravity.CENTER
        })

        root.addView(TextView(this).apply {
            text = title
            textSize = 30f
            setTextColor(Color.WHITE)
            typeface = Typeface.DEFAULT_BOLD
            gravity = Gravity.CENTER
            setPadding(0, 24, 0, 0)
        })

        root.addView(TextView(this).apply {
            text = if (note.isNotBlank()) note else "时间到啦"
            textSize = 16f
            setTextColor(Color.parseColor("#9CA3AF"))
            gravity = Gravity.CENTER
            setPadding(0, 12, 0, 0)
        })

        val stopBtn = TextView(this).apply {
            text = "关 闭"
            textSize = 20f
            setTextColor(Color.WHITE)
            typeface = Typeface.DEFAULT_BOLD
            gravity = Gravity.CENTER
            setPadding(0, 18, 0, 18)
            background = GradientDrawable().apply {
                cornerRadius = 50f
                setColor(Color.parseColor("#4A5AE8"))
            }
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT
            ).apply { topMargin = 40 }
        }
        stopBtn.setOnClickListener {
            AlarmSoundService.stop(this)
            finish()
        }
        root.addView(stopBtn)

        setContentView(root)
    }
}
