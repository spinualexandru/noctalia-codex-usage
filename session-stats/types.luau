--!strict

-- Types for the JSONL records stored under ~/.codex/sessions.
--
-- The persisted wire format comes from RolloutLine and RolloutItem in
-- codex-rs/protocol. Optional fields account for both serde omissions and
-- older records that predate newer protocol fields.

export type IsoTimestamp = string
export type ThreadId = string
export type SessionId = string
export type TurnId = string
export type CallId = string
export type AbsolutePath = string

export type ReasoningEffort =
  "none" | "minimal" | "low" | "medium" | "high" | "xhigh" | "max" | "ultra" | string
export type ReasoningSummary = "auto" | "concise" | "detailed" | "none"
export type Personality = "none" | "friendly" | "pragmatic"
export type ModeKind = "default" | "plan"
export type MultiAgentVersion = "disabled" | "v1" | "v2"
export type MessagePhase = "commentary" | "final_answer"

export type BaseInstructions = {
  text: string,
}

export type GitInfo = {
  commit_hash: string?,
  branch: string?,
  repository_url: string?,
}

export type HistoryPosition = {
  thread_id: ThreadId,
  end_ordinal_exclusive: number,
  end_byte_offset: number,
}

export type ContextWindow = {
  window_id: string,
}

export type CapabilityRootLocation = {
  type: "environment",
  environmentId: string,
  path: string,
}

export type SelectedCapabilityRoot = {
  id: string,
  location: CapabilityRootLocation,
}

export type SubAgentSource =
  "review"
  | "compact"
  | "memory_consolidation"
  | {
      thread_spawn: {
        parent_thread_id: ThreadId,
        depth: number,
        agent_path: string?,
        agent_nickname: string?,
        agent_role: string?,
      },
    }
  | { other: string }

-- Simple variants serialize as strings. Data-carrying variants use serde's
-- externally tagged object representation.
export type SessionSource =
  "cli"
  | "vscode"
  | "exec"
  | "mcp"
  | "unknown"
  | { custom: string }
  | { internal: "memory_consolidation" }
  | { subagent: SubAgentSource }

-- Feature sources are open-ended strings in the Rust protocol.
export type ThreadSource = "user" | "subagent" | "memory_consolidation" | string
export type ThreadHistoryMode = "legacy" | "paginated"

export type SessionMetaPayload = {
  -- Older rollouts only contain id; Codex treats it as session_id on load.
  session_id: SessionId?,
  id: ThreadId,
  forked_from_id: ThreadId?,
  parent_thread_id: ThreadId?,
  timestamp: IsoTimestamp,
  cwd: AbsolutePath,
  originator: string,
  cli_version: string,
  source: SessionSource?,
  thread_source: ThreadSource?,
  agent_nickname: string?,
  agent_role: string?,
  agent_path: string?,
  model_provider: string?,
  base_instructions: BaseInstructions?,
  dynamic_tools: { unknown }?,
  selected_capability_roots: { SelectedCapabilityRoot }?,
  memory_mode: string?,
  history_mode: ThreadHistoryMode?,
  history_base: HistoryPosition?,
  subagent_history_start_ordinal: number?,
  multi_agent_version: MultiAgentVersion?,
  context_window: ContextWindow?,
  git: GitInfo?,
}

export type InternalMessageMetadata = {
  turn_id: TurnId?,
}

export type InputTextContent = {
  type: "input_text",
  text: string,
}

export type InputImageContent = {
  type: "input_image",
  image_url: string,
  detail: ("auto" | "low" | "high" | "original")?,
}

export type InputAudioContent = {
  type: "input_audio",
  audio_url: string,
}

export type OutputTextContent = {
  type: "output_text",
  text: string,
}

export type ContentItem = InputTextContent | InputImageContent | InputAudioContent | OutputTextContent

export type PlaintextAgentContent = {
  type: "input_text",
  text: string,
}

export type EncryptedAgentContent = {
  type: "encrypted_content",
  encrypted_content: string,
}

