/// Typed download progress to avoid raw callbacks with multiple nullable args.
class DownloadProgress {
  final int receivedBytes;
  final int? totalBytes;
  
  double get percentage =>
      (totalBytes != null && totalBytes! > 0)
          ? (receivedBytes / totalBytes! * 100).clamp(0, 100)
          : -1;

  DownloadProgress(this.receivedBytes, this.totalBytes);
}
