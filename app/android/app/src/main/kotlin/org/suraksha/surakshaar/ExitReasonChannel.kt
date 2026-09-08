package org.suraksha.surakshaar

import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.Context
import android.os.Build
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Reports why previous instances of this process died.
 *
 * Android has recorded this since API 30 via
 * [ActivityManager.getHistoricalProcessExitReasons], and it is the ground truth
 * that breadcrumbs can only approximate. A Dart breadcrumb trail stops at the
 * last thing the *Dart* isolate did; if the process is killed by the kernel for
 * memory, by a native SIGSEGV on the raster thread, or by the ANR watchdog, the
 * trail simply ends and every explanation for why looks equally plausible.
 *
 * This says which it actually was — and for a native crash or an ANR, hands
 * back the tombstone, including the fatal signal and the faulting library.
 *
 * Needs no USB cable, no debugger and no developer options, which is the whole
 * point: the devices that matter here are workers' own handsets in districts
 * with nobody around to attach a laptop.
 */
class ExitReasonChannel(
    private val context: Context,
) : MethodChannel.MethodCallHandler {

    companion object {
        private const val CHANNEL = "org.suraksha.surakshaar/exit_reasons"

        /** A handful of recent deaths is plenty; older ones are noise. */
        private const val MAX_RECORDS = 6

        /** Tombstones can be large. This is enough to reach the signal and the
         *  top native frames without dragging megabytes through the channel. */
        private const val MAX_TRACE_BYTES = 128 * 1024

        private const val MIN_PRINTABLE_RUN = 6
        private const val MAX_TRACE_LINES = 160
    }

    private var channel: MethodChannel? = null

    fun attach(messenger: BinaryMessenger) {
        channel = MethodChannel(messenger, CHANNEL).also { it.setMethodCallHandler(this) }
    }

    fun detach() {
        channel?.setMethodCallHandler(null)
        channel = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "lastExits" -> result.success(lastExits())
            else -> result.notImplemented()
        }
    }

    private fun lastExits(): List<Map<String, Any?>> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return emptyList()

        val manager = context.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
            ?: return emptyList()

        val records = try {
            manager.getHistoricalProcessExitReasons(context.packageName, 0, MAX_RECORDS)
        } catch (e: Exception) {
            return listOf(mapOf("error" to e.toString()))
        }

        return records.map { info ->
            mapOf(
                "reason" to reasonName(info.reason),
                "reasonCode" to info.reason,
                "description" to info.description,
                "status" to info.status,
                "importance" to info.importance,
                // Memory at the moment of death, in kB. Decides OOM outright.
                "pssKb" to info.pss,
                "rssKb" to info.rss,
                "timestampMs" to info.timestamp,
                "trace" to readTrace(info),
            )
        }
    }

    /** Human-readable exit reason. The numeric code alone tells the reader nothing. */
    private fun reasonName(reason: Int): String = when (reason) {
        ApplicationExitInfo.REASON_UNKNOWN -> "UNKNOWN"
        ApplicationExitInfo.REASON_EXIT_SELF -> "EXIT_SELF"
        ApplicationExitInfo.REASON_SIGNALED -> "SIGNALED"
        ApplicationExitInfo.REASON_LOW_MEMORY -> "LOW_MEMORY"
        ApplicationExitInfo.REASON_CRASH -> "CRASH (Java/Kotlin exception)"
        ApplicationExitInfo.REASON_CRASH_NATIVE -> "CRASH_NATIVE (native signal)"
        ApplicationExitInfo.REASON_ANR -> "ANR (unresponsive)"
        ApplicationExitInfo.REASON_INITIALIZATION_FAILURE -> "INITIALIZATION_FAILURE"
        ApplicationExitInfo.REASON_PERMISSION_CHANGE -> "PERMISSION_CHANGE"
        ApplicationExitInfo.REASON_EXCESSIVE_RESOURCE_USAGE -> "EXCESSIVE_RESOURCE_USAGE"
        ApplicationExitInfo.REASON_USER_REQUESTED -> "USER_REQUESTED"
        ApplicationExitInfo.REASON_USER_STOPPED -> "USER_STOPPED"
        ApplicationExitInfo.REASON_DEPENDENCY_DIED -> "DEPENDENCY_DIED"
        ApplicationExitInfo.REASON_OTHER -> "OTHER"
        else -> "code $reason"
    }

    /**
     * The ANR trace or native tombstone, if one was kept.
     *
     * An ANR trace is plain text; an API 30+ tombstone is a protobuf. Rather
     * than link a protobuf runtime to read one field, printable strings are
     * pulled out of the bytes — which surfaces the signal name, the abort
     * message and the shared-object paths, and those are the parts that
     * identify the fault.
     */
    private fun readTrace(info: ApplicationExitInfo): String? {
        return try {
            info.traceInputStream?.use { stream ->
                val buffer = ByteArray(MAX_TRACE_BYTES)
                var read = 0
                while (read < MAX_TRACE_BYTES) {
                    val n = stream.read(buffer, read, MAX_TRACE_BYTES - read)
                    if (n <= 0) break
                    read += n
                }
                if (read <= 0) null else extractPrintable(buffer, read)
            }
        } catch (e: Exception) {
            "trace unavailable: ${e.message}"
        }
    }

    private fun extractPrintable(bytes: ByteArray, length: Int): String {
        val lines = ArrayList<String>()
        val current = StringBuilder()

        for (i in 0 until length) {
            val c = bytes[i].toInt() and 0xFF
            val printable = c in 0x20..0x7E
            if (printable) {
                current.append(c.toChar())
            } else {
                if (current.length >= MIN_PRINTABLE_RUN) lines.add(current.toString())
                current.setLength(0)
                if (lines.size >= MAX_TRACE_LINES) break
            }
        }
        if (current.length >= MIN_PRINTABLE_RUN && lines.size < MAX_TRACE_LINES) {
            lines.add(current.toString())
        }

        return lines.joinToString("\n")
    }
}
