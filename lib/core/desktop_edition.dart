/// The standard app and the remote upload feature use separate update assets.
enum DesktopEdition { standard, remoteUpload }

const kDesktopEdition = DesktopEdition.remoteUpload;

bool matchesDesktopEditionAsset(String name, DesktopEdition edition) {
  final lower = name.toLowerCase();
  final remote =
      lower.contains('remoteupload') || lower.contains('remote-upload');
  return remote == (edition == DesktopEdition.remoteUpload);
}
