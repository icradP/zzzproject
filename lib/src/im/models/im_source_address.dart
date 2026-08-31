/// Stable source-scoped identifiers used by the client-side aggregate inbox.
abstract final class ImSourceAddress {
  static const separator = '::';

  static String scope(String sourceId, String localId) {
    if (sourceId.isEmpty || localId.isEmpty) return localId;
    if (sourceIdOf(localId) == sourceId) return localId;
    return '$sourceId$separator$localId';
  }

  static String? sourceIdOf(String value) {
    final index = value.indexOf(separator);
    return index <= 0 ? null : value.substring(0, index);
  }

  static String localIdOf(String value) {
    final index = value.indexOf(separator);
    return index <= 0 ? value : value.substring(index + separator.length);
  }
}