export type AgentContentItem = PlaintextAgentContent | EncryptedAgentContent

export type ReasoningSummaryItem = {
  type: "summary_text",
  text: string,
}

export type ReasoningContentItem = {
  type: "reasoning_text" | "text",
  text: string,
}

export type MessageResponseItem = {
  type: "message",
  id: string?,
  role: string,
  content: { ContentItem },
  phase: MessagePhase?,
  internal_chat_message_metadata_passthrough: InternalMessageMetadata?,
}

export type AgentMessageResponseItem = {
  type: "agent_message",
  id: string?,
  author: string,
  recipient: string,
  content: { AgentContentItem },
  internal_chat_message_metadata_passthrough: InternalMessageMetadata?,
}

export type ReasoningResponseItem = {
  type: "reasoning",
  id: string?,
  summary: { ReasoningSummaryItem },
  content: { ReasoningContentItem }?,
  encrypted_content: string?,
  internal_chat_message_metadata_passthrough: InternalMessageMetadata?,
}

export type FunctionCallResponseItem = {
  type: "function_call",
  id: string?,
  name: string,
  namespace: string?,
  -- JSON encoded as a string by the Responses API.
  arguments: string,
  call_id: CallId,
  internal_chat_message_metadata_passthrough: InternalMessageMetadata?,
}

export type EncryptedToolOutputContent = {
  type: "encrypted_content",
  encrypted_content: string,
}

export type FunctionCallOutputContentItem =
  InputTextContent | InputImageContent | InputAudioContent | EncryptedToolOutputContent

export type FunctionCallOutput = string | { FunctionCallOutputContentItem }

export type FunctionCallOutputResponseItem = {
  type: "function_call_output",
  id: string?,
  call_id: CallId,
  output: FunctionCallOutput,
  internal_chat_message_metadata_passthrough: InternalMessageMetadata?,
}

export type CustomToolCallResponseItem = {
  type: "custom_tool_call",
  id: string?,
  status: string?,
  call_id: CallId,
  name: string,
  namespace: string?,
  input: string,
  internal_chat_message_metadata_passthrough: InternalMessageMetadata?,
}

export type CustomToolCallOutputResponseItem = {
  type: "custom_tool_call_output",
  id: string?,
  call_id: CallId,
  name: string?,
  output: FunctionCallOutput,
  internal_chat_message_metadata_passthrough: InternalMessageMetadata?,
}

export type ToolSearchCallResponseItem = {
  type: "tool_search_call",
  id: string?,
  call_id: CallId?,
  status: string?,
  execution: string,
  arguments: unknown,
  internal_chat_message_metadata_passthrough: InternalMessageMetadata?,
}

export type ToolSearchOutputResponseItem = {
  type: "tool_search_output",
  id: string?,
  call_id: CallId?,
  status: string,
  execution: string,
  tools: { unknown },
  internal_chat_message_metadata_passthrough: InternalMessageMetadata?,
}

export type LocalShellCallResponseItem = {
  type: "local_shell_call",
  id: string?,
  call_id: CallId?,
  status: string,
  action: unknown,
  internal_chat_message_metadata_passthrough: InternalMessageMetadata?,
}

export type WebSearchCallResponseItem = {
  type: "web_search_call",
  id: string?,
  status: string?,
  action: unknown?,
  internal_chat_message_metadata_passthrough: InternalMessageMetadata?,
}

export type ImageGenerationCallResponseItem = {
  type: "image_generation_call",
  id: string?,
  status: string,
  revised_prompt: string?,
  result: string,
  internal_chat_message_metadata_passthrough: InternalMessageMetadata?,
}

export type CompactionResponseItem = {
  type: "compaction" | "compaction_summary",
  id: string?,
  encrypted_content: string,
  internal_chat_message_metadata_passthrough: InternalMessageMetadata?,
}

export type ContextCompactionResponseItem = {
  type: "context_compaction",
  id: string?,
  encrypted_content: string?,
  internal_chat_message_metadata_passthrough: InternalMessageMetadata?,
}

