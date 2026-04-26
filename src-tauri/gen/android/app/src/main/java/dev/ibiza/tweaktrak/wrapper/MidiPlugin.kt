package dev.ibiza.tweaktrak.wrapper

import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.media.midi.MidiDevice
import android.media.midi.MidiDeviceInfo
import android.media.midi.MidiInputPort
import android.media.midi.MidiManager
import android.media.midi.MidiOutputPort
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import app.tauri.annotation.Command
import app.tauri.annotation.InvokeArg
import app.tauri.annotation.TauriPlugin
import app.tauri.plugin.JSObject
import app.tauri.plugin.Plugin
import app.tauri.plugin.Invoke
import org.json.JSONArray
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger

@InvokeArg
class OpenPortArgs {
    var deviceId: Int = 0
    var portIndex: Int = 0
}

@InvokeArg
class SendArgs {
    var handle: Int = 0
    var data: List<Int> = emptyList()
    var timestamp: Long = 0
}

@InvokeArg
class ClosePortArgs {
    var handle: Int = 0
}

@TauriPlugin
class MidiPlugin(private val activity: android.app.Activity) : Plugin(activity) {

    companion object {
        // BLE-MIDI service UUID (MIDI over BLE, RFC 6455 MIDI 1.0)
        val BLE_MIDI_SERVICE_UUID: UUID = UUID.fromString("03B80E5A-EDE8-4B33-A751-6CE34EC4C700")
    }

    private val midiManager: MidiManager? by lazy {
        activity.getSystemService(Context.MIDI_SERVICE) as? MidiManager
    }

    private val handleCounter = AtomicInteger(1)
    private val openDevices = ConcurrentHashMap<Int, MidiDevice>()
    private val inputPorts = ConcurrentHashMap<Int, MidiInputPort>()   // app → device
    private val outputPorts = ConcurrentHashMap<Int, MidiOutputPort>() // device → app

    // ── listDevices ──────────────────────────────────────────────────────────

    @Command
    fun listDevices(invoke: Invoke) {
        val mm = midiManager ?: run { invoke.reject("MIDI service unavailable"); return }
        val infos = mm.devices
        val arr = JSONArray()
        for (info in infos) {
            val obj = JSObject()
            obj.put("id", info.id)
            obj.put("name", info.properties.getString(MidiDeviceInfo.PROPERTY_NAME) ?: "Unknown")
            obj.put("manufacturer", info.properties.getString(MidiDeviceInfo.PROPERTY_MANUFACTURER) ?: "")
            obj.put("inputPortCount", info.inputPortCount)
            obj.put("outputPortCount", info.outputPortCount)
            arr.put(obj)
        }
        val result = JSObject()
        result.put("devices", arr)
        invoke.resolve(result)
    }

    // ── openInputPort (app sends TO device — Web MIDIOutput) ─────────────────

    @Command
    fun openInputPort(invoke: Invoke) {
        val args = invoke.parseArgs(OpenPortArgs::class.java)
        val mm = midiManager ?: run { invoke.reject("MIDI service unavailable"); return }
        val info = mm.devices.firstOrNull { it.id == args.deviceId }
            ?: run { invoke.reject("Device not found: ${args.deviceId}"); return }

        mm.openDevice(info, { device ->
            if (device == null) { invoke.reject("Failed to open device"); return@openDevice }
            val port = device.openInputPort(args.portIndex)
                ?: run { device.close(); invoke.reject("Failed to open input port ${args.portIndex}"); return@openDevice }
            val handle = handleCounter.getAndIncrement()
            openDevices[handle] = device
            inputPorts[handle] = port
            val result = JSObject()
            result.put("handle", handle)
            invoke.resolve(result)
        }, Handler(Looper.getMainLooper()))
    }

    // ── openOutputPort (device sends TO app — Web MIDIInput) ─────────────────

