import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import '../../../core/auth/secure_storage.dart';
import '../agent_model.dart' show assistantModelPrefProvider;
import 'plan_oauth.dart';

typedef PlanChoice = ({String client, String model});
String planModelKey(String client, String model) =>
    'chatgpt:${Uri.encodeComponent(client)}/${Uri.encodeComponent(model)}';
PlanChoice? planChoiceOf(String key) {
  if (!key.startsWith('chatgpt:')) return null;
  final parts = key.substring(8).split('/');
  // A stale or malformed subscription selection must still stay on this route.
  try {
    if (parts.length == 2) {
      return (
        client: Uri.decodeComponent(parts[0]),
        model: Uri.decodeComponent(parts[1]),
      );
    }
  } on FormatException {
    /* Show the account picker for malformed selections. */
  }
  return (client: '', model: '');
}

class PlanProfile {
  PlanProfile._(this.id, Map data)
    : email = data['email'] as String? ?? '',
      label = data['label'] as String? ?? '',
      connected = data['grant'] != null,
      models = Map<String, String>.from(data['models'] as Map? ?? {}),
      selected = (data['selected'] as List? ?? const [])
          .whereType<String>()
          .toSet(),
      reasoning = {
        for (final e in (data['reasoning'] as Map? ?? {}).entries)
          if (e.key is String && e.value is List)
            e.key as String: (e.value as List).whereType<String>().toSet(),
      };
  final String id, email, label;
  final bool connected;
  final Map<String, String> models;
  final Map<String, Set<String>> reasoning;
  final Set<String> selected;
  Map<String, String> get selectedModels => {
    for (final e in models.entries)
      if (selected.contains(e.key)) e.key: e.value,
  };
  String get shortId => id.length > 6 ? id.substring(id.length - 6) : id;
  String get displayLabel => label == '$email · $shortId' ? email : label;
}

class PlanAccounts {
  PlanAccounts._(Map data)
    : activeId = data['active'] as String? ?? '',
      enabled = data['enabled'] != false,
      profiles = [
        for (final e in (data['profiles'] as Map).entries)
          if (e.key is String && e.value is Map)
            PlanProfile._(e.key as String, e.value as Map),
      ];
  final List<PlanProfile> profiles;
  final String activeId;
  final bool enabled;
  PlanProfile? find(String id) => profiles.where((p) => p.id == id).firstOrNull;
  PlanProfile? get active => find(activeId);
}

final planStoreProvider = Provider<PlanStore>((ref) {
  final httpClient = http.Client();
  ref.onDispose(httpClient.close);
  return PlanStore(
    ref.watch(secureStorageProvider),
    PlanOAuth(httpClient),
    savedModel: () => ref.read(assistantModelPrefProvider.future),
    onChanged: () {
      if (ref.mounted) ref.invalidate(planAccountsProvider);
    },
  );
});

final FutureProvider<PlanAccounts> planAccountsProvider =
    FutureProvider<PlanAccounts>((ref) {
      ref.watch(credentialRevisionProvider);
      return ref.watch(planStoreProvider).accounts(refreshOldCatalog: true);
    });

class PlanStore {
  PlanStore(
    this.storage,
    this.oauth, {
    this.directory = getApplicationSupportDirectory,
    this.onChanged,
    this.savedModel,
  });
  final FlutterSecureStorage storage;
  final PlanOAuth oauth;
  final Future<Directory> Function() directory;
  final void Function()? onChanged;
  final Future<String> Function()? savedModel;
  final _requests = <String, Set<http.Client>>{};
  final _checkedOldCatalog = <String>{};

  void track(String id, http.Client client) =>
      _requests.putIfAbsent(id, () => {}).add(client);
  void untrack(String id, http.Client client) {
    _requests[id]?.remove(client);
    if (_requests[id]?.isEmpty == true) _requests.remove(id);
  }

  void _stopRequests(String? id) {
    if (id == null) return;
    for (final client in _requests.remove(id) ?? <http.Client>{}) {
      client.close();
    }
  }

  static const _key = 'chatgpt_plan_profiles_v1';
  Future<void> _tail = Future.value();
  bool _signingIn = false;