export type CompactionTriggerResponseItem = {
  type: "compaction_trigger",
}

export type ResponseItem =
  MessageResponseItem
  | AgentMessageResponseItem
  | ReasoningResponseItem
  | FunctionCallResponseItem
  | FunctionCallOutputResponseItem
  | CustomToolCallResponseItem
  | CustomToolCallOutputResponseItem
  | ToolSearchCallResponseItem
  | ToolSearchOutputResponseItem
  | LocalShellCallResponseItem
  | WebSearchCallResponseItem
  | ImageGenerationCallResponseItem
  | CompactionResponseItem
  | ContextCompactionResponseItem
  | CompactionTriggerResponseItem

export type InterAgentCommunicationPayload = {
  id: string?,
  author: string,
  recipient: string,
  other_recipients: { string }?,
  content: string,
  encrypted_content: string?,
  internal_chat_message_metadata_passthrough: InternalMessageMetadata?,
  trigger_turn: boolean,
}

export type InterAgentCommunicationMetadataPayload = {
  trigger_turn: boolean,
}

export type CompactedPayload = {
  message: string,
  replacement_history: { ResponseItem }?,
  window_number: number?,
  first_window_id: string?,
  previous_window_id: string?,
  window_id: string?,
}

export type GranularApproval = {
  granular: {
    sandbox_approval: boolean,
    rules: boolean,
    skill_approval: boolean?,
    request_permissions: boolean?,
    mcp_elicitations: boolean,
  },
}

export type ApprovalPolicy = "untrusted" | "on-request" | "on-failure" | "never" | GranularApproval

export type CollaborationMode = {
  mode: ModeKind,
  settings: {
    model: string,
    reasoning_effort: ReasoningEffort?,
    developer_instructions: string?,
  },
}

-- Permission and sandbox structures are intentionally open here. They are
-- useful session metadata, but their nested schema changes independently of
-- the statistics fields (model, effort, timing, and usage).
export type TaggedPolicy = {
  type: string,
  [string]: unknown,
}

export type TurnContextPayload = {
  turn_id: TurnId?,
  cwd: AbsolutePath,
  workspace_roots: { AbsolutePath }?,
  current_date: string?,
  timezone: string?,
  approval_policy: ApprovalPolicy,
  approvals_reviewer: string?,
  sandbox_policy: TaggedPolicy,
  permission_profile: TaggedPolicy?,
  network: {
    allowed_domains: { string },
    denied_domains: { string },
  }?,
  file_system_sandbox_policy: {
    kind: string,
    entries: { unknown },
    [string]: unknown,
  }?,
  model: string,
  comp_hash: string?,
  personality: Personality?,
  collaboration_mode: CollaborationMode?,
  multi_agent_version: MultiAgentVersion?,
  multi_agent_mode: string | { custom: string }?,
  realtime_active: boolean?,
  effort: ReasoningEffort?,
  summary: ReasoningSummary,
}

export type WorldStatePayload = {
  full: boolean,
  state: unknown,
}

export type TokenUsage = {
  input_tokens: number,
  cached_input_tokens: number,
  -- Added after the older records in the local corpus were written.
  cache_write_input_tokens: number?,
  output_tokens: number,
  reasoning_output_tokens: number,
  total_tokens: number,
}

export type TokenUsageInfo = {
  total_token_usage: TokenUsage,
  last_token_usage: TokenUsage,
  model_context_window: number?,
}

export type RateLimitWindow = {
  used_percent: number,
  window_minutes: number?,
  resets_at: number?,
}

export type CreditsSnapshot = {
  has_credits: boolean,
  unlimited: boolean,
  balance: string?,
}

export type RateLimitSnapshot = {
  limit_id: string?,
  limit_name: string?,
  primary: RateLimitWindow?,
  secondary: RateLimitWindow?,
  credits: CreditsSnapshot?,
  individual_limit: unknown?,
  spend_control_reached: boolean?,
  plan_type: string?,
  rate_limit_reached_type: string?,
}

