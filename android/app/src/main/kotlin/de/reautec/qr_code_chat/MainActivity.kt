package de.paulporg.obmc

import android.app.Activity
import android.bluetooth.BluetoothManager
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.location.LocationManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.Uri
import android.net.wifi.WifiManager
import android.nfc.NfcAdapter
import android.os.Build
import android.os.Bundle
import android.os.storage.StorageManager
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.documentfile.provider.DocumentFile
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {

    companion object {
        private const val CHANNEL = "de.paulporg.obmc/file_intent"
        private const val STORAGE_CHANNEL = "de.paulporg.obmc/storage"
        private const val CONN_CHANNEL = "de.paulporg.obmc/connectivity_check"
        private const val USB_SAF_CHANNEL = "de.paulporg.obmc/usbsaf"
        private const val SAF_PREFS = "obmc_saf_prefs"
        private const val SAF_KEY_TREE_URI = "usb_tree_uri"
        private const val REQ_PICK_USB_TREE = 0x4711
    }

    // Hintergrund-ThreadPool für schwere SAF-I/O (listFiles, readBytes etc.)
    // Läuft NICHT auf dem Android-UI-Thread → Rendering bleibt flüssig.
    private val ioExecutor = Executors.newCachedThreadPool()
    private val mainHandler = Handler(Looper.getMainLooper())

    private var pendingFileUri: String? = null
    private var pendingSafPickResult: MethodChannel.Result? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        handleIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleIntent(intent)
        // Sofort weiterleiten falls der FlutterEngine bereits bereit ist
        flutterEngine?.dartExecutor?.binaryMessenger?.let { messenger ->
            pendingFileUri?.let { uri ->
                MethodChannel(messenger, CHANNEL).invokeMethod("onFileIntent", uri)
                pendingFileUri = null
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getPendingFileIntent" -> {
                        result.success(pendingFileUri)
                        pendingFileUri = null
                    }
                    "readContentUri" -> {
                        val uriString = call.arguments as? String
                        if (uriString == null) {
                            result.error("INVALID_ARG", "URI is null", null)
                            return@setMethodCallHandler
                        }
                        try {
                            val uri = Uri.parse(uriString)
                            val bytes = contentResolver.openInputStream(uri)?.use { it.readBytes() }
                            if (bytes != null) {
                                result.success(bytes)
                            } else {
                                result.error("READ_FAILED", "Could not open URI", null)
                            }
                        } catch (e: Exception) {
                            result.error("READ_ERROR", e.message, null)
                        }
                    }
                    "getContentUriInfo" -> {
                        val uriString = call.arguments as? String
                        if (uriString == null) {
                            result.error("INVALID_ARG", "URI is null", null)
                            return@setMethodCallHandler
                        }

                        try {
                            val uri = Uri.parse(uriString)
                            var displayName: String? = null

                            contentResolver.query(
                                uri,
                                arrayOf(OpenableColumns.DISPLAY_NAME),
                                null,
                                null,
                                null
                            )?.use { cursor ->
                                if (cursor.moveToFirst()) {
                                    val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                                    if (index >= 0) {
                                        displayName = cursor.getString(index)
                                    }
                                }
                            }

                            val mimeType = contentResolver.getType(uri)
                            result.success(
                                mapOf(
                                    "displayName" to displayName,
                                    "mimeType" to mimeType
                                )
                            )
                        } catch (e: Exception) {
                            result.error("URI_INFO_ERROR", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, STORAGE_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getStorageVolumes" -> {
                        try {
                            val sm = getSystemService(Context.STORAGE_SERVICE) as StorageManager
                            val volumes = sm.storageVolumes
                            val paths = mutableListOf<String>()
                            for (vol in volumes) {
                                // getDirectory() ab API 30, davor Reflection nötig
                                try {
                                    val dirMethod = vol.javaClass.getMethod("getDirectory")
                                    val dir = dirMethod.invoke(vol) as? java.io.File
                                    if (dir != null) {
                                        paths.add(dir.absolutePath)
                                    }
                                } catch (_: Exception) {
                                    // getDirectory nicht verfügbar (API < 30) → Reflection auf path
                                    try {
                                        val pathField = vol.javaClass.getDeclaredField("mPath")
                                        pathField.isAccessible = true
                                        val p = pathField.get(vol) as? String
                                        if (p != null) paths.add(p)
                                    } catch (_: Exception) {}
                                }
                            }
                            result.success(paths)
                        } catch (e: Exception) {
                            result.error("STORAGE_ERROR", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        // ── Verbindungscheck für Offline-Gerät-Sicherheitsprüfung ────────────
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CONN_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "checkDataConnections" -> {
                        try {
                            val connections = mutableMapOf<String, Boolean>()

                            // WiFi
                            val wifiManager = applicationContext
                                .getSystemService(Context.WIFI_SERVICE) as? WifiManager
                            connections["wifi"] = wifiManager?.isWifiEnabled ?: false

                            // Mobile Daten (aktive Verbindung via Mobilfunk)
                            val cm = getSystemService(Context.CONNECTIVITY_SERVICE)
                                    as? ConnectivityManager
                            val mobileActive: Boolean = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                                val net = cm?.activeNetwork
                                val caps = cm?.getNetworkCapabilities(net)
                                caps?.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) ?: false
                            } else {
                                @Suppress("DEPRECATION")
                                cm?.getNetworkInfo(ConnectivityManager.TYPE_MOBILE)?.isConnected ?: false
                            }
                            connections["mobile_data"] = mobileActive

                            // Bluetooth
                            val btEnabled: Boolean = try {
                                val btManager = getSystemService(Context.BLUETOOTH_SERVICE)
                                        as? BluetoothManager
                                btManager?.adapter?.isEnabled ?: false
                            } catch (_: SecurityException) { false }
                            connections["bluetooth"] = btEnabled

                            // GPS / Standort
                            val lm = getSystemService(Context.LOCATION_SERVICE) as? LocationManager
                            val gpsEnabled: Boolean = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                                lm?.isLocationEnabled ?: false
                            } else {
                                @Suppress("DEPRECATION")
                                (lm?.isProviderEnabled(LocationManager.GPS_PROVIDER) ?: false) ||
                                (lm?.isProviderEnabled(LocationManager.NETWORK_PROVIDER) ?: false)
                            }
                            connections["gps"] = gpsEnabled

                            // NFC
                            val nfc = try {
                                NfcAdapter.getDefaultAdapter(this)?.isEnabled ?: false
                            } catch (_: Exception) { false }
                            connections["nfc"] = nfc

                            result.success(connections)
                        } catch (e: Exception) {
                            result.error("CHECK_ERROR", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        // ── USB-SAF (Storage Access Framework) ──────────────────────────────
        // Erlaubt den persistenten Zugriff auf USB-OTG-Volumes über
        // ACTION_OPEN_DOCUMENT_TREE. Die gewählte Tree-Uri wird in
        // SharedPreferences gespeichert, die Lese-/Schreibrechte über
        // takePersistableUriPermission langfristig gesichert.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, USB_SAF_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "pickUsbTreeUri" -> {
                        if (pendingSafPickResult != null) {
                            result.error("BUSY", "USB-Auswahl läuft bereits", null)
                            return@setMethodCallHandler
                        }
                        try {
                            val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                                addFlags(
                                    Intent.FLAG_GRANT_READ_URI_PERMISSION or
                                            Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                                            Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION
                                )
                            }
                            pendingSafPickResult = result
                            startActivityForResult(intent, REQ_PICK_USB_TREE)
                        } catch (e: Exception) {
                            pendingSafPickResult = null
                            result.error("PICK_ERROR", e.message, null)
                        }
                    }
                    "getPersistedUsbTreeUri" -> {
                        result.success(safPrefs().getString(SAF_KEY_TREE_URI, null))
                    }
                    "registerTreeUri" -> {
                        // Speichert eine von außen (z.B. FilePicker) erhaltene Tree-Uri
                        // und sichert persistable Zugriffsrechte.
                        val uriStr = call.arguments as? String
                            ?: return@setMethodCallHandler result.error(
                                "INVALID_ARG", "URI is null", null
                            )
                        try {
                            val uri = Uri.parse(uriStr)
                            val flags = Intent.FLAG_GRANT_READ_URI_PERMISSION or
                                    Intent.FLAG_GRANT_WRITE_URI_PERMISSION
                            try {
                                contentResolver.takePersistableUriPermission(uri, flags)
                            } catch (e: SecurityException) {
                                Log.w("OBMC_SAF",
                                    "takePersistableUriPermission fehlgeschlagen: ${e.message}")
                            }
                            safPrefs().edit().putString(SAF_KEY_TREE_URI, uriStr).apply()
                            result.success(uriStr)
                        } catch (e: Exception) {
                            result.error("REGISTER_ERROR", e.message, null)
                        }
                    }
                    "clearUsbTreeUri" -> {
                        val uriStr = safPrefs().getString(SAF_KEY_TREE_URI, null)
                        if (uriStr != null) {
                            try {
                                contentResolver.releasePersistableUriPermission(
                                    Uri.parse(uriStr),
                                    Intent.FLAG_GRANT_READ_URI_PERMISSION or
                                            Intent.FLAG_GRANT_WRITE_URI_PERMISSION
                                )
                            } catch (_: Exception) {}
                        }
                        safPrefs().edit().remove(SAF_KEY_TREE_URI).apply()
                        result.success(true)
                    }
                    "listSubDirs" -> {
                        // Listet alle Unterordner im angegebenen subPath (oder Root).
                        // Wird vom Dart-Ordner-Browser verwendet – kein FilePicker nötig.
                        val args = call.arguments as? Map<*, *>
                        val subPath = args?.get("subPath") as? String
                        ioExecutor.execute {
                            try {
                                val treeUriStr = safPrefs().getString(SAF_KEY_TREE_URI, null)
                                if (treeUriStr == null) {
                                    mainHandler.post { result.error("NO_TREE", "USB-Stick nicht gekoppelt", null) }
                                    return@execute
                                }
                                val root = DocumentFile.fromTreeUri(this@MainActivity, Uri.parse(treeUriStr))
                                if (root == null) {
                                    mainHandler.post { result.error("INVALID_TREE", "Tree-Uri ungültig", null) }
                                    return@execute
                                }
                                if (!root.canRead()) {
                                    mainHandler.post { result.error("NO_ACCESS", "Zugriff auf USB-Stick verweigert – bitte erneut koppeln", null) }
                                    return@execute
                                }
                                val dir = if (subPath.isNullOrBlank()) root
                                else resolveSubDir(root, subPath, create = false)
                                if (dir == null || !dir.isDirectory) {
                                    mainHandler.post { result.success(emptyList<String>()) }
                                    return@execute
                                }
                                val dirs = dir.listFiles()
                                    .filter { it.isDirectory }
                                    .mapNotNull { it.name }
                                    .sorted()
                                mainHandler.post { result.success(dirs) }
                            } catch (e: Exception) {
                                mainHandler.post { result.error("LIST_ERROR", e.message, null) }
                            }
                        }
                    }
                    "listUsbDir" -> {
                        // args: { subPath: String?, suffix: String? }
                        val args = call.arguments as? Map<*, *>
                        val subPath = args?.get("subPath") as? String
                        val suffix = (args?.get("suffix") as? String)?.lowercase()
                        ioExecutor.execute {
                            try {
                                val treeUriStr = safPrefs().getString(SAF_KEY_TREE_URI, null)
                                if (treeUriStr == null) {
                                    mainHandler.post { result.error("NO_TREE", "USB-Stick wurde noch nicht gekoppelt", null) }
                                    return@execute
                                }
                                val root = DocumentFile.fromTreeUri(this@MainActivity, Uri.parse(treeUriStr))
                                if (root == null) {
                                    mainHandler.post { result.error("NO_TREE", "Tree-Uri ungültig", null) }
                                    return@execute
                                }
                                if (!root.canRead()) {
                                    mainHandler.post { result.error("NO_ACCESS", "Zugriff auf USB-Stick verweigert – bitte erneut koppeln", null) }
                                    return@execute
                                }
                                val dir = if (subPath.isNullOrBlank()) root
                                else resolveSubDir(root, subPath, create = false)
                                if (dir == null || !dir.isDirectory) {
                                    mainHandler.post { result.success(emptyList<Map<String, Any?>>()) }
                                    return@execute
                                }
                                val list = mutableListOf<Map<String, Any?>>()
                                for (f in dir.listFiles()) {
                                    if (!f.isFile) continue
                                    val name = f.name ?: continue
                                    if (suffix != null && !name.lowercase().endsWith(suffix)) continue
                                    list.add(
                                        mapOf(
                                            "name" to name,
                                            "uri" to f.uri.toString(),
                                            "size" to f.length(),
                                            "lastModified" to f.lastModified()
                                        )
                                    )
                                }
                                mainHandler.post { result.success(list) }
                            } catch (e: Exception) {
                                mainHandler.post { result.error("LIST_ERROR", e.message, null) }
                            }
                        }
                    }
                    "readUsbFile" -> {
                        val uriStr = call.arguments as? String
                            ?: return@setMethodCallHandler result.error(
                                "INVALID_ARG", "URI is null", null
                            )
                        ioExecutor.execute {
                            try {
                                val bytes = contentResolver.openInputStream(Uri.parse(uriStr))
                                    ?.use { it.readBytes() }
                                if (bytes != null) mainHandler.post { result.success(bytes) }
                                else mainHandler.post { result.error("READ_FAILED", "Could not open URI", null) }
                            } catch (e: Exception) {
                                mainHandler.post { result.error("READ_ERROR", e.message, null) }
                            }
                        }
                    }
                    "writeUsbFile" -> {
                        // args: { subPath, fileName, bytes, mime }
                        val args = call.arguments as? Map<*, *>
                            ?: return@setMethodCallHandler result.error(
                                "INVALID_ARG", "Arguments missing", null
                            )
                        val subPath = args["subPath"] as? String
                        val fileName = args["fileName"] as? String
                            ?: return@setMethodCallHandler result.error(
                                "INVALID_ARG", "fileName missing", null
                            )
                        val bytes = args["bytes"] as? ByteArray
                            ?: return@setMethodCallHandler result.error(
                                "INVALID_ARG", "bytes missing", null
                            )
                        val mime = (args["mime"] as? String) ?: "application/octet-stream"
                        ioExecutor.execute {
                            try {
                                val treeUriStr = safPrefs().getString(SAF_KEY_TREE_URI, null)
                                if (treeUriStr == null) {
                                    mainHandler.post { result.error("NO_TREE", "USB-Stick wurde noch nicht gekoppelt", null) }
                                    return@execute
                                }
                                val root = DocumentFile.fromTreeUri(this@MainActivity, Uri.parse(treeUriStr))
                                if (root == null) {
                                    mainHandler.post { result.error("NO_TREE", "Tree-Uri ungültig", null) }
                                    return@execute
                                }
                                val dir = if (subPath.isNullOrBlank()) root
                                else resolveSubDir(root, subPath, create = true)
                                if (dir == null) {
                                    mainHandler.post { result.error("MKDIR_FAILED", "Unterverzeichnis konnte nicht angelegt werden: $subPath", null) }
                                    return@execute
                                }
                                // Existierende Datei mit gleichem Namen löschen
                                dir.findFile(fileName)?.delete()
                                val newFile = dir.createFile(mime, fileName)
                                if (newFile == null) {
                                    mainHandler.post { result.error("CREATE_FAILED", "Datei konnte nicht angelegt werden: $fileName", null) }
                                    return@execute
                                }
                                val written = contentResolver.openOutputStream(newFile.uri, "w")?.use { out ->
                                    out.write(bytes)
                                    out.flush()
                                    true
                                } ?: false
                                if (!written) {
                                    mainHandler.post { result.error("WRITE_FAILED", "OutputStream null", null) }
                                    return@execute
                                }
                                mainHandler.post {
                                    result.success(
                                        mapOf(
                                            "uri" to newFile.uri.toString(),
                                            "name" to (newFile.name ?: fileName),
                                            "size" to newFile.length()
                                        )
                                    )
                                }
                            } catch (e: Exception) {
                                mainHandler.post { result.error("WRITE_ERROR", e.message, null) }
                            }
                        }
                    }
                    "deleteUsbFile" -> {
                        val uriStr = call.arguments as? String
                            ?: return@setMethodCallHandler result.error(
                                "INVALID_ARG", "URI is null", null
                            )
                        ioExecutor.execute {
                            try {
                                val ok = DocumentsContract.deleteDocument(
                                    contentResolver, Uri.parse(uriStr)
                                )
                                mainHandler.post { result.success(ok) }
                            } catch (e: Exception) {
                                mainHandler.post { result.error("DELETE_ERROR", e.message, null) }
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun safPrefs(): SharedPreferences =
        getSharedPreferences(SAF_PREFS, Context.MODE_PRIVATE)

    /**
     * Sucht (oder legt an) das Unterverzeichnis `subPath` (z. B. "Daten/obmc/schluessel")
     * unterhalb des angegebenen DocumentFile-Roots.
     */
    private fun resolveSubDir(root: DocumentFile, subPath: String, create: Boolean): DocumentFile? {
        var current: DocumentFile = root
        for (segment in subPath.split('/').filter { it.isNotBlank() }) {
            val existing = current.findFile(segment)
            current = when {
                existing != null && existing.isDirectory -> existing
                create -> current.createDirectory(segment) ?: return null
                else -> return null
            }
        }
        return current
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == REQ_PICK_USB_TREE) {
            val resultCallback = pendingSafPickResult
            pendingSafPickResult = null
            if (resultCallback == null) {
                super.onActivityResult(requestCode, resultCode, data)
                return
            }
            if (resultCode == Activity.RESULT_OK) {
                val uri = data?.data
                if (uri == null) {
                    resultCallback.error("NO_URI", "Kein URI vom Picker erhalten", null)
                    return
                }
                try {
                    // Nur READ-Berechtigung persistieren (WRITE ist optional und kann fehlen)
                    val grantFlags = data.flags and (
                        Intent.FLAG_GRANT_READ_URI_PERMISSION or
                                Intent.FLAG_GRANT_WRITE_URI_PERMISSION
                    )
                    val readFlag = Intent.FLAG_GRANT_READ_URI_PERMISSION
                    // Mindestens READ muss vorhanden sein
                    val flagsToTake = if (grantFlags and readFlag != 0) grantFlags else readFlag
                    contentResolver.takePersistableUriPermission(uri, flagsToTake)
                    safPrefs().edit().putString(SAF_KEY_TREE_URI, uri.toString()).apply()
                    resultCallback.success(uri.toString())
                } catch (e: Exception) {
                    resultCallback.error("PERSIST_ERROR", e.message, null)
                }
            } else {
                resultCallback.success(null)
            }
            return
        }
        super.onActivityResult(requestCode, resultCode, data)
    }

    private fun handleIntent(intent: Intent?) {
        if (intent == null) {
            Log.d("OBMC_INTENT", "handleIntent: intent is null")
            return
        }
        val action = intent.action
        Log.d("OBMC_INTENT", "handleIntent: action=$action type=${intent.type} data=${intent.data} package=${intent.`package`} component=${intent.component}")

        // ClipData loggen (z.B. WhatsApp übergibt URI manchmal via ClipData)
        val clip = intent.clipData
        if (clip != null) {
            for (i in 0 until clip.itemCount) {
                Log.d("OBMC_INTENT", "  ClipData[$i]: uri=${clip.getItemAt(i).uri} text=${clip.getItemAt(i).text}")
            }
        } else {
            Log.d("OBMC_INTENT", "  ClipData: null")
        }

        // Alle Extras loggen
        intent.extras?.keySet()?.forEach { key ->
            Log.d("OBMC_INTENT", "  Extra[$key]: ${intent.extras?.get(key)}")
        } ?: Log.d("OBMC_INTENT", "  Extras: null")

        if (action == null) {
            Log.d("OBMC_INTENT", "handleIntent: action is null, ignoriere")
            return
        }

        val intentMimeType = intent.type ?: ""

        when (action) {
            Intent.ACTION_VIEW -> {
                val uri: Uri? = intent.data
                Log.d("OBMC_INTENT", "ACTION_VIEW: uri=$uri")
                if (uri != null) {
                    pendingFileUri = buildPendingInfo(uri, intentMimeType)
                    Log.d("OBMC_INTENT", "pendingFileUri gesetzt: $pendingFileUri")
                } else {
                    Log.d("OBMC_INTENT", "ACTION_VIEW: data URI ist null")
                }
            }
            Intent.ACTION_SEND -> {
                val uri: Uri? = intent.getParcelableExtra(Intent.EXTRA_STREAM)
                Log.d("OBMC_INTENT", "ACTION_SEND: EXTRA_STREAM uri=$uri")
                // Fallback: prüfe ClipData falls EXTRA_STREAM null
                val resolvedUri = uri ?: clip?.getItemAt(0)?.uri
                if (resolvedUri != null) {
                    pendingFileUri = buildPendingInfo(resolvedUri, intentMimeType)
                    Log.d("OBMC_INTENT", "pendingFileUri gesetzt (ACTION_SEND): $pendingFileUri")
                } else {
                    Log.d("OBMC_INTENT", "ACTION_SEND: kein URI gefunden (weder EXTRA_STREAM noch ClipData)")
                }
            }
            else -> {
                Log.d("OBMC_INTENT", "handleIntent: unbekannte Action '$action', ignoriere")
            }
        }
    }

    /**
     * Liest die URI sofort (solange die Berechtigung aktiv ist), cached die Bytes in einer
     * Temp-Datei und gibt einen \u001F-getrennten String zurück:
     *   tempFilePath\u001FdisplayName\u001FintentMimeType\u001ForiginalUri
     */
    private fun buildPendingInfo(uri: Uri, intentMimeType: String): String {
        // displayName aus ContentResolver holen
        var displayName = ""
        try {
            contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
                ?.use { cursor ->
                    if (cursor.moveToFirst()) {
                        val idx = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                        if (idx >= 0) displayName = cursor.getString(idx) ?: ""
                    }
                }
        } catch (e: Exception) {
            Log.w("OBMC_INTENT", "displayName query failed: ${e.message}")
        }
        Log.d("OBMC_INTENT", "buildPendingInfo: displayName='$displayName' intentMime='$intentMimeType'")

        // Bytes sofort lesen und cachen (während die Uri-Berechtigung garantiert aktiv ist)
        val tempPath = cacheUriContent(uri)

        // Format: tempPath|displayName|intentMimeType|originalUri  (Trennzeichen \u001F)
        val localRef = tempPath ?: uri.toString()
        return "${localRef}\u001F${displayName}\u001F${intentMimeType}\u001F${uri}"
    }

    /** Liest die URI-Bytes und speichert sie in einer Temp-Datei im App-Cache. */
    private fun cacheUriContent(uri: Uri): String? {
        return try {
            val bytes = contentResolver.openInputStream(uri)?.use { it.readBytes() }
            if (bytes == null || bytes.isEmpty()) {
                Log.w("OBMC_INTENT", "cacheUriContent: keine Bytes für $uri")
                return null
            }
            val tempFile = java.io.File(cacheDir, "obmc_import_${System.currentTimeMillis()}.tmp")
            tempFile.writeBytes(bytes)
            Log.d("OBMC_INTENT", "cacheUriContent: ${bytes.size} Bytes nach ${tempFile.absolutePath} gecacht")
            tempFile.absolutePath
        } catch (e: Exception) {
            Log.e("OBMC_INTENT", "cacheUriContent fehlgeschlagen: ${e.message}")
            null
        }
    }
}
