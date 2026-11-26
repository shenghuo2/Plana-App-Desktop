import '../agent_trace.dart';
import '../custom_endpoint.dart' show CustomEndpoint;
import '../domain/agent_event.dart';
import '../domain/turn_request.dart';
import '../llm/http_provider.dart' show llmProviderFor;
import '../llm/plana_channel_provider.dart';
import '../subscription/plan_runtime.dart';
import '../tools/tool_context.dart' show OnlineTags, TagLookup;
import 'local_runtime.dart';

/// 跑一轮 AI 对话。事件序列见 [AgentEvent]:中间若干工具 / 增量事件,最后一个必是
/// [AgentDone];失败以 [AgentFailure] 结束流。只有 listen 之后才发请求。
abstract interface class AgentRuntime {
  /// 调试记录中的 Bot 后端、自定义接口或 ChatGPT 订阅路线。
  String get route;

  /// [trace] 由 runtime 填系统提示、消息、每一跳这些只有它看得见的细节。
  Stream<AgentEvent> run(AgentTurnRequest request, {AgentTrace? trace});
}

/// ChatGPT 订阅由 [PlanRuntime] 直连 OpenAI。自定义接口和 Bot 后端由
/// [LocalAgentRuntime] 运行，各自使用所选服务商或 [backendModel] 指定的渠道。
AgentRuntime agentRuntimeFor({
  required CustomEndpoint? endpoint,
  required String backendBase,
  required String sessionId,
  required String backendModel,
  required String imageModel,
  TagLookup? offline,
  OnlineTags? online,
}) => endpoint is PlanEndpoint
    ? PlanRuntime(endpoint)
    : LocalAgentRuntime(
        provider: endpoint != null
            ? llmProviderFor(endpoint)
            : PlanaChannelProvider(
                baseUrl: backendBase,
                sessionId: sessionId,
                model: backendModel,
                imageModel: imageModel,
              ),
        route: endpoint != null
            ? AgentTrace.routeCustom
            : AgentTrace.routeBackend,
        offline: offline,
        online: online,
      );