export type TokenCountEvent = {
  type: "token_count",
  info: TokenUsageInfo?,
  rate_limits: RateLimitSnapshot?,
}

export type TurnStartedEvent = {
  -- Persisted under the legacy v1 name.
  type: "task_started" | "turn_started",
  turn_id: TurnId,
  trace_id: string?,
  started_at: number?,
  model_context_window: number?,
  collaboration_mode_kind: ModeKind,
}

export type ErrorEvent = {
  message: string,
  codex_error_info: unknown?,
}

export type TurnCompleteEvent = {
  type: "task_complete" | "turn_complete",
  turn_id: TurnId,
  last_agent_message: string?,
  error: ErrorEvent?,
  started_at: number?,
  completed_at: number?,
  duration_ms: number?,
  time_to_first_token_ms: number?,
}

export type TurnAbortedEvent = {
  type: "turn_aborted",
  turn_id: TurnId?,
  reason: "interrupted" | "replaced" | "review_ended" | "budget_limited",
  started_at: number?,
  completed_at: number?,
  duration_ms: number?,
}

export type AgentMessageEvent = {
  type: "agent_message",
  message: string,
  phase: MessagePhase?,
  memory_citation: {
    entries: {
      {
        path: string,
        lineStart: number,
        lineEnd: number,
        note: string,
      }
    },
    rolloutIds: { string },
  }?,
}

export type UserMessageEvent = {
  type: "user_message",
  client_id: string?,
  message: string,
  images: { string }?,
  image_details: { ("auto" | "low" | "high" | "original")? }?,
  local_images: { AbsolutePath },
  local_image_details: { ("auto" | "low" | "high" | "original")? }?,
  audio: { string }?,
  local_audio: { AbsolutePath }?,
  text_elements: { unknown },
}

export type AgentReasoningEvent = {
  type: "agent_reasoning",
  text: string,
}

export type ContextCompactedEvent = {
  type: "context_compacted",
}

export type ThreadRolledBackEvent = {
  type: "thread_rolled_back",
  num_turns: number,
}

export type ThreadSettings = {
  model: string,
  model_provider_id: string,
  service_tier: string?,
  approval_policy: ApprovalPolicy,
  approvals_reviewer: string,
  permission_profile: TaggedPolicy,
  active_permission_profile: unknown?,
  cwd: AbsolutePath,
  reasoning_effort: ReasoningEffort?,
  reasoning_summary: ReasoningSummary?,
  personality: Personality?,
  collaboration_mode: CollaborationMode,
}

export type ThreadSettingsAppliedEvent = {
  type: "thread_settings_applied",
  thread_settings: ThreadSettings,
}

export type FileChange =
  { type: "add", content: string }
  | { type: "delete", content: string }
  | { type: "update", unified_diff: string, move_path: AbsolutePath? }

export type PatchApplyEndEvent = {
  type: "patch_apply_end",
  call_id: CallId,
  turn_id: TurnId,
  stdout: string,
  stderr: string,
  success: boolean,
  changes: { [string]: FileChange },
  status: "completed" | "failed" | "declined",
}

export type WebSearchAction =
  { type: "search", query: string?, queries: { string }? }
  | { type: "open_page", url: string }
  | { type: "find_in_page", pattern: string }
  | { type: "other" }

export type WebSearchEndEvent = {
  type: "web_search_end",
  call_id: CallId,
  query: string,
  action: WebSearchAction,
  results: { unknown }?,
}

export type ImageGenerationEndEvent = {
  type: "image_generation_end",
  call_id: CallId,
  status: string,
  revised_prompt: string?,
  result: string,
  saved_path: AbsolutePath?,
}

export type McpInvocation = {
  server: string,
  tool: string,
  arguments: unknown?,
}

