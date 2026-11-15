package com.harolre.mishoras

import android.app.Activity
import android.content.Intent
import android.net.Uri
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream

class MainActivity : FlutterActivity() {
    private var backupChannel: MethodChannel? = null
    private var pendingSaveResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        backupChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.harolre.mishoras/backup"
        )
        backupChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "createBackupDestination" -> {
                    val fileName = call.argument<String>("fileName")
                    if (fileName.isNullOrBlank()) {
                        result.error("INVALID_ARGUMENT", "Falta el nombre del archivo.", null)
                    } else if (pendingSaveResult != null) {
                        result.error("SAVE_IN_PROGRESS", "Ya hay un selector abierto.", null)
                    } else {
                        pendingSaveResult = result
                        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE)
                            type = "application/octet-stream"
                            putExtra(Intent.EXTRA_TITLE, fileName)
                        }
                        try {
                            startActivityForResult(intent, REQUEST_CREATE_BACKUP)
                        } catch (error: Exception) {
                            pendingSaveResult = null
                            result.error("SAVE_PICKER_FAILED", error.message, null)
                        }
                    }
                }
                "copyFileToUri" -> {
                    val sourcePath = call.argument<String>("sourcePath")
                    val destinationUri = call.argument<String>("destinationUri")
                    if (sourcePath == null || destinationUri == null) {
                        result.error("INVALID_ARGUMENT", "Falta la ruta de la copia.", null)
                    } else {
                        try {
                            val uri = Uri.parse(destinationUri)
                            val output = contentResolver.openOutputStream(uri, "wt")
                                ?: throw IllegalStateException("No se pudo abrir el destino.")
                            output.use { destination ->
                                FileInputStream(File(sourcePath)).use { source ->
                                    val buffer = ByteArray(128 * 1024)
                                    while (true) {
                                        val count = source.read(buffer)
                                        if (count < 0) break
                                        destination.write(buffer, 0, count)
                                    }
                                    destination.flush()
                                }
                            }
                            result.success(null)
                        } catch (error: Exception) {
                            result.error("BACKUP_WRITE_FAILED", error.message, null)
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    @Deprecated("Deprecated in Android")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQUEST_CREATE_BACKUP) return
        val result = pendingSaveResult ?: return
        pendingSaveResult = null
        if (resultCode == Activity.RESULT_OK && data?.data != null) {
            result.success(data.data.toString())
        } else {
            result.success(null)
        }
    }

    companion object {
        private const val REQUEST_CREATE_BACKUP = 7204
    }
}
