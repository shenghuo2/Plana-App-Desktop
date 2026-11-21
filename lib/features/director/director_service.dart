import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/auth_mode.dart';
import '../../core/auth/nai_keys.dart';
import '../../core/auth/token_store.dart';
import '../../core/net/nai_client.dart';
import '../../core/net/nai_endpoint.dart';
import '../../core/net/nai_gate.dart';
import '../../core/net/nai_proxy.dart';
import 'director_codec.dart';
import 'director_models.dart';
import 'pixel_snap.dart';

class DirectorAccess {
  const DirectorAccess({this.key, this.proxy = false, this.reason});
  final NaiKey? key;
  final bool proxy;
  final String? reason;
  bool get available => reason == null && key != null;
  String get label {
    if (key == null) return reason ?? '尚未配置接口';
    final route = key!.isThirdParty
        ? '第三方 NAI 接口'
        : proxy
        ? 'Cloudflare 转发'
        : 'NovelAI 官方接口';
    return key!.label.isEmpty ? route : '$route · ${key!.label}';
  }
}

DirectorAccess directorAccessFor(AuthMode? mode, NaiKey? key, bool proxy) {
  if (mode == AuthMode.bot) {
    return const DirectorAccess(reason: 'Bot 授权账户不支持导演工具接口；可使用本机像素对齐');
  }
  if (mode != AuthMode.token || key == null || key.token.trim().isEmpty) {
    return const DirectorAccess(reason: '请先在账户设置中配置 NovelAI 接口');
  }
  if (naiEndpointIsChat(key.endpoint)) {
    return DirectorAccess(key: key, reason: 'OpenAI 格式接口不支持导演转换；可使用本机像素对齐');
  }
  return DirectorAccess(
    key: key,
    proxy: proxy,
    reason: !key.joinPaid ? '当前账户未允许点数处理，请先调整账户设置' : null,
  );
}

final directorAccessProvider = Provider<DirectorAccess>((ref) {
  final mode = ref.watch(authModeProvider);
  final key = ref.watch(primaryNaiKeyProvider);
  if (mode.isLoading || (mode.value == AuthMode.token && key.isLoading)) {
    return const DirectorAccess(reason: '正在读取账户设置…');
  }
  return directorAccessFor(mode.value, key.value, ref.watch(naiProxyProvider));
});

typedef DirectorRunner =
    Future<List<DirectorOutput>> Function(
      DirectorInput source,
      DirectorOptions options,
      DirectorAccess access,
    );

final directorRunnerProvider = Provider<DirectorRunner>((ref) {
  final gate = ref.read(naiGateProvider);
  return (source, options, access) async {
    options.validate();
    if (options.tool.local) {
      return [
        await compute((args) => snapDirectorPixels(args.$1, args.$2), (
          source.bytes,
          options,
        )),
      ];
    }
    if (!access.available) throw StateError(access.reason ?? '没有可用接口');
    final key = access.key!;
    final prepared = await compute(prepareDirectorImage, source.bytes);
    final pass = await gate.acquire(paid: true, keyId: key.id);
    try {
      if (pass.token == null) throw StateError('所选账户已不可用，请检查账户设置');
      if (pass.base != key.endpoint || pass.token != key.token) {
        throw StateError('等待期间账户配置已改变，请确认后重新转换');
      }
      final client = NaiClient(base: pass.base, proxy: access.proxy);
      final bytes = await client.augmentImage(
        token: pass.token!,
        parameters: {
          ...options.requestParameters(),
          'image': prepared.image,
          'width': prepared.width,
          'height': prepared.height,
        },
      );
      return await compute((args) => decodeDirectorResponse(args.$1, args.$2), (
        bytes,
        options.tool,
      ));
    } finally {
      gate.release(pass.slot);
    }
  };
});

String directorError(Object error) => switch (error) {
  FormatException e => e.message,
  NaiException e => e.message,
  StateError e => e.message,
  TimeoutException() => '转换请求超时，服务可能已处理。请先确认余额；本次不会自动重试。',
  SocketException() => '连接失败，请检查网络与代理设置。',
  _ => '处理失败，请检查图片和当前接口后重试。',
};
