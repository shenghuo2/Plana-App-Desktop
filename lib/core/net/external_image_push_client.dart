/// Client for the pic-manager external image push API.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// A concise, user-displayable failure from the external image API.
class ExternalImagePushException implements Exception {
  const ExternalImagePushException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

/// The subset of a successful upload response the app needs to present.
class ExternalImagePushReceipt {
  const ExternalImagePushReceipt({
    required this.id,
    required this.deduplicated,
  });

  final String id;
  final bool deduplicated;
}

/// Extracted to make the multipart contract testable without a real server.
typedef ExternalImagePushRequestSender =
    Future<http.StreamedResponse> Function(http.MultipartRequest request);

/// Turns a configured service URL into the API's one upload endpoint.
///
/// Both a service root (`https://images.example`) and a complete endpoint
/// (`https://images.example/api/v1/assets`) are accepted. Query strings and
/// fragments are deliberately rejected so a credential cannot accidentally be
/// configured into a URL that may be displayed or logged by networking stacks.
Uri externalImagePushAssetUri(String configuredEndpoint) {
  final raw = configuredEndpoint.trim();
  final uri = Uri.tryParse(raw);
  if (uri == null ||
      (uri.scheme != 'http' && uri.scheme != 'https') ||
      uri.host.isEmpty) {
    throw const ExternalImagePushException('请输入有效的 http 或 https API 地址');
  }
  if (uri.hasQuery || uri.hasFragment || uri.userInfo.isNotEmpty) {
    throw const ExternalImagePushException('API 地址不能包含查询参数、片段或账号信息');
  }

  var path = uri.path.replaceFirst(RegExp(r'/+$'), '');
  const suffix = '/api/v1/assets';
  if (!path.endsWith(suffix)) {
    path = path.isEmpty ? suffix : '$path$suffix';
  }
  return uri.replace(path: path);
}

/// Sends an original gallery image to the external image push API.
class ExternalImagePushClient {
  ExternalImagePushClient({
    this.requestSender,
    http.Client Function()? clientFactory,
  }) : _clientFactory = clientFactory ?? http.Client.new;

  final ExternalImagePushRequestSender? requestSender;
  final http.Client Function() _clientFactory;

  Future<ExternalImagePushReceipt> upload({
    required Uri endpoint,
    required String token,
    required Uint8List imageBytes,
    required Map<String, dynamic> source,
    required String fileName,
    Duration timeout = const Duration(minutes: 2),
  }) async {
    final bearer = token.trim();
    if (bearer.isEmpty) {
      throw const ExternalImagePushException('请先配置云存储 Token');
    }
    if (imageBytes.isEmpty) {
      throw const ExternalImagePushException('图片数据为空,无法上传');
    }

    final request = http.MultipartRequest('POST', endpoint)
      ..headers['Authorization'] = 'Bearer $bearer'
      ..fields['source'] = jsonEncode(source)
      ..files.add(
        http.MultipartFile(
          'file',
          Stream<List<int>>.value(imageBytes),
          imageBytes.length,
          filename: fileName,
        ),
      );

    http.Client? client;
    try {
      // Timeout covers receiving the body too. Closing the per-upload client
      // releases the connection if headers arrive but the server then stalls.
      final response = await (() async {
        final sender = requestSender;
        final streamed = sender != null
            ? await sender(request)
            : await (client = _clientFactory()).send(request);
        return http.Response.fromStream(streamed);
      })().timeout(timeout);
      final payload = _decodeObject(response.bodyBytes);
      if (response.statusCode != 200 && response.statusCode != 201) {
        throw ExternalImagePushException(
          _errorMessage(
            payload,
            response.statusCode,
          ).replaceAll(bearer, '[已隐藏]'),
          statusCode: response.statusCode,
        );
      }
      final id = payload?['id'];
      if (id is! String || id.isEmpty) {
        throw const ExternalImagePushException('云存储返回格式异常');
      }
      return ExternalImagePushReceipt(
        id: id,
        deduplicated: payload?['deduplicated'] == true,
      );
    } on TimeoutException {
      throw const ExternalImagePushException('上传超时,请检查网络后重试');
    } on ExternalImagePushException {
      rethrow;
    } catch (_) {
      // Do not surface lower-level errors: some HTTP clients include request
      // details in them, and this request carries a Bearer credential.
      throw const ExternalImagePushException('上传失败,请检查 API 地址与网络');
    } finally {
      client?.close();
    }
  }

  static Map<String, dynamic>? _decodeObject(List<int> bytes) {
    try {
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is Map) {
        return {
          for (final entry in decoded.entries)
            if (entry.key is String) entry.key as String: entry.value,
        };
      }
    } catch (_) {}
    return null;
  }

  static String _errorMessage(Map<String, dynamic>? payload, int statusCode) {
    final error = payload?['error'];
    if (error is Map && error['message'] is String) {
      final message = (error['message'] as String).trim();
      if (message.isNotEmpty) return message;
    }
    return switch (statusCode) {
      401 => '云存储 Token 无效或已撤销',
      400 => '云存储拒绝了图片或来源信息',
      _ => '云存储请求失败($statusCode)',
    };
  }
}
