extension IterableLastOrNull<T> on Iterable<T> {
  T? get lastOrNull {
    final iterator = this.iterator;
    if (!iterator.moveNext()) return null;
    var current = iterator.current;
    while (iterator.moveNext()) {
      current = iterator.current;
    }
    return current;
  }
}
