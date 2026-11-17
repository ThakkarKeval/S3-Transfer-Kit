import FlutterMacOS
import Foundation

public class S3TransferKitPlugin: NSObject, FlutterPlugin, S3TransferKitHostApi, URLSessionTaskDelegate, URLSessionDataDelegate {
  private var flutterApi: S3TransferKitFlutterApi?
  private var activeTasks: [String: URLSessionTask] = [:]
  private var taskTotals: [String: Int64] = [:]
  private let lock = NSLock()

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = S3TransferKitPlugin()
    instance.flutterApi = S3TransferKitFlutterApi(binaryMessenger: registrar.messenger)
    S3TransferKitHostApiSetup.setUp(binaryMessenger: registrar.messenger, api: instance)
  }

  public func getPlatformVersion() throws -> String? {
    let version = ProcessInfo.processInfo.operatingSystemVersion
    return "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
  }

  public func isBackgroundTransferSupported() throws -> Bool {
    return true
  }

  public func startBackgroundUpload(request: NativeUploadRequest) throws {
    guard let url = URL(string: request.url) else {
      notifyState(taskId: request.taskId, status: "failed", error: "Invalid URL")
      return
    }

    var urlRequest = URLRequest(url: url)
    urlRequest.httpMethod = request.method
    for (k, v) in request.headers {
      urlRequest.setValue(v, forHTTPHeaderField: k)
    }

    let fileUrl = URL(fileURLWithPath: request.filePath)
    let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    let uploadTask = session.uploadTask(with: urlRequest, fromFile: fileUrl)
    uploadTask.taskDescription = request.taskId

    lock.lock()
    activeTasks[request.taskId] = uploadTask
    lock.unlock()

    notifyState(taskId: request.taskId, status: "inProgress")
    uploadTask.resume()
  }

  public func startBackgroundDownload(request: NativeDownloadRequest) throws {
    guard let url = URL(string: request.url) else {
      notifyState(taskId: request.taskId, status: "failed", error: "Invalid URL")
      return
    }

    var urlRequest = URLRequest(url: url)
    urlRequest.httpMethod = "GET"
    for (k, v) in request.headers {
      urlRequest.setValue(v, forHTTPHeaderField: k)
    }

    let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    let destUrl = URL(fileURLWithPath: request.destinationPath)

    let downloadTask = session.downloadTask(with: urlRequest) { [weak self] tempUrl, response, error in
      guard let self = self else { return }
      self.lock.lock()
      self.activeTasks.removeValue(forKey: request.taskId)
      self.lock.unlock()

      if let error = error {
        if (error as NSError).code == NSURLErrorCancelled {
          self.notifyState(taskId: request.taskId, status: "cancelled")
        } else {
          self.notifyState(taskId: request.taskId, status: "failed", error: error.localizedDescription)
        }
        return
      }

      guard let tempUrl = tempUrl, let httpResponse = response as? HTTPURLResponse else {
        self.notifyState(taskId: request.taskId, status: "failed", error: "No response received")
        return
      }

      if httpResponse.statusCode >= 200 && httpResponse.statusCode < 300 {
        do {
          try? FileManager.default.removeItem(at: destUrl)
          try FileManager.default.createDirectory(at: destUrl.deletingLastPathComponent(), withIntermediateDirectories: true)
          try FileManager.default.moveItem(at: tempUrl, to: destUrl)
          let eTag = httpResponse.allHeaderFields["ETag"] as? String ?? httpResponse.allHeaderFields["etag"] as? String
          self.notifyState(
            taskId: request.taskId,
            status: "completed",
            httpStatusCode: Int64(httpResponse.statusCode),
            eTag: eTag?.replacingOccurrences(of: "\"", with: "")
          )
        } catch {
          self.notifyState(taskId: request.taskId, status: "failed", error: error.localizedDescription)
        }
      } else {
        self.notifyState(
          taskId: request.taskId,
          status: "failed",
          error: "HTTP \(httpResponse.statusCode)",
          httpStatusCode: Int64(httpResponse.statusCode)
        )
      }
    }

    downloadTask.taskDescription = request.taskId
    lock.lock()
    activeTasks[request.taskId] = downloadTask
    lock.unlock()

    notifyState(taskId: request.taskId, status: "inProgress")
    downloadTask.resume()
  }

  public func cancelBackgroundTransfer(taskId: String) throws {
    lock.lock()
    let task = activeTasks.removeValue(forKey: taskId)
    lock.unlock()
    task?.cancel()
    notifyState(taskId: taskId, status: "cancelled")
  }

  public func pauseBackgroundTransfer(taskId: String) throws {
    try cancelBackgroundTransfer(taskId: taskId)
    notifyState(taskId: taskId, status: "paused")
  }

  public func resumeBackgroundTransfer(taskId: String) throws {}

  public func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didSendBodyData bytesSent: Int64,
    totalBytesSent: Int64,
    totalBytesExpectedToSend: Int64
  ) {
    guard let taskId = task.taskDescription else { return }
    notifyProgress(taskId: taskId, transferred: totalBytesSent, total: totalBytesExpectedToSend)
  }

  public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    guard let taskId = task.taskDescription else { return }
    lock.lock()
    activeTasks.removeValue(forKey: taskId)
    lock.unlock()

    if let error = error {
      if (error as NSError).code == NSURLErrorCancelled {
        notifyState(taskId: taskId, status: "cancelled")
      } else {
        notifyState(taskId: taskId, status: "failed", error: error.localizedDescription)
      }
      return
    }

    if let httpResponse = task.response as? HTTPURLResponse {
      let eTag = httpResponse.allHeaderFields["ETag"] as? String ?? httpResponse.allHeaderFields["etag"] as? String
      if httpResponse.statusCode >= 200 && httpResponse.statusCode < 300 {
        notifyState(
          taskId: taskId,
          status: "completed",
          httpStatusCode: Int64(httpResponse.statusCode),
          eTag: eTag?.replacingOccurrences(of: "\"", with: "")
        )
      } else {
        notifyState(
          taskId: taskId,
          status: "failed",
          error: "HTTP \(httpResponse.statusCode)",
          httpStatusCode: Int64(httpResponse.statusCode)
        )
      }
    }
  }

  private func notifyProgress(taskId: String, transferred: Int64, total: Int64) {
    Task { @MainActor in
      try? await self.flutterApi?.onTransferProgress(
        update: NativeTransferProgressUpdate(
          taskId: taskId,
          bytesTransferred: transferred,
          totalBytes: total
        )
      )
    }
  }

  private func notifyState(
    taskId: String,
    status: String,
    error: String? = nil,
    httpStatusCode: Int64? = nil,
    eTag: String? = nil
  ) {
    Task { @MainActor in
      try? await self.flutterApi?.onTransferStateChanged(
        update: NativeTransferStateUpdate(
          taskId: taskId,
          status: status,
          error: error,
          httpStatusCode: httpStatusCode,
          eTag: eTag
        )
      )
    }
  }
}