export type McpToolCallEndEvent = {
  type: "mcp_tool_call_end",
  call_id: CallId,
  invocation: McpInvocation,
  connector_id: string?,
  mcp_app_resource_uri: string?,
  link_id: string?,
  app_name: string?,
  action_name: string?,
  plugin_id: string?,
  duration: string | { secs: number, nanos: number },
  -- Rust's Result serializes as either { Ok = value } or { Err = string }.
  result: { Ok: unknown } | { Err: string },
}

export type PlanTurnItem = {
  type: "Plan",
  id: string,
  text: string,
}

export type ItemCompletedEvent = {
  type: "item_completed",
  thread_id: ThreadId,
  turn_id: TurnId,
  item: PlanTurnItem | { type: string, [string]: unknown },
  completed_at_ms: number,
}

export type SubAgentActivityEvent = {
  type: "sub_agent_activity",
  event_id: string,
  occurred_at_ms: number,
  agent_thread_id: ThreadId,
  agent_path: string,
  kind: "started" | "interacted" | "interrupted",
}

export type ThreadGoal = {
  threadId: ThreadId,
  objective: string,
  status: "active" | "paused" | "blocked" | "usageLimited" | "budgetLimited" | "complete",
  tokenBudget: number?,
  tokensUsed: number,
  timeUsedSeconds: number,
  createdAt: number,
  updatedAt: number,
}

export type ThreadGoalUpdatedEvent = {
  type: "thread_goal_updated",
  threadId: ThreadId,
  turnId: TurnId?,
  goal: ThreadGoal,
}

-- Event variants found in the local session corpus on 2026-07-23.
export type ObservedEventPayload =
  TokenCountEvent
  | TurnStartedEvent
  | TurnCompleteEvent
  | TurnAbortedEvent
  | AgentMessageEvent
  | UserMessageEvent
  | AgentReasoningEvent
  | ContextCompactedEvent
  | ThreadRolledBackEvent
  | ThreadSettingsAppliedEvent
  | PatchApplyEndEvent
  | WebSearchEndEvent
  | ImageGenerationEndEvent
  | McpToolCallEndEvent
  | ItemCompletedEvent
  | SubAgentActivityEvent
  | ThreadGoalUpdatedEvent

export type EventPayload = ObservedEventPayload

-- Decode untrusted JSON as unknown first. This fallback is available for a
-- reader that deliberately preserves EventMsg variants not yet observed,
-- while EventPayload remains narrow enough for discriminator-based narrowing.
export type UnknownEventPayload = {
  type: string,
  [string]: unknown,
}

export type AnyEventPayload = EventPayload | UnknownEventPayload

type RolloutLineBase = {
  timestamp: IsoTimestamp,
  ordinal: number?,
}

export type SessionMetaLine = RolloutLineBase & {
  type: "session_meta",
  payload: SessionMetaPayload,
}

export type ResponseItemLine = RolloutLineBase & {
  type: "response_item",
  payload: ResponseItem,
}

export type InterAgentCommunicationLine = RolloutLineBase & {
  type: "inter_agent_communication",
  payload: InterAgentCommunicationPayload,
}

export type InterAgentCommunicationMetadataLine = RolloutLineBase & {
  type: "inter_agent_communication_metadata",
  payload: InterAgentCommunicationMetadataPayload,
}

export type CompactedLine = RolloutLineBase & {
  type: "compacted",
  payload: CompactedPayload,
}

export type TurnContextLine = RolloutLineBase & {
  type: "turn_context",
  payload: TurnContextPayload,
}

export type WorldStateLine = RolloutLineBase & {
  type: "world_state",
  payload: WorldStatePayload,
}

export type EventLine = RolloutLineBase & {
  type: "event_msg",
  payload: EventPayload,
}

export type RolloutLine =
  SessionMetaLine
  | ResponseItemLine
  | InterAgentCommunicationLine
  | InterAgentCommunicationMetadataLine
  | CompactedLine
  | TurnContextLine
  | WorldStateLine
  | EventLine

-- A session file is JSONL, so readers build this array by decoding each line;
-- the file itself is not encoded as one JSON array.
export type SessionFile = { RolloutLine }

return {}
