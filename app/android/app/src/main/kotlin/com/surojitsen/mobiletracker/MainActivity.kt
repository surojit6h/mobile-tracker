package com.surojitsen.mobiletracker

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.telephony.SubscriptionManager
import android.telephony.TelephonyManager
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity: FlutterActivity() {
    private val CHANNEL = "com.surojitsen.mobiletracker/sim"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "getSim1Number") {
                val number = getSim1PhoneNumber()
                result.success(number)
            } else {
                result.notImplemented()
            }
        }
    }

    private fun getSim1PhoneNumber(): String? {
        try {
            val hasPhoneNumbers = ContextCompat.checkSelfPermission(this, Manifest.permission.READ_PHONE_NUMBERS) == PackageManager.PERMISSION_GRANTED
            val hasPhoneState = ContextCompat.checkSelfPermission(this, Manifest.permission.READ_PHONE_STATE) == PackageManager.PERMISSION_GRANTED
            if (!hasPhoneNumbers && !hasPhoneState) {
                return null
            }

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP_MR1) {
                val subManager = getSystemService(Context.TELEPHONY_SUBSCRIPTION_SERVICE) as? SubscriptionManager
                if (subManager != null) {
                    val activeList = subManager.activeSubscriptionInfoList
                    if (!activeList.isNullOrEmpty()) {
                        // Find SIM slot index 0 (SIM 1)
                        val sim1 = activeList.firstOrNull { it.simSlotIndex == 0 } ?: activeList[0]

                        // On Android 13+ (API 33+), SubscriptionManager has getPhoneNumber(subId)
                        if (Build.VERSION.SDK_INT >= 33) {
                            try {
                                val num = subManager.getPhoneNumber(sim1.subscriptionId)
                                if (!num.isNullOrBlank()) return num.trim()
                            } catch (_: Exception) {}
                        }

                        val num = sim1.number
                        if (!num.isNullOrBlank()) {
                            return num.trim()
                        }
                    }
                }
            }

            // Fallback for older Android or single-SIM devices
            val telephonyManager = getSystemService(Context.TELEPHONY_SERVICE) as? TelephonyManager
            val legacyNum = telephonyManager?.line1Number
            if (!legacyNum.isNullOrBlank()) {
                return legacyNum.trim()
            }
        } catch (_: Exception) {}

        return null
    }
}
