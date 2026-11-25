import 'package:flutter/material.dart';

import '../../../l10n/l10n.dart';
import '../assistant_settings.dart';
import 'assistant_choice_sheet.dart';

Future<ThinkLevel?> showThinkSheet(
  BuildContext anchor, {
  required ThinkLevel current,
  required List<ThinkLevel> choices,
}) => showAssistantChoiceSheet(
  anchor,
  title: l10nNow.adjustThinkDepth,
  current: current,
  choices: choices,
  label: thinkLevelLabel,
  preferAbove: true,
  icon: (level) => switch (level) {
    ThinkLevel.off => Icons.lightbulb_outline,
    ThinkLevel.auto => Icons.auto_awesome_outlined,
    ThinkLevel.low => Icons.signal_cellular_alt_1_bar,
    ThinkLevel.medium => Icons.signal_cellular_alt_2_bar,
    ThinkLevel.high => Icons.signal_cellular_alt,
    ThinkLevel.ultra => Icons.bolt_outlined,
  },
);