  Future<Map<String, dynamic>> _read() async {
    final raw = await storage.read(key: _key);
    if (raw == null) return {'profiles': <String, dynamic>{}};
    try {
      final body = jsonDecode(raw);
      if (body is Map<String, dynamic> && body['profiles'] is Map) return body;
    } on FormatException {
      /* Never surface the protected document in an error message. */
    }
    throw const PlanAuthException('无法读取本机订阅账户记录');
  }

  Future<void> _save(Map data) async {
    await storage.write(key: _key, value: jsonEncode(data));
    onChanged?.call();
  }

  // Refresh tokens rotate. Serialize the read, exchange and protected write across windows/processes.
  Future<T> _locked<T>(Future<T> Function(Map<String, dynamic>) action) {
    final future = _tail.then((_) async {
      final dir = await directory();
      await dir.create(recursive: true);
      final file = await File(
        '${dir.path}/chatgpt-session.lock',
      ).open(mode: FileMode.append);
      try {
        await file.lock(FileLock.blockingExclusive);
        return await action(await _read());
      } finally {
        await file.close();
      }
    });
    _tail = future.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return future;
  }

  Future<PlanAccounts> accounts({bool refreshOldCatalog = false}) async {
    final data = await _read();
    final profiles = (data['profiles'] as Map).values.whereType<Map>();
    if (profiles.any((p) => !p.containsKey('selected'))) {
      final previous = planChoiceOf(await savedModel?.call() ?? '');
      await _locked((latest) async {
        var changed = false;
        for (final e in (latest['profiles'] as Map).entries) {
          if (e.value is! Map) continue;
          final p = e.value as Map;
          if (p.containsKey('selected')) continue;
          p['selected'] = [
            if (previous != null &&
                previous.client == e.key &&
                (p['models'] as Map?)?.containsKey(previous.model) == true)
              previous.model,
          ];
          changed = true;
        }
        if (changed) await _save(latest);
      });
      return accounts(refreshOldCatalog: refreshOldCatalog);
    }
    final snapshot = PlanAccounts._(data);
    final active = snapshot.active;
    if (refreshOldCatalog &&
        active != null &&
        active.connected &&
        active.models.isNotEmpty &&
        data['profiles'][active.id]['reasoning'] == null &&
        _checkedOldCatalog.add(active.id)) {
      try {
        await refreshModels(active.id);
      } on Exception {
        // Offline users can still select a saved model with its default effort.
      }
      return accounts();
    }
    return snapshot;
  }

  Future<bool> get hasSignedIn async => (await _read())['noticeVersion'] == 1;

  Future<String?> signIn({String? id, Future<void>? cancel}) async {
    if (_signingIn) throw const PlanAuthException('已有登录窗口正在等待授权');
    _signingIn = true;
    try {
      final info = await _locked((data) async {
        final saved = data['profiles'][id] as Map?;
        if (id != null && saved == null) {
          throw const PlanAuthException('找不到此工作区');
        }
        if (data['host'] == null) {
          data['host'] = newPlanHostId();
          await _save(data);
        }
        return (host: data['host'] as String, profile: saved);
      });
      final current = info.profile;
      final login = await oauth.authorize(
        host: info.host,
        existingClient: id,
        subject: current?['subject'] as String?,
        email: current?['email'] as String?,
        hint: current?['grant']?['idToken'] as String?,
        cancel: cancel,
      );
      if (login == null) return null;
      await _locked((data) async {
        final profiles = data['profiles'] as Map;
        final old = profiles[login.clientId] as Map?;
        if (old != null && old['subject'] != login.identity.subject) {
          throw const PlanAuthException('工作区身份不一致');
        }
        final shortId = login.clientId.length > 6
            ? login.clientId.substring(login.clientId.length - 6)
            : login.clientId;
        profiles[login.clientId] = {
          ...?old,
          if (old == null) 'selected': <String>[],
          'subject': login.identity.subject,
          'email': login.identity.email,
          'label':
              old?['label'] ??
              '${login.identity.email.isEmpty ? 'ChatGPT' : login.identity.email} · $shortId',
          'grant': login.grant.toJson(),
        };
        if (data['active'] != login.clientId) {
          _stopRequests(data['active'] as String?);
        }
        data['active'] = login.clientId;
        data['noticeVersion'] = 1;
        await _save(data);
      });
      return login.clientId;
    } finally {
      _signingIn = false;
    }
  }

