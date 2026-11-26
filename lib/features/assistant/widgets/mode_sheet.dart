import 'package:flutter/material.dart';

import '../../../l10n/l10n.dart';
import '../assistant_mode.dart';
import 'assistant_choice_sheet.dart';

IconData assistantModeIcon(AssistantMode m, {bool on = false}) => switch (m) {
  AssistantMode.normal => Icons.layers_clear_outlined,
  AssistantMode.comic => on ? Icons.view_quilt : Icons.view_quilt_outlined,
  AssistantMode.natural => on ? Icons.notes : Icons.notes_outlined,
};

Future<AssistantMode?> showModeSheet(
  BuildContext context, {
  required AssistantMode current,
}) => showAssistantChoiceSheet(
  context,
  title: l10nNow.chatMode,
  current: current,
  choices: AssistantMode.values,
  label: assistantModeLabel,
  icon: assistantModeIcon,
);
