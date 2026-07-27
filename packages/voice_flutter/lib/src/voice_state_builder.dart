import 'package:flutter/widgets.dart';
import 'package:voice_core/voice_core.dart';

/// Builds UI from a voice snapshot stream with an explicit initial value.
class VoiceStateBuilder extends StatelessWidget {
  /// Creates a state builder.
  const VoiceStateBuilder({
    required this.initialData,
    required this.snapshots,
    required this.builder,
    super.key,
  });

  /// State rendered before the stream emits.
  final VoiceConversationSnapshot initialData;

  /// Voice state stream, typically a controller's `snapshots`.
  final Stream<VoiceConversationSnapshot> snapshots;

  /// Builds the current voice UI.
  final Widget Function(
    BuildContext context,
    VoiceConversationSnapshot snapshot,
  )
  builder;

  @override
  Widget build(BuildContext context) =>
      StreamBuilder<VoiceConversationSnapshot>(
        initialData: initialData,
        stream: snapshots,
        builder: (context, asyncSnapshot) =>
            builder(context, asyncSnapshot.data ?? initialData),
      );
}