    @Command
    fun openOutputPort(invoke: Invoke) {
        val args = invoke.parseArgs(OpenPortArgs::class.java)
        val mm = midiManager ?: run { invoke.reject("MIDI service unavailable"); return }
        val info = mm.devices.firstOrNull { it.id == args.deviceId }
            ?: run { invoke.reject("Device not found: ${args.deviceId}"); return }

        mm.openDevice(info, { device ->
            if (device == null) { invoke.reject("Failed to open device"); return@openDevice }
            val port = device.openOutputPort(args.portIndex)
                ?: run { device.close(); invoke.reject("Failed to open output port ${args.portIndex}"); return@openDevice }
            val handle = handleCounter.getAndIncrement()
            openDevices[handle] = device
            outputPorts[handle] = port

            // Forward incoming bytes to the WebView as a Tauri event
            port.connect(object : android.media.midi.MidiReceiver() {
                override fun onSend(data: ByteArray, offset: Int, count: Int, timestamp: Long) {
                    val payload = JSObject()
                    payload.put("handle", handle)
                    val byteArr = JSONArray()
                    for (i in offset until offset + count) byteArr.put(data[i].toInt() and 0xFF)
                    payload.put("data", byteArr)
                    payload.put("timestamp", timestamp)
                    trigger("midiMessage", payload)
                }
            })

            val result = JSObject()
            result.put("handle", handle)
            invoke.resolve(result)
        }, Handler(Looper.getMainLooper()))
    }

    // ── send ─────────────────────────────────────────────────────────────────

    @Command
    fun send(invoke: Invoke) {
        val args = invoke.parseArgs(SendArgs::class.java)
        val port = inputPorts[args.handle] ?: run { invoke.reject("Invalid handle ${args.handle}"); return }
        val bytes = ByteArray(args.data.size) { args.data[it].toByte() }
        port.send(bytes, 0, bytes.size, args.timestamp)
        invoke.resolve()
    }

    // ── closePort ─────────────────────────────────────────────────────────────

    @Command
    fun closePort(invoke: Invoke) {
        val args = invoke.parseArgs(ClosePortArgs::class.java)
        inputPorts.remove(args.handle)?.close()
        outputPorts.remove(args.handle)?.close()
        openDevices.remove(args.handle)?.close()
        invoke.resolve()
    }

    // ── requestBluetoothPermission ────────────────────────────────────────────

    @Command
    fun requestBluetoothPermission(invoke: Invoke) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val permission = android.Manifest.permission.BLUETOOTH_CONNECT
            val granted = androidx.core.content.ContextCompat.checkSelfPermission(
                activity, permission
            ) == android.content.pm.PackageManager.PERMISSION_GRANTED
            if (!granted) {
                androidx.core.app.ActivityCompat.requestPermissions(
                    activity, arrayOf(permission), 1001
                )
            }
            val result = JSObject()
            result.put("granted", granted)
            invoke.resolve(result)
        } else {
            val result = JSObject()
            result.put("granted", true)
            invoke.resolve(result)
        }
    }

    // ── scanBle ───────────────────────────────────────────────────────────────

    @Command
    fun scanBle(invoke: Invoke) {
        val btManager = activity.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
            ?: run { invoke.reject("Bluetooth unavailable"); return }
        val scanner = btManager.adapter?.bluetoothLeScanner
            ?: run { invoke.reject("BLE scanner unavailable"); return }

        val found = ConcurrentHashMap<String, JSObject>()
        val filter = ScanFilter.Builder()
            .setServiceUuid(ParcelUuid(BLE_MIDI_SERVICE_UUID))
            .build()
        val settings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
            .build()

        val callback = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, result: ScanResult) {
                val dev = result.device
                val obj = JSObject()
                obj.put("address", dev.address)
                obj.put("name", dev.name ?: "BLE-MIDI Device")
                obj.put("rssi", result.rssi)
                found[dev.address] = obj
            }
        }

        scanner.startScan(listOf(filter), settings, callback)

        // Stop after 5 s and return results
        Handler(Looper.getMainLooper()).postDelayed({
            scanner.stopScan(callback)
            val arr = JSONArray()
            for (obj in found.values) arr.put(obj)
            val result = JSObject()
            result.put("devices", arr)
            invoke.resolve(result)
        }, 5000)
    }
}
