export '../../../core/net/agent_stream.dart'
    show AgentEvent, AgentToolCall, AgentToolResult, AgentDelta, AgentDone;

/// 一轮失败。[message] 是原始错误内容(上游状态码 + 原文、异常原文),界面原样显示。
class AgentFailure implements Exception {
  AgentFailure(this.message, {this.status, this.retryable = true});

  /// HTTP 状态码 + 响应原文。原文过长时截断,免得一整页 HTML 进对话存档。
  factory AgentFailure.http(int status, String body, {bool retryable = true}) {
    final text = body.trim();
    return AgentFailure(
      text.isEmpty
          ? 'HTTP $status'
          : 'HTTP $status\n${text.length > kMaxBody ? '${text.substring(0, kMaxBody)}…' : text}',
      status: status,
      retryable: retryable,
    );
  }

  /// 响应原文最多留这么多字。
  static const kMaxBody = 4000;

  final String message;
  final int? status;

  /// 降级重试有没有用。后端已经重掷过的拒绝、后端自己拒掉的请求为 false。
  final bool retryable;

  @override
  String toString() => message;
}

/// Older Plana servers only expose the prompt stream route.
class AgentChannelUnavailable extends AgentFailure {
  AgentChannelUnavailable(int code, super.message)
    : super(status: code, retryable: false);
}
