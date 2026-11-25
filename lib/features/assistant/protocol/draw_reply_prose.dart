/// Some model replies wrap the actual drawing dialogue in a simulated file read.
/// Require the full transcript, including the named file in the directory listing.
final _documentTranscript = RegExp(
  r'^([\w.-]+@[\w.-]+):~\$[ \t]+cd[ \t]+(?:~/)?([\w.-]+)[ \t]*\r?\n'
  r'\1:~/\2\$[ \t]+ls[ \t]*\r?\n'
  r'((?:[\w. \t-]+\r?\n){1,32})'
  r'\1:~/\2\$[ \t]+cat[ \t]+([\w.-]+\.(?:txt|md))[ \t]*\r?\n'
  r'```(?:markdown|md|text|plaintext)?[ \t]*(?:\r?\n|$)',
);
final _closingFence = RegExp(r'(?:^|\r?\n)```[ \t]*$');

String drawReplyProse(String text) {
  final match = _documentTranscript.firstMatch(text.trimLeft());
  if (match == null || !match[3]!.split(RegExp(r'\s+')).contains(match[4])) {
    return text;
  }
  return text
      .trimLeft()
      .substring(match.end)
      .trim()
      .replaceFirst(_closingFence, '')
      .trimRight();
}
