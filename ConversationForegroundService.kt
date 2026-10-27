package com.device_tools.conversation_awareness

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.os.Binder
import android.os.IBinder

/**
 * Foreground service that keeps audio monitoring alive in the background.
 *
 * When the user taps Stop in the notification, the service broadcasts
 * ACTION_STOP_MONITORING so the plugin can cleanly stop AudioRecord,
 * restore volume, and notify Flutter to update the UI — then the service
 * stops itself.
 */
class ConversationForegroundService : Service() {

    companion object {
        const val ACTION_START = "com.example.conversation_awareness.START"
        const val ACTION_STOP  = "com.example.conversation_awareness.STOP"

        // Broadcast the plugin listens for when Stop is tapped in the notification.
        const val ACTION_STOP_MONITORING =
            "com.example.conversation_awareness.STOP_MONITORING"

        private const val NOTIFICATION_ID  = 1001
        private const val CHANNEL_ID       = "conversation_awareness_channel"
        private const val CHANNEL_NAME     = "Conversation Awareness"
    }

    inner class LocalBinder : Binder() {
        fun getService(): ConversationForegroundService = this@ConversationForegroundService
    }

    private val binder = LocalBinder()

    override fun onBind(intent: Intent?): IBinder = binder

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> startForeground(NOTIFICATION_ID, buildNotification())
            ACTION_STOP  -> {
                // Broadcast to the plugin so it can stop monitoring and
                // notify Flutter before the service dies.
                sendBroadcast(Intent(ACTION_STOP_MONITORING).apply {
                    setPackage(packageName)
                })
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
            }
        }
        return START_STICKY
    }

    override fun onDestroy() {
        super.onDestroy()
        stopForeground(STOP_FOREGROUND_REMOVE)
    }

    // ── Notification ──────────────────────────────────────────────────────────

    private fun buildNotification(): Notification {
        createNotificationChannel()

        val openIntent = packageManager
            .getLaunchIntentForPackage(packageName)
            ?.apply { flags = Intent.FLAG_ACTIVITY_SINGLE_TOP }

        val pendingOpen = PendingIntent.getActivity(
            this, 0, openIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val stopIntent = Intent(this, ConversationForegroundService::class.java)
            .apply { action = ACTION_STOP }
        val pendingStop = PendingIntent.getService(
            this, 1, stopIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        return Notification.Builder(this, CHANNEL_ID)
            .setContentTitle("Conversation Awareness")
            .setContentText("Listening in background — tap to open")
            .setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .setContentIntent(pendingOpen)
            .setOngoing(true)
            .addAction(
                Notification.Action.Builder(null, "Stop", pendingStop).build()
            )
            .build()
    }

    private fun createNotificationChannel() {
        val manager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            CHANNEL_ID, CHANNEL_NAME, NotificationManager.IMPORTANCE_LOW
        ).apply {
            description =
                "Shows while Conversation Awareness is running in the background"
            setShowBadge(false)
        }
        manager.createNotificationChannel(channel)
    }
}