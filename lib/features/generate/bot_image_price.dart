import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/auth_mode.dart';
import '../../core/net/anlas_provider.dart';
import '../../l10n/l10n.dart';
import 'models.dart';

/// Bot image quotes use yuan per image. Direct keys and shared-pool Anlas
/// estimates keep their own calculation and billing units.
class BotImagePrice {
  const BotImagePrice(this.yuan) : status = null;
  const BotImagePrice.unavailable(this.status) : yuan = null;
  final double? yuan;
  final String? status;

  bool get free => yuan == 0;
  String get label =>
      status ?? (free ? l10nNow.free : '${formatRelayPrice(yuan!)}/张');
  String forCount(int n) => yuan == null || free || n <= 1
      ? label
      : '$label · 共 ${formatRelayPrice(yuan! * n)}';
}

String formatRelayPrice(double price) {
  if (price == 0) return l10nNow.free;
  // The service also quotes fractions of a fen.
  final fen = price * 100;
  final digits = (fen - fen.round()).abs() > 1e-8 ? 3 : 2;
  return '¥${price.toStringAsFixed(digits)}';
}

final botImagePriceProvider = Provider.autoDispose
    .family<BotImagePrice?, String>((ref, model) {
      if (!model.startsWith('NAI ') ||
          ref.watch(authModeProvider).value != AuthMode.bot) {
        return null;
      }
      final response = ref.watch(naiQuotaProvider);
      final quota = response.asData?.value;
      if (quota == null) {
        return BotImagePrice.unavailable(
          response.isLoading ? '查询价格…' : '价格暂不可用',
        );
      }
      if (!quota.relayOnly) return null;
      if (!quota.relayAvailable) {
        return const BotImagePrice.unavailable('中转不可用');
      }
      if (!quota.relayEnabled) return const BotImagePrice.unavailable('中转未启用');
      final price = isNai5Model(model)
          ? quota.relayPrice
          : model.startsWith('NAI 4.5')
          ? quota.relayPrice45
          : quota.relayPriceLegacy;
      return BotImagePrice(price);
    });
