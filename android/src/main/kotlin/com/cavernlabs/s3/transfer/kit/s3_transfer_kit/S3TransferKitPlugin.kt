package com.cavernlabs.s3.transfer.kit.s3_transfer_kit

import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.BinaryMessenger
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.Future

/** S3TransferKitPlugin */
class S3TransferKitPlugin : FlutterPlugin, S3TransferKitHostApi {
    private var binaryMessenger: BinaryMessenger? = null
    private var flutterApi: S3TransferKitFlutterApi? = null
    private val executor = Executors.newCachedThreadPool()
    private val mainHandler = Handler(Looper.getMainLooper())
    private val activeTransfers = ConcurrentHashMap<String, Future<*>>()
    private val cancelledTasks = ConcurrentHashMap.newKeySet<String>()

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        binaryMessenger = flutterPluginBinding.binaryMessenger
        flutterApi = S3TransferKitFlutterApi(flutterPluginBinding.binaryMessenger)
        S3TransferKitHostApi.setUp(flutterPluginBinding.binaryMessenger, this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        S3TransferKitHostApi.setUp(binding.binaryMessenger, null)
        binaryMessenger = null
        flutterApi = null
        executor.shutdownNow()
    }

    override fun getPlatformVersion(): String {
        return "Android ${android.os.Build.VERSION.RELEASE}"
    }

    override fun isBackgroundTransferSupported(): Boolean {
        return true
    }

    override fun startBackgroundUpload(request: NativeUploadRequest) {
        cancelledTasks.remove(request.taskId)
        val future = executor.submit {
            try {
                val file = File(request.filePath)
                val totalBytes = file.length()
                val url = URL(request.url)
                val conn = url.openConnection() as HttpURLConnection
                conn.requestMethod = request.method
                conn.doOutput = true
                conn.setFixedLengthStreamingMode(totalBytes)
                for ((k, v) in request.headers) {
                    conn.setRequestProperty(k, v)
                }

                notifyState(request.taskId, "inProgress")

                val buffer = ByteArray(64 * 1024)
                var bytesTransferred = 0L
                FileInputStream(file).use { input ->
                    conn.outputStream.use { output ->
                        var read: Int
                        while (input.read(buffer).also { read = it } != -1) {
                            if (cancelledTasks.contains(request.taskId)) {
                                conn.disconnect()
                                notifyState(request.taskId, "cancelled")
                                return@submit
                            }
                            output.write(buffer, 0, read)
                            bytesTransferred += read
                            notifyProgress(request.taskId, bytesTransferred, totalBytes)
                        }
                        output.flush()
                    }
                }

                val responseCode = conn.responseCode
                val rawEtag = conn.getHeaderField("ETag")?.replace("\"", "")
                if (responseCode in 200..299) {
                    notifyState(
                        request.taskId,
                        "completed",
                        httpStatusCode = responseCode.toLong(),
                        eTag = rawEtag
                    )
                } else {
                    notifyState(
                        request.taskId,
                        "failed",
                        error = "HTTP $responseCode: ${conn.responseMessage}",
                        httpStatusCode = responseCode.toLong()
                    )
                }
            } catch (e: Exception) {
                if (cancelledTasks.contains(request.taskId)) {
                    notifyState(request.taskId, "cancelled")
                } else {
                    notifyState(request.taskId, "failed", error = e.localizedMessage ?: e.toString())
                }
            } finally {
                activeTransfers.remove(request.taskId)
            }
        }
        activeTransfers[request.taskId] = future
    }

    override fun startBackgroundDownload(request: NativeDownloadRequest) {
        cancelledTasks.remove(request.taskId)
        val future = executor.submit {
            try {
                val url = URL(request.url)
                val conn = url.openConnection() as HttpURLConnection
                conn.requestMethod = "GET"
                for ((k, v) in request.headers) {
                    conn.setRequestProperty(k, v)
                }

                notifyState(request.taskId, "inProgress")

                val responseCode = conn.responseCode
                if (responseCode !in 200..299) {
                    notifyState(
                        request.taskId,
                        "failed",
                        error = "HTTP $responseCode: ${conn.responseMessage}",
                        httpStatusCode = responseCode.toLong()
                    )
                    return@submit
                }

                val totalBytes = conn.contentLengthLong
                val rawEtag = conn.getHeaderField("ETag")?.replace("\"", "")
                val destFile = File(request.destinationPath)
                destFile.parentFile?.mkdirs()

                val buffer = ByteArray(64 * 1024)
                var bytesTransferred = 0L

                conn.inputStream.use { input ->
                    FileOutputStream(destFile).use { output ->
                        var read: Int
                        while (input.read(buffer).also { read = it } != -1) {
                            if (cancelledTasks.contains(request.taskId)) {
                                conn.disconnect()
                                destFile.delete()
                                notifyState(request.taskId, "cancelled")
                                return@submit
                            }
                            output.write(buffer, 0, read)
                            bytesTransferred += read
                            notifyProgress(request.taskId, bytesTransferred, totalBytes)
                        }
                        output.flush()
                    }
                }

                notifyState(
                    request.taskId,
                    "completed",
                    httpStatusCode = responseCode.toLong(),
                    eTag = rawEtag
                )
            } catch (e: Exception) {
                if (cancelledTasks.contains(request.taskId)) {
                    notifyState(request.taskId, "cancelled")
                } else {
                    notifyState(request.taskId, "failed", error = e.localizedMessage ?: e.toString())
                }
            } finally {
                activeTransfers.remove(request.taskId)
            }
        }
        activeTransfers[request.taskId] = future
    }

    override fun cancelBackgroundTransfer(taskId: String) {
        cancelledTasks.add(taskId)
        activeTransfers[taskId]?.cancel(true)
        activeTransfers.remove(taskId)
        notifyState(taskId, "cancelled")
    }

    override fun pauseBackgroundTransfer(taskId: String) {
        cancelBackgroundTransfer(taskId)
        notifyState(taskId, "paused")
    }

    override fun resumeBackgroundTransfer(taskId: String) {
        // Resumption handled at coordinator level
    }

    private fun notifyProgress(taskId: String, transferred: Long, total: Long) {
        mainHandler.post {
            flutterApi?.onTransferProgress(
                NativeTransferProgressUpdate(
                    taskId = taskId,
                    bytesTransferred = transferred,
                    totalBytes = total
                )
            ) {}
        }
    }

    private fun notifyState(
        taskId: String,
        status: String,
        error: String? = null,
        httpStatusCode: Long? = null,
        eTag: String? = null
    ) {
        mainHandler.post {
            flutterApi?.onTransferStateChanged(
                NativeTransferStateUpdate(
                    taskId = taskId,
                    status = status,
                    error = error,
                    httpStatusCode = httpStatusCode,
                    eTag = eTag
                )
            ) {}
        }
    }
}