  Future<void> activate(String id) => _locked((data) async {
    if (data['profiles'][id]?['grant'] == null) {
      throw const PlanAuthException('请先登录此工作区');
    }
    if (data['active'] != id) _stopRequests(data['active'] as String?);
    data['active'] = id;
    await _save(data);
  });
  Future<void> rename(String id, String label) => _locked((data) async {
    if (label.trim().isEmpty || data['profiles'][id] == null) return;
    data['profiles'][id]['label'] = label.trim();
    await _save(data);
  });

  Future<void> setEnabled(bool enabled) => _locked((data) async {
    if (!enabled) _stopRequests(data['active'] as String?);
    data['enabled'] = enabled;
    await _save(data);
  });

  Future<PlanProfile> selectModels(String id, Set<String> selected) =>
      _locked((data) async {
        final p = data['profiles'][id] as Map?;
        if (p == null || p['grant'] == null || data['active'] != id) {
          throw const PlanAuthException('当前工作区已切换');
        }
        final models = p['models'] as Map? ?? const {};
        p['selected'] = selected.where(models.containsKey).toList();
        await _save(data);
        return PlanProfile._(id, p);
      });

  Future<String> access(String id, {String? model}) => _locked((data) async {
    final profile = data['profiles'][id] as Map?;
    if (data['active'] != id || profile == null || profile['grant'] == null) {
      throw const PlanAuthException('请先在模型列表中选择并登录这个 ChatGPT 工作区');
    }
    if (model != null && data['enabled'] == false) {
      throw const PlanAuthException('请先在「接口与订阅」启用 ChatGPT 订阅');
    }
    if (model != null &&
        (model.isEmpty ||
            !(profile['selected'] as List? ?? const []).contains(model) ||
            (profile['models'] as Map?)?.containsKey(model) != true)) {
      throw const PlanAuthException('请在这个工作区点击「重新拉取模型」并勾选要使用的模型');
    }
    var grant = PlanGrant.fromJson(profile['grant'] as Map);
    if (DateTime.now().millisecondsSinceEpoch + 60000 >= grant.expires) {
      try {
        grant = await oauth.renew(id, profile['subject'] as String, grant);
      } on PlanAuthException catch (e) {
        if (e.expired) {
          profile.remove('grant');
          await _save(data);
        }
        rethrow;
      }
      profile['grant'] = grant.toJson();
      await _save(data);
    }
    return grant.access;
  });

  Future<PlanProfile> refreshModels(String id) async {
    final token = await access(id);
    final request = http.Request('GET', Uri.parse('$planResource/models'))
      ..followRedirects = false
      ..headers['Authorization'] = 'Bearer $token';
    final response = await oauth.client
        .send(request)
        .then(http.Response.fromStream)
        .timeout(const Duration(seconds: 25));
    if (response.statusCode != 200) {
      throw PlanAuthException('无法获取此工作区的模型（HTTP ${response.statusCode}）');
    }
    Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException {
      throw const PlanAuthException('OpenAI 返回的模型目录无法读取');
    }
    final rows = decoded is Map ? decoded['models'] : null;
    if (rows is! List) throw const PlanAuthException('OpenAI 返回的模型目录无法读取');
    final models = <String, String>{};
    final reasoning = <String, List<String>>{};
    for (final row in rows.whereType<Map>()) {
      final slug = row['slug'];
      if (row['visibility'] == 'list' && slug is String && slug.isNotEmpty) {
        models[slug] = row['display_name'] as String? ?? slug;
        if (row['supported_reasoning_levels'] case final List levels) {
          reasoning[slug] = [
            for (final level in levels)
              if (level case {'effort': final String effort})
                effort
              else if (level is String)
                level,
          ];
        }
      }
    }
    return _locked((data) async {
      final profile = data['profiles'][id] as Map?;
      if (data['active'] != id || profile?['grant'] == null) {
        throw const PlanAuthException('当前工作区已切换');
      }
      profile!['models'] = models;
      profile['reasoning'] = reasoning;
      await _save(data);
      return PlanProfile._(id, profile);
    });
  }

  Future<bool> signOut(String id) => _locked((data) async {
    final profile = data['profiles'][id] as Map?;
    if (profile == null) return true;
    _stopRequests(id);
    final token = profile['grant']?['refresh'] as String?;
    final ok = token == null || await oauth.revoke(id, token);
    profile.remove('grant');
    profile.remove('models');
    profile.remove('reasoning');
    if (data['active'] == id) data.remove('active');
    await _save(data);
    return ok;
  });
}
