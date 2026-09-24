package com.zensoultion.travel_record

import android.Manifest
import android.content.Intent
import android.database.Cursor
import android.os.Build
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
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
                if (call.method != "pickFile") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                if (filePickerResult != null) {
                    result.error("PICKER_BUSY", "파일 선택창이 이미 열려 있습니다.", null)
                    return@setMethodCallHandler
                }
                filePickerResult = result
                startActivityForResult(
                    Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        type = "*/*"
                    },
                    FILE_PICKER_REQUEST_CODE,
                )
            }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != FILE_PICKER_REQUEST_CODE) return
        val result = filePickerResult ?: return
        filePickerResult = null
        if (resultCode != RESULT_OK || data?.data == null) {
            result.success(null)
            return
        }
        val uri = data.data!!
        try {
            contentResolver.takePersistableUriPermission(
                uri,
                Intent.FLAG_GRANT_READ_URI_PERMISSION,
            )
        } catch (_: SecurityException) {
            // Some document providers do not offer persistable permissions.
        }
        result.success(mapOf("uri" to uri.toString(), "name" to displayName(uri)))
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
