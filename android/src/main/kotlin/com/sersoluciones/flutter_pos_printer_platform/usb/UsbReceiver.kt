package com.sersoluciones.flutter_pos_printer_platform.usb

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbManager
import android.os.Build
import android.util.Log

class UsbReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context?, intent: Intent?) {
        Log.d("UsbReceiver", "Inside USB Broadcast action ${intent!!.action}")

        val action = intent.action
        if (UsbManager.ACTION_USB_DEVICE_ATTACHED == action) {

            val usbDevice: UsbDevice? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                intent.getParcelableExtra(UsbManager.EXTRA_DEVICE, UsbDevice::class.java)
            } else {
                intent.getParcelableExtra(UsbManager.EXTRA_DEVICE)
            }

            val mPermissionIndent = PendingIntent.getBroadcast(context, 0, Intent("com.flutter_pos_printer.USB_PERMISSION"), PendingIntent.FLAG_IMMUTABLE)
            val mUSBManager = context?.getSystemService(Context.USB_SERVICE) as UsbManager?
            mUSBManager?.requestPermission(usbDevice, mPermissionIndent)

        }
    }
}