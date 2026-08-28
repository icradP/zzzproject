import 'package:flutter/material.dart';

import 'adapters/im_message_source.dart';
import 'data/im_interaction_handler.dart';
import 'data/im_nsfw_checker.dart';
import 'data/im_repository.dart';
import 'data/im_push_manager.dart';

/// Provides [ImRepository], interaction callbacks, and the NSFW checker
/// to the widget tree.
class ImScope extends InheritedWidget {
  const ImScope({
    required this.repository,
    required this.interactions,
    required this.nsfwChecker,
    required this.nsfwStateCache,
    required this.pushManager,
    this.connectionStatus,
    required super.child,
    super.key,
  });

  final ImRepository repository;
  final ImInteractionHandler interactions;
  final ImNsfwChecker nsfwChecker;
  final NsfwStateCache nsfwStateCache;
  final ImPushManager pushManager;
  final Stream<ConnectionStatus>? connectionStatus;

  static ImScope of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<ImScope>();
    assert(scope != null, 'ImScope not found in context');
    return scope!;
  }

  static ImRepository repositoryOf(BuildContext context) =>
      of(context).repository;

  static ImInteractionHandler interactionsOf(BuildContext context) =>
      of(context).interactions;

  static ImNsfwChecker nsfwCheckerOf(BuildContext context) =>
      of(context).nsfwChecker;

  static NsfwStateCache nsfwStateCacheOf(BuildContext context) =>
      of(context).nsfwStateCache;

  static ImPushManager pushManagerOf(BuildContext context) =>
      of(context).pushManager;

  static Stream<ConnectionStatus>? connectionStatusOf(BuildContext context) =>
      of(context).connectionStatus;

  @override
  bool updateShouldNotify(ImScope oldWidget) {
    return repository != oldWidget.repository ||
        interactions != oldWidget.interactions ||
        nsfwChecker != oldWidget.nsfwChecker ||
        nsfwStateCache != oldWidget.nsfwStateCache ||
        pushManager != oldWidget.pushManager ||
        connectionStatus != oldWidget.connectionStatus;
  }
}
