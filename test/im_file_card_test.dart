import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zzzproject/src/im/widgets/im_chat_room_view/im_file_card.dart';

void main() {
  testWidgets('video attachment exposes its open action', (tester) async {
    var opened = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ImFileCard(
            fileName: 'clip.mp4',
            fileSize: 2048,
            isMine: true,
            isVideo: true,
            onOpen: () => opened = true,
          ),
        ),
      ),
    );

    expect(find.byIcon(Icons.videocam_rounded), findsOneWidget);
    expect(find.byIcon(Icons.play_circle_outline_rounded), findsOneWidget);
    expect(find.text('2.0 KB'), findsOneWidget);

    await tester.tap(find.text('clip.mp4'));
    expect(opened, isTrue);
  });
}
