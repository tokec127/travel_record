package com.zensoultion.travel_record

import android.Manifest
import android.content.ContentValues
import android.content.Intent
import android.database.Cursor
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.provider.OpenableColumns
import java.io.File
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterFragmentActivity() {
    private var filePickerResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "travel_record/permissions")
            .setMethodCallHandler { call, result ->
                if (call.method != "requestNotifications") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1001)
                }
                result.success(null)
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "travel_record/files")
            .setMethodCallHandler { call, result ->
                if (call.method == "openFile") {
                    val uriValue = call.argument<String>("uri")
                    if (uriValue == null) {
                        result.error("INVALID_URI", "열 파일 URI가 없습니다.", null)
                        return@setMethodCallHandler
                    }
                    try {
                        val uri = android.net.Uri.parse(uriValue)
                        startActivity(Intent(Intent.ACTION_VIEW).apply {
                            setDataAndType(uri, contentResolver.getType(uri) ?: "*/*")
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        })
                        result.success(null)
                    } catch (_: android.content.ActivityNotFoundException) {
                        result.error("NO_VIEWER", "파일을 열 수 있는 앱이 없습니다.", null)
                    }
                    return@setMethodCallHandler
                }
                if (call.method == "shareTripZip") {
                    shareTripZip(call, result)
                    return@setMethodCallHandler
                }
                if (call.method != "pickFile") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val allowMultiple = call.argument<Boolean>("allowMultiple") == true
                if (filePickerResult != null) {
                    result.error("PICKER_BUSY", "파일 선택창이 이미 열려 있습니다.", null)
                    return@setMethodCallHandler
                }
                filePickerResult = result
                startActivityForResult(
                    Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        type = "*/*"
                        putExtra(Intent.EXTRA_ALLOW_MULTIPLE, allowMultiple)
                    },
                    FILE_PICKER_REQUEST_CODE,
                )
            }
    }

    private fun shareTripZip(call: MethodCall, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            result.error("UNSUPPORTED", "Android 10 이상에서만 다운로드 공유를 지원합니다.", null)
            return
        }
        val fileName = call.argument<String>("fileName") ?: "여행기록.zip"
        val metadata = call.argument<String>("metadata") ?: "{}"
        val files = call.argument<List<Any>>("files") ?: emptyList()
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, fileName)
            put(MediaStore.MediaColumns.MIME_TYPE, "application/zip")
            put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS)
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        val uri = contentResolver.insert(
            MediaStore.Downloads.EXTERNAL_CONTENT_URI,
            values,
        )
        if (uri == null) {
            result.error("CREATE_FAILED", "ZIP 파일을 만들 수 없습니다.", null)
            return
        }
        try {
            contentResolver.openOutputStream(uri)?.use { output ->
                ZipOutputStream(output).use { zip ->
                    zip.putNextEntry(ZipEntry("metadata.json"))
                    zip.write(metadata.toByteArray(Charsets.UTF_8))
                    zip.closeEntry()
                    val names = mutableSetOf<String>()
                    for (item in files) {
                        val file = item as? Map<*, *> ?: continue
                        val source = file["source"] as? String ?: continue
                        val name = safeEntryName(file["name"] as? String ?: "file")
                        val entryName = uniqueEntryName(names, name)
                        val input = openSource(source) ?: continue
                        input.use {
                            zip.putNextEntry(ZipEntry(entryName))
                            it.copyTo(zip)
                            zip.closeEntry()
                        }
                    }
                }
            } ?: throw IllegalStateException("출력 스트림을 열 수 없습니다.")
            contentResolver.update(
                uri,
                ContentValues().apply {
                    put(MediaStore.MediaColumns.IS_PENDING, 0)
                },
                null,
                null,
            )
            val share = Intent(Intent.ACTION_SEND).apply {
                type = "application/zip"
                putExtra(Intent.EXTRA_STREAM, uri)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            startActivity(Intent.createChooser(share, "기록공유"))
            result.success(null)
        } catch (error: Exception) {
            contentResolver.delete(uri, null, null)
            result.error("CREATE_FAILED", error.message, null)
        }
    }

    private fun openSource(source: String) = if (source.startsWith("content://")) {
        contentResolver.openInputStream(Uri.parse(source))
    } else {
        val file = File(source)
        if (file.isFile) file.inputStream() else null
    }

    private fun safeEntryName(name: String): String =
        name.substringAfterLast('/').substringAfterLast('\\').ifBlank { "file" }

    private fun uniqueEntryName(names: MutableSet<String>, name: String): String {
        if (names.add(name)) return name
        val dot = name.lastIndexOf('.')
        val base = if (dot > 0) name.substring(0, dot) else name
        val extension = if (dot > 0) name.substring(dot) else ""
        var index = 2
        while (true) {
            val candidate = "$base-$index$extension"
            if (names.add(candidate)) return candidate
            index++
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != FILE_PICKER_REQUEST_CODE) return
        val result = filePickerResult ?: return
        filePickerResult = null
        if (resultCode != RESULT_OK ||
            data == null || (data.data == null && data.clipData == null)
        ) {
            result.success(null)
            return
        }
        val uris = buildList {
            data.clipData?.let { clipData ->
                for (index in 0 until clipData.itemCount) add(clipData.getItemAt(index).uri)
            }
            data.data?.let { uri -> if (isEmpty()) add(uri) }
        }
        val files = uris.map { uri ->
            try {
                contentResolver.takePersistableUriPermission(
                    uri,
                    Intent.FLAG_GRANT_READ_URI_PERMISSION,
                )
            } catch (_: SecurityException) {
                // Some document providers do not offer persistable permissions.
            }
            mapOf("uri" to uri.toString(), "name" to displayName(uri))
        }
        result.success(if (data.clipData != null) files else files.firstOrNull())
    }

    private fun displayName(uri: android.net.Uri): String {
        val cursor: Cursor? = contentResolver.query(
            uri,
            arrayOf(OpenableColumns.DISPLAY_NAME),
            null,
            null,
            null,
        )
        cursor.use {
            if (it != null && it.moveToFirst()) {
                return it.getString(0)
            }
        }
        return uri.lastPathSegment ?: "선택한 파일"
    }

    companion object {
        private const val FILE_PICKER_REQUEST_CODE = 1002
    }
}
