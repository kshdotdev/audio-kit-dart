import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voice_core/voice_core.dart';
import 'package:voice_flutter/voice_flutter.dart';

void main() {
  testWidgets('status indicator presents independent session and turn states', (
    tester,
  ) async {
    const speaking = VoiceConversationSnapshot(
      sessionState: VoiceSessionState.active,
      turnState: VoiceTurnState.speaking,
      generationId: 3,
    );

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: VoiceStatusIndicator(snapshot: speaking)),
      ),
    );

    expect(find.text('Speaking'), findsOneWidget);
    expect(
      tester.getSemantics(find.byType(VoiceStatusIndicator)).label,
      contains('Voice status: Speaking'),
    );
  });

  testWidgets('state builder updates from snapshots', (tester) async {
    final snapshots = StreamController<VoiceConversationSnapshot>();
    addTearDown(snapshots.close);

    await tester.pumpWidget(
      MaterialApp(
        home: VoiceStateBuilder(
          initialData: VoiceConversationSnapshot.initial,
          snapshots: snapshots.stream,
          builder: (context, snapshot) => Text(snapshot.turnState.name),
        ),
      ),
    );
    expect(find.text('idle'), findsOneWidget);

    snapshots.add(
      const VoiceConversationSnapshot(
        sessionState: VoiceSessionState.active,
        turnState: VoiceTurnState.listening,
        generationId: 0,
      ),
    );
    await tester.pump();
    expect(find.text('listening'), findsOneWidget);
  });

  testWidgets('control selects start, stop, and interrupt actions', (
    tester,
  ) async {
    var action = '';
    var snapshot = VoiceConversationSnapshot.initial;

    Widget build() => MaterialApp(
      home: Scaffold(
        body: VoiceControlButton(
          snapshot: snapshot,
          onStart: () => action = 'start',
          onStop: () => action = 'stop',
          onInterrupt: () => action = 'interrupt',
        ),
      ),
    );

    await tester.pumpWidget(build());
    await tester.tap(find.text('Start listening'));
    expect(action, 'start');

    snapshot = const VoiceConversationSnapshot(
      sessionState: VoiceSessionState.active,
      turnState: VoiceTurnState.listening,
      generationId: 0,
    );
    await tester.pumpWidget(build());
    await tester.tap(find.text('Stop listening'));
    expect(action, 'stop');

    snapshot = const VoiceConversationSnapshot(
      sessionState: VoiceSessionState.active,
      turnState: VoiceTurnState.speaking,
      generationId: 1,
    );
    await tester.pumpWidget(build());
    await tester.tap(find.text('Interrupt response'));
    expect(action, 'interrupt');
  });

  testWidgets('transcript view distinguishes interim and response text', (
    tester,
  ) async {
    const snapshot = VoiceConversationSnapshot(
      sessionState: VoiceSessionState.active,
      turnState: VoiceTurnState.thinking,
      generationId: 2,
      interimTranscript: 'hello wor',
      finalTranscript: 'old final',
      responseText: 'How can I help?',
    );

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: VoiceTranscriptView(snapshot: snapshot)),
      ),
    );

    expect(find.text('hello wor'), findsOneWidget);
    expect(find.text('old final'), findsNothing);
    expect(find.text('How can I help?'), findsOneWidget);
  });
}
