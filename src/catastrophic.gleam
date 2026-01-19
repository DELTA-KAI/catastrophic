// SANS-IO Anthropic API client for Gleam.
//
// This package provides a SANS-IO (Sans I/O) implementation of the Anthropic API client.
// Following the SANS-IO pattern, this library separates I/O operations from protocol logic,
// making it easier to test and compose with different HTTP clients.

import castor
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode.{type DecodeError, type Decoder}
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

// ---- Configuration ----

/// Configuration for the Anthropic API client.
pub type Config {
  Config(
    /// Anthropic API key
    api_key: String,
    /// API version (defaults to "2023-06-01")
    api_version: String,
    /// Base URL for the API (defaults to "https://api.anthropic.com")
    base_url: String,
  )
}

/// Create a new configuration with default values.
///
/// Creates a configuration object for the Anthropic API with standard defaults:
/// - API version: "2023-06-01"
/// - Base URL: "https://api.anthropic.com"
///
/// ## Parameters
///
/// - `api_key`: Your Anthropic API key. Get one from https://console.anthropic.com/
///
/// ## Example
///
/// ```gleam
/// let config = catastrophic.default_config("sk-ant-api03-...")
/// ```
pub fn default_config(api_key: String) -> Config {
  Config(
    api_key: api_key,
    api_version: "2023-06-01",
    base_url: "https://api.anthropic.com",
  )
}

/// Set a custom API version on the configuration.
///
/// Override the default API version if you need to use a specific version
/// of the Anthropic API.
///
/// ## Parameters
///
/// - `config`: The configuration to modify
/// - `version`: The API version string (e.g., "2023-06-01")
///
/// ## Example
///
/// ```gleam
/// let config = catastrophic.default_config("sk-ant-api03-...")
///   |> catastrophic.api_version("2024-01-01")
/// ```
pub fn api_version(config: Config, version: String) -> Config {
  Config(..config, api_version: version)
}

/// Set a custom base URL on the configuration.
///
/// Override the default base URL if you're using a proxy or custom endpoint.
///
/// ## Parameters
///
/// - `config`: The configuration to modify
/// - `url`: The base URL (e.g., "https://api.anthropic.com")
///
/// ## Example
///
/// ```gleam
/// let config = catastrophic.default_config("sk-ant-api03-...")
///   |> catastrophic.url("https://my-proxy.com")
/// ```
pub fn url(config: Config, url: String) -> Config {
  Config(..config, base_url: url)
}

// ---- Error Types ----

/// Errors that can occur when interacting with the Anthropic API.
pub type Error {
  /// Error decoding JSON response
  JsonDecodeError(json.DecodeError)
  /// HTTP error response from the API
  ApiError(status: Int, message: String, error_type: String)
  /// Invalid request parameters
  InvalidRequest(String)
  /// Missing required API key
  MissingApiKey
}

/// Error response from the Anthropic API
type ApiErrorResponse {
  ApiErrorResponse(error_type: String, message: String)
}

/// Convert an error to a human-readable string
pub fn describe_error(error: Error) -> String {
  case error {
    JsonDecodeError(json_error) ->
      "JSON decode error: " <> describe_json_error(json_error)
    ApiError(status, message, error_type) ->
      "API error (status "
      <> int.to_string(status)
      <> ", type: "
      <> error_type
      <> "): "
      <> message
    InvalidRequest(msg) -> "Invalid request: " <> msg
    MissingApiKey ->
      "Missing API key. Please provide a valid Anthropic API key."
  }
}

fn describe_json_error(error: json.DecodeError) -> String {
  case error {
    json.UnexpectedEndOfInput -> "Unexpected end of input"
    json.UnexpectedByte(byte) -> "Unexpected byte: " <> byte
    json.UnexpectedSequence(seq) -> "Unexpected sequence: " <> seq
    json.UnableToDecode(errors) -> {
      let count = list.length(errors)
      "Unable to decode: " <> int.to_string(count) <> " error(s)"
    }
  }
}

fn decode_api_error(
  data: Dynamic,
) -> Result(ApiErrorResponse, List(DecodeError)) {
  let error_object_decoder = {
    use error_type <- decode.field("type", decode.string)
    use message <- decode.field("message", decode.string)
    decode.success(ApiErrorResponse(error_type: error_type, message: message))
  }

  let decoder = {
    use error_obj <- decode.field("error", error_object_decoder)
    decode.success(error_obj)
  }

  decode.run(data, decoder)
}

// ---- Message Types ----

/// A role in a conversation.
///
/// Represents who sent a message in the conversation history.
pub type Role {
  /// Messages sent by the user/human
  User
  /// Messages sent by Claude/assistant
  Assistant
}

/// Content block in a message.
///
/// Messages can contain different types of content including text, images,
/// tool use requests, and tool results.
pub type ContentBlock {
  /// Text content
  ///
  /// ## Fields
  /// - `text`: The text content of the message
  TextBlock(text: String)

  /// Image content (base64 encoded)
  ///
  /// ## Fields
  /// - `source`: Image data and metadata
  ImageBlock(source: ImageSource)

  /// Tool use request from the assistant
  ///
  /// When Claude wants to use a tool, it returns this block with the tool name
  /// and input parameters.
  ///
  /// ## Fields
  /// - `id`: Unique identifier for this tool use (e.g., "toolu_123")
  /// - `name`: Name of the tool to use
  /// - `input`: Tool input parameters as JSON
  ToolUseBlock(id: String, name: String, input: Json)

  /// Tool result from the user
  ///
  /// Send this block to provide the results of executing a tool back to Claude.
  ///
  /// ## Fields
  /// - `tool_use_id`: ID of the tool use this is responding to
  /// - `content`: Result content (typically JSON string)
  /// - `is_error`: Whether this result represents an error
  ToolResultBlock(tool_use_id: String, content: String, is_error: Bool)
}

/// Image source configuration.
///
/// Defines how image data is provided to Claude.
pub type ImageSource {
  /// Base64 encoded image data
  ///
  /// ## Fields
  /// - `media_type`: MIME type (e.g., "image/png", "image/jpeg")
  /// - `data`: Base64 encoded image data
  Base64Image(media_type: String, data: String)
}

/// A message in the conversation.
///
/// Represents a single turn in the conversation, containing the role
/// and a list of content blocks.
///
/// ## Fields
/// - `role`: Who sent this message (User or Assistant)
/// - `content`: List of content blocks in the message
pub type Message {
  Message(role: Role, content: List(ContentBlock))
}

/// Stop reason for message completion.
///
/// Indicates why Claude stopped generating.
pub type StopReason {
  /// Claude decided the conversation turn is complete
  EndTurn
  /// Hit the maximum token limit
  MaxTokens
  /// Encountered a stop sequence
  StopSequence
  /// Claude wants to use a tool
  ToolUse
}

/// Usage information for the API request.
///
/// Token counts for billing and rate limiting purposes.
///
/// ## Fields
/// - `input_tokens`: Number of tokens in the input
/// - `output_tokens`: Number of tokens in the output
pub type Usage {
  Usage(input_tokens: Int, output_tokens: Int)
}

/// Response from the Messages API.
///
/// The complete response from creating a message, including the generated
/// content and metadata.
///
/// ## Fields
/// - `id`: Unique identifier for this message (e.g., "msg_123")
/// - `model`: Model that generated this response
/// - `role`: Always Assistant for responses
/// - `content`: List of content blocks in the response
/// - `stop_reason`: Why Claude stopped generating
/// - `usage`: Token usage information
pub type MessageResponse {
  MessageResponse(
    id: String,
    model: String,
    role: Role,
    content: List(ContentBlock),
    stop_reason: Option(StopReason),
    usage: Usage,
  )
}

/// Request to create a message.
///
/// Contains all parameters for creating a message with Claude.
///
/// ## Fields
/// - `model`: Model identifier (e.g., "claude-3-5-sonnet-20241022")
/// - `messages`: Conversation history (must alternate user/assistant roles)
/// - `max_tokens`: Maximum number of tokens to generate (required)
/// - `system`: System prompt to guide Claude's behavior (optional)
/// - `temperature`: Randomness (0.0-1.0, higher = more random) (optional)
/// - `top_p`: Nucleus sampling threshold (optional)
/// - `top_k`: Top-k sampling parameter (optional)
/// - `stop_sequences`: Sequences that stop generation (optional)
/// - `tools`: Tools Claude can use (optional)
pub type CreateMessageRequest {
  CreateMessageRequest(
    model: String,
    messages: List(Message),
    max_tokens: Int,
    system: Option(String),
    temperature: Option(Float),
    top_p: Option(Float),
    top_k: Option(Int),
    stop_sequences: Option(List(String)),
    tools: Option(List(Tool)),
  )
}

// ---- Tool Use Types ----

/// A tool (function) that the model can use.
///
/// Tools allow Claude to interact with external systems and APIs.
/// Define tools with type-safe JSON schemas using the castor package.
///
/// ## Fields
/// - `name`: Tool identifier (must match [a-zA-Z0-9_-]+)
/// - `description`: What the tool does (helps Claude decide when to use it)
/// - `input_schema`: JSON schema for input parameters (castor.Schema)
///
/// ## Example
///
/// ```gleam
/// import castor
///
/// let weather_tool = catastrophic.Tool(
///   name: "get_weather",
///   description: "Get current weather for a location",
///   input_schema: castor.object([
///     castor.field("location", castor.string()),
///     castor.field("unit", castor.string()),
///   ]),
/// )
/// ```
pub type Tool {
  Tool(name: String, description: String, input_schema: castor.Schema)
}

/// Helper function to create a simple text message.
///
/// Convenience function for creating messages with just text content.
///
/// ## Parameters
///
/// - `role`: Who is sending the message (User or Assistant)
/// - `text`: The text content
///
/// ## Example
///
/// ```gleam
/// let user_msg = catastrophic.text_message(
///   catastrophic.User,
///   "Hello, Claude!"
/// )
/// ```
pub fn text_message(role: Role, text: String) -> Message {
  Message(role: role, content: [TextBlock(text)])
}

/// Helper function to create a tool result message.
///
/// After executing a tool, use this to send the results back to Claude.
/// The message role is automatically set to User.
///
/// ## Parameters
///
/// - `tool_use_id`: The ID from the ToolUseBlock you're responding to
/// - `content`: The result (typically JSON string)
/// - `is_error`: True if the tool execution failed
///
/// ## Example
///
/// ```gleam
/// let result_msg = catastrophic.tool_result_message(
///   "toolu_123",
///   "{\"temperature\": 72, \"condition\": \"sunny\"}",
///   False
/// )
/// ```
pub fn tool_result_message(
  tool_use_id: String,
  content: String,
  is_error: Bool,
) -> Message {
  Message(role: User, content: [
    ToolResultBlock(
      tool_use_id: tool_use_id,
      content: content,
      is_error: is_error,
    ),
  ])
}

/// Helper to build a simple tool with string parameters.
///
/// Creates a tool where all parameters are strings. For more complex parameter
/// types (numbers, booleans, nested objects), use castor directly to build
/// the schema.
///
/// ## Parameters
///
/// - `name`: Tool identifier (must match [a-zA-Z0-9_-]+)
/// - `description`: What the tool does
/// - `parameters`: List of (parameter_name, parameter_description) tuples
///
/// ## Example
///
/// ```gleam
/// let tool = catastrophic.simple_tool(
///   "get_weather",
///   "Get the current weather for a location",
///   [
///     #("location", "The city and state, e.g. San Francisco, CA"),
///     #("unit", "Temperature unit (celsius or fahrenheit)"),
///   ]
/// )
/// ```
pub fn simple_tool(
  name: String,
  description: String,
  parameters: List(#(String, String)),
) -> Tool {
  // Build fields using castor
  let fields =
    parameters
    |> list.map(fn(param) {
      let #(param_name, param_desc) = param
      castor.field(
        param_name,
        castor.String(
          max_length: None,
          min_length: None,
          pattern: None,
          format: None,
          nullable: False,
          title: None,
          description: Some(param_desc),
          deprecated: False,
        ),
      )
    })

  let schema = castor.object(fields)

  Tool(name: name, description: description, input_schema: schema)
}

// ---- JSON Encoding ----

fn role_to_string(role: Role) -> String {
  case role {
    User -> "user"
    Assistant -> "assistant"
  }
}

fn content_block_to_json(block: ContentBlock) -> json.Json {
  case block {
    TextBlock(text) ->
      json.object([
        #("type", json.string("text")),
        #("text", json.string(text)),
      ])
    ImageBlock(Base64Image(media_type, data)) ->
      json.object([
        #("type", json.string("image")),
        #(
          "source",
          json.object([
            #("type", json.string("base64")),
            #("media_type", json.string(media_type)),
            #("data", json.string(data)),
          ]),
        ),
      ])
    ToolUseBlock(id, name, input) ->
      json.object([
        #("type", json.string("tool_use")),
        #("id", json.string(id)),
        #("name", json.string(name)),
        #("input", input),
      ])
    ToolResultBlock(tool_use_id, content, is_error) -> {
      let base = [
        #("type", json.string("tool_result")),
        #("tool_use_id", json.string(tool_use_id)),
        #("content", json.string(content)),
      ]
      case is_error {
        True -> json.object(list.append(base, [#("is_error", json.bool(True))]))
        False -> json.object(base)
      }
    }
  }
}

/// Encode a message to JSON.
///
/// Converts a Message to its JSON representation. Useful for debugging,
/// logging, or custom serialization.
///
/// ## Parameters
///
/// - `message`: The message to encode
///
/// ## Returns
///
/// JSON representation of the message
pub fn message_to_json(message: Message) -> json.Json {
  json.object([
    #("role", json.string(role_to_string(message.role))),
    #("content", json.array(message.content, content_block_to_json)),
  ])
}

/// Encode a tool to JSON.
///
/// Converts a Tool definition to its JSON representation. Useful for debugging
/// or verifying tool schemas.
///
/// ## Parameters
///
/// - `tool`: The tool to encode
///
/// ## Returns
///
/// JSON representation of the tool with its schema
pub fn tool_to_json(tool: Tool) -> json.Json {
  // Convert castor schema to JSON
  let schema_json = castor.encode(tool.input_schema)

  json.object([
    #("name", json.string(tool.name)),
    #("description", json.string(tool.description)),
    #("input_schema", schema_json),
  ])
}

/// Encode a create message request to JSON.
///
/// Converts a CreateMessageRequest to its JSON representation. This is used
/// internally by `create_message` but exposed for debugging and custom use.
///
/// ## Parameters
///
/// - `request`: The request to encode
///
/// ## Returns
///
/// JSON representation of the request with all fields
pub fn create_message_request_to_json(
  request: CreateMessageRequest,
) -> json.Json {
  // Build base fields
  let base_fields = [
    #("model", json.string(request.model)),
    #("messages", json.array(request.messages, message_to_json)),
    #("max_tokens", json.int(request.max_tokens)),
  ]

  // Add optional fields
  let with_system = case request.system {
    Some(system) -> list.append(base_fields, [#("system", json.string(system))])
    None -> base_fields
  }

  let with_temperature = case request.temperature {
    Some(temp) -> list.append(with_system, [#("temperature", json.float(temp))])
    None -> with_system
  }

  let with_top_p = case request.top_p {
    Some(top_p) ->
      list.append(with_temperature, [#("top_p", json.float(top_p))])
    None -> with_temperature
  }

  let with_top_k = case request.top_k {
    Some(top_k) -> list.append(with_top_p, [#("top_k", json.int(top_k))])
    None -> with_top_p
  }

  let with_stop_sequences = case request.stop_sequences {
    Some(sequences) ->
      list.append(with_top_k, [
        #("stop_sequences", json.array(sequences, json.string)),
      ])
    None -> with_top_k
  }

  let with_tools = case request.tools {
    Some(tools) ->
      list.append(with_stop_sequences, [
        #("tools", json.array(tools, tool_to_json)),
      ])
    None -> with_stop_sequences
  }

  json.object(with_tools)
}

// ---- JSON Decoding ----

fn role_decoder() -> Decoder(Role) {
  use role_str <- decode.then(decode.string)
  case role_str {
    "user" -> decode.success(User)
    "assistant" -> decode.success(Assistant)
    _ -> decode.failure(User, expected: "Role")
  }
}

fn content_block_decoder() -> Decoder(ContentBlock) {
  use block_type <- decode.field("type", decode.string)
  case block_type {
    "text" -> {
      use text <- decode.field("text", decode.string)
      decode.success(TextBlock(text))
    }
    "tool_use" -> {
      use id <- decode.field("id", decode.string)
      use name <- decode.field("name", decode.string)
      use input <- decode.field(
        "input",
        decode.dynamic |> decode.map(dynamic_to_json),
      )
      decode.success(ToolUseBlock(id: id, name: name, input: input))
    }
    "tool_result" -> {
      use tool_use_id <- decode.field("tool_use_id", decode.string)
      use content <- decode.field("content", decode.string)
      use is_error <- decode.optional_field("is_error", False, decode.bool)
      decode.success(ToolResultBlock(
        tool_use_id: tool_use_id,
        content: content,
        is_error: is_error,
      ))
    }
    _ -> decode.failure(TextBlock(""), expected: "ContentBlock")
  }
}

// FFI to convert Dynamic (from JSON) to json.Json type
// Both Dynamic and Json have the same runtime representation
@external(erlang, "gleam@function", "identity")
@external(javascript, "../gleam_stdlib/gleam/function.mjs", "identity")
fn dynamic_to_json(d: Dynamic) -> Json

fn stop_reason_decoder() -> Decoder(StopReason) {
  use reason_str <- decode.then(decode.string)
  case reason_str {
    "end_turn" -> decode.success(EndTurn)
    "max_tokens" -> decode.success(MaxTokens)
    "stop_sequence" -> decode.success(StopSequence)
    "tool_use" -> decode.success(ToolUse)
    _ -> decode.failure(EndTurn, expected: "StopReason")
  }
}

fn usage_decoder() -> Decoder(Usage) {
  use input_tokens <- decode.field("input_tokens", decode.int)
  use output_tokens <- decode.field("output_tokens", decode.int)
  decode.success(Usage(input_tokens: input_tokens, output_tokens: output_tokens))
}

fn decode_message_response(
  data: Dynamic,
) -> Result(MessageResponse, List(DecodeError)) {
  let decoder = {
    use id <- decode.field("id", decode.string)
    use model <- decode.field("model", decode.string)
    use role <- decode.field("role", role_decoder())
    use content <- decode.field(
      "content",
      decode.list(of: content_block_decoder()),
    )
    use stop_reason <- decode.field(
      "stop_reason",
      decode.optional(stop_reason_decoder()),
    )
    use usage <- decode.field("usage", usage_decoder())
    decode.success(MessageResponse(
      id: id,
      model: model,
      role: role,
      content: content,
      stop_reason: stop_reason,
      usage: usage,
    ))
  }
  decode.run(data, decoder)
}

// ---- Request Building (SANS-IO) ----

/// Build an HTTP request to create a message.
///
/// This is a SANS-IO function - it only builds the HTTP request without
/// sending it. You're responsible for sending the request using your
/// preferred HTTP client.
///
/// ## Parameters
///
/// - `config`: API configuration with your API key
/// - `request_data`: The message request parameters
///
/// ## Returns
///
/// - `Ok(Request(String))`: The HTTP request ready to send
/// - `Error(MissingApiKey)`: If the API key is empty
/// - `Error(InvalidRequest)`: If the URL is invalid
///
/// ## Example
///
/// ```gleam
/// let config = catastrophic.default_config("sk-ant-api03-...")
/// let request = catastrophic.CreateMessageRequest(
///   model: "claude-3-5-sonnet-20241022",
///   messages: [catastrophic.text_message(catastrophic.User, "Hello!")],
///   max_tokens: 1024,
///   system: option.None,
///   temperature: option.None,
///   top_p: option.None,
///   top_k: option.None,
///   stop_sequences: option.None,
///   tools: option.None,
/// )
///
/// case catastrophic.create_message(config, request) {
///   Ok(http_request) -> {
///     // Send with your HTTP client (e.g., gleam_httpc)
///     todo
///   }
///   Error(e) -> todo
/// }
/// ```
pub fn create_message(
  config: Config,
  request_data: CreateMessageRequest,
) -> Result(Request(String), Error) {
  // Validate that we have an API key
  case config.api_key {
    "" -> Error(MissingApiKey)
    _ -> {
      // Encode the request to JSON
      let json_body =
        create_message_request_to_json(request_data)
        |> json.to_string

      // Build the HTTP request
      case request.to(config.base_url <> "/v1/messages") {
        Ok(req) ->
          Ok(
            req
            |> request.set_method(http.Post)
            |> request.set_header("content-type", "application/json")
            |> request.set_header("x-api-key", config.api_key)
            |> request.set_header("anthropic-version", config.api_version)
            |> request.set_body(json_body),
          )
        Error(_) -> Error(InvalidRequest("Invalid API URL"))
      }
    }
  }
}

// ---- Response Parsing (SANS-IO) ----

/// Parse a create message response from an HTTP response.
///
/// This is a SANS-IO function - it only parses the response without
/// performing any I/O. Feed it the HTTP response from your HTTP client.
///
/// ## Parameters
///
/// - `http_response`: The HTTP response with status and body
///
/// ## Returns
///
/// - `Ok(MessageResponse)`: Successfully parsed response from Claude
/// - `Error(JsonDecodeError)`: If the JSON is invalid or unexpected
/// - `Error(ApiError)`: If the API returned an error (4xx/5xx status)
///
/// ## Example
///
/// ```gleam
/// // After sending the request with your HTTP client
/// case http_client.send(http_request) {
///   Ok(http_response) -> {
///     case catastrophic.parse_create_message_response(http_response) {
///       Ok(response) -> {
///         // Use response.content, response.usage, etc.
///         todo
///       }
///       Error(catastrophic.ApiError(status, message, _)) -> {
///         // Handle API error
///         todo
///       }
///       Error(e) -> todo
///     }
///   }
///   Error(e) -> todo
/// }
/// ```
pub fn parse_create_message_response(
  http_response: Response(String),
) -> Result(MessageResponse, Error) {
  // Check HTTP status
  case http_response.status {
    200 -> {
      // Parse JSON body to dynamic, then decode
      case json.parse(http_response.body, using: decode.dynamic) {
        Ok(parsed_json) -> {
          case decode_message_response(parsed_json) {
            Ok(message_response) -> Ok(message_response)
            Error(decode_errors) ->
              Error(JsonDecodeError(json.UnableToDecode(decode_errors)))
          }
        }
        Error(json_error) -> Error(JsonDecodeError(json_error))
      }
    }
    // Handle error responses
    status -> {
      // Try to parse error response
      case json.parse(http_response.body, using: decode.dynamic) {
        Ok(parsed_json) -> {
          case decode_api_error(parsed_json) {
            Ok(api_error) ->
              Error(ApiError(
                status: status,
                message: api_error.message,
                error_type: api_error.error_type,
              ))
            Error(_) ->
              // If we can't decode the error, return a generic error
              Error(ApiError(
                status: status,
                message: http_response.body,
                error_type: "unknown",
              ))
          }
        }
        Error(_) ->
          // If we can't parse the JSON, return a generic error
          Error(ApiError(
            status: status,
            message: http_response.body,
            error_type: "unknown",
          ))
      }
    }
  }
}

// ---- Streaming Support (SANS-IO) ----

/// Events emitted during a streaming response.
///
/// When using `create_message_stream`, Claude sends Server-Sent Events (SSE)
/// that represent incremental updates. Parse these with `parse_sse_chunk`.
///
/// The most important event is `ContentBlockDelta` which contains the actual
/// text being generated incrementally.
pub type StreamEvent {
  /// Initial message metadata when stream starts
  ///
  /// Contains the message ID, model, role, and initial usage info
  MessageStart(MessageStartEvent)

  /// Start of a content block
  ///
  /// Indicates a new content block (text, tool use, etc.) is beginning
  ContentBlockStart(ContentBlockStartEvent)

  /// Incremental content update (delta)
  ///
  /// The main event - contains incremental text as Claude generates it.
  /// Print delta.delta.text to display streaming output.
  ContentBlockDelta(ContentBlockDeltaEvent)

  /// End of a content block
  ContentBlockStop(ContentBlockStopEvent)

  /// Message-level update
  ///
  /// Contains final stop_reason and usage information
  MessageDelta(MessageDeltaEvent)

  /// End of the message stream
  ///
  /// Signals that streaming is complete
  MessageStop(MessageStopEvent)

  /// Keep-alive ping event
  ///
  /// Sent periodically to keep the connection alive
  Ping

  /// Unknown event type (for forward compatibility)
  ///
  /// Events not recognized are preserved with their type and data
  UnknownEvent(event_type: String, data: String)
}

/// Message start event data.
///
/// Contains initial metadata about the message being generated.
///
/// ## Fields
/// - `message`: Initial MessageResponse (content will be empty initially)
pub type MessageStartEvent {
  MessageStartEvent(message: MessageResponse)
}

/// Content block start event data.
///
/// Signals the start of a new content block in the stream.
///
/// ## Fields
/// - `index`: Index of this content block (0-based)
/// - `content_block`: The content block that's starting
pub type ContentBlockStartEvent {
  ContentBlockStartEvent(index: Int, content_block: ContentBlock)
}

/// Content block delta event data (incremental update).
///
/// Contains the actual incremental content being generated.
///
/// ## Fields
/// - `index`: Index of the content block being updated
/// - `delta`: The incremental update (usually TextDelta with new text)
pub type ContentBlockDeltaEvent {
  ContentBlockDeltaEvent(index: Int, delta: ContentDelta)
}

/// Content delta types.
///
/// Different types of incremental updates that can occur.
pub type ContentDelta {
  /// Text content delta
  ///
  /// Contains incrementally generated text. Concatenate these to build
  /// the complete response.
  ///
  /// ## Fields
  /// - `text`: The new text chunk (e.g., "Hello", " world", "!")
  TextDelta(text: String)
}

/// Content block stop event data.
///
/// Signals the end of a content block.
///
/// ## Fields
/// - `index`: Index of the content block that finished
pub type ContentBlockStopEvent {
  ContentBlockStopEvent(index: Int)
}

/// Message delta event data.
///
/// Contains message-level updates like stop_reason and usage.
///
/// ## Fields
/// - `delta`: Changes to message-level fields
/// - `usage`: Token usage delta (optional)
pub type MessageDeltaEvent {
  MessageDeltaEvent(delta: MessageChanges, usage: Option(UsageDelta))
}

/// Message-level delta (changes to message).
///
/// ## Fields
/// - `stop_reason`: Why generation stopped (optional)
/// - `stop_sequence`: The stop sequence that was matched (optional)
pub type MessageChanges {
  MessageChanges(stop_reason: Option(StopReason), stop_sequence: Option(String))
}

/// Usage delta (token counts).
///
/// Incremental token usage information.
///
/// ## Fields
/// - `output_tokens`: Number of output tokens in this delta
pub type UsageDelta {
  UsageDelta(output_tokens: Int)
}

/// Message stop event data.
///
/// Signals that the message stream has completed. No additional data.
pub type MessageStopEvent {
  MessageStopEvent
}

/// Build an HTTP request to create a streaming message.
///
/// This is a SANS-IO function - it builds the HTTP request for streaming
/// without sending it. The request includes `stream: true` and sets the
/// Accept header to `text/event-stream`.
///
/// Use this instead of `create_message` when you want incremental responses
/// (Server-Sent Events).
///
/// ## Parameters
///
/// - `config`: API configuration with your API key
/// - `request_data`: The message request parameters
///
/// ## Returns
///
/// - `Ok(Request(String))`: The HTTP request ready to send to a streaming client
/// - `Error(MissingApiKey)`: If the API key is empty
/// - `Error(InvalidRequest)`: If the URL is invalid
///
/// ## Example
///
/// ```gleam
/// let config = catastrophic.default_config("sk-ant-api03-...")
/// let request = catastrophic.CreateMessageRequest(
///   model: "claude-3-5-sonnet-20241022",
///   messages: [catastrophic.text_message(catastrophic.User, "Write a haiku")],
///   max_tokens: 1024,
///   // ... other fields
/// )
///
/// case catastrophic.create_message_stream(config, request) {
///   Ok(http_request) -> {
///     // Send with your streaming HTTP client
///     // Parse chunks with parse_sse_chunk()
///     todo
///   }
///   Error(e) -> todo
/// }
/// ```
pub fn create_message_stream(
  config: Config,
  request_data: CreateMessageRequest,
) -> Result(Request(String), Error) {
  // Validate that we have an API key
  case config.api_key {
    "" -> Error(MissingApiKey)
    _ -> {
      // Encode the request to JSON with stream: true
      let json_body =
        create_message_request_to_json(request_data)
        |> json.to_string
        // Add stream: true to the JSON
        |> add_stream_field

      // Build the HTTP request
      case request.to(config.base_url <> "/v1/messages") {
        Ok(req) ->
          Ok(
            req
            |> request.set_method(http.Post)
            |> request.set_header("content-type", "application/json")
            |> request.set_header("x-api-key", config.api_key)
            |> request.set_header("anthropic-version", config.api_version)
            // Accept SSE events
            |> request.set_header("accept", "text/event-stream")
            |> request.set_body(json_body),
          )
        Error(_) -> Error(InvalidRequest("Invalid API URL"))
      }
    }
  }
}

// Helper to add stream: true to JSON
fn add_stream_field(json_str: String) -> String {
  // Insert "stream":true before the closing brace
  case string.ends_with(json_str, "}") {
    True -> {
      let without_brace = string.drop_end(json_str, 1)
      without_brace <> ",\"stream\":true}"
    }
    False -> json_str
  }
}

/// Parse Server-Sent Events (SSE) from a chunk of text.
///
/// This is a SANS-IO function - feed it text chunks from your HTTP client's
/// streaming response. It returns a list of parsed events. Incomplete events
/// at the end are ignored (they'll be completed in the next chunk).
///
/// The most important event to handle is `ContentBlockDelta` which contains
/// the incremental text being generated.
///
/// ## Parameters
///
/// - `chunk`: A chunk of SSE text from the stream
///
/// ## Returns
///
/// List of parsed StreamEvents (may be empty if chunk has no complete events)
///
/// ## Example
///
/// ```gleam
/// import gleam/io
///
/// // With your streaming HTTP client:
/// use chunk <- stream_reader.read()
/// let events = catastrophic.parse_sse_chunk(chunk)
/// 
/// list.each(events, fn(event) {
///   case event {
///     catastrophic.ContentBlockDelta(delta) -> {
///       // Print incremental text as it arrives
///       case delta.delta {
///         catastrophic.TextDelta(text) -> io.print(text)
///       }
///     }
///     catastrophic.MessageStop(_) -> {
///       io.println("\n[Stream complete]")
///     }
///     _ -> Nil
///   }
/// })
/// ```
pub fn parse_sse_chunk(chunk: String) -> List(StreamEvent) {
  chunk
  |> string.split("\n\n")
  |> list.filter_map(parse_sse_event)
}

/// Parse a single SSE event from text.
/// An SSE event consists of lines like:
/// ```
/// event: content_block_delta
/// data: {"type":"content_block_delta",...}
/// ```
fn parse_sse_event(event_text: String) -> Result(StreamEvent, Nil) {
  let lines =
    event_text
    |> string.trim
    |> string.split("\n")

  // Extract event type and data
  let event_type =
    lines
    |> list.find(string.starts_with(_, "event: "))
    |> result.map(string.drop_start(_, 7))
    |> result.unwrap("message_start")

  let data =
    lines
    |> list.find(string.starts_with(_, "data: "))
    |> result.map(string.drop_start(_, 6))

  case data {
    Ok(json_data) -> parse_event_data(event_type, json_data)
    Error(_) ->
      case event_type {
        "ping" -> Ok(Ping)
        _ -> Error(Nil)
      }
  }
}

/// Parse event data based on event type
fn parse_event_data(
  event_type: String,
  json_data: String,
) -> Result(StreamEvent, Nil) {
  case json.parse(json_data, using: decode.dynamic) {
    Ok(data) ->
      case event_type {
        "message_start" -> parse_message_start(data)
        "content_block_start" -> parse_content_block_start(data)
        "content_block_delta" -> parse_content_block_delta(data)
        "content_block_stop" -> parse_content_block_stop(data)
        "message_delta" -> parse_message_delta(data)
        "message_stop" -> Ok(MessageStop(MessageStopEvent))
        "ping" -> Ok(Ping)
        _ -> Ok(UnknownEvent(event_type: event_type, data: json_data))
      }
    Error(_) -> Error(Nil)
  }
}

// ---- Stream Event Decoders ----

fn parse_message_start(data: Dynamic) -> Result(StreamEvent, Nil) {
  let decoder = {
    use message_data <- decode.field("message", decode.dynamic)
    case decode_message_response(message_data) {
      Ok(message) ->
        decode.success(MessageStart(MessageStartEvent(message: message)))
      Error(_) ->
        decode.failure(
          MessageStart(
            MessageStartEvent(message: MessageResponse(
              id: "",
              model: "",
              role: Assistant,
              content: [],
              stop_reason: None,
              usage: Usage(input_tokens: 0, output_tokens: 0),
            )),
          ),
          expected: "MessageResponse",
        )
    }
  }
  decode.run(data, decoder)
  |> result.replace_error(Nil)
}

fn parse_content_block_start(data: Dynamic) -> Result(StreamEvent, Nil) {
  let decoder = {
    use index <- decode.field("index", decode.int)
    use content_block <- decode.field("content_block", content_block_decoder())
    decode.success(
      ContentBlockStart(ContentBlockStartEvent(
        index: index,
        content_block: content_block,
      )),
    )
  }
  decode.run(data, decoder)
  |> result.replace_error(Nil)
}

fn parse_content_block_delta(data: Dynamic) -> Result(StreamEvent, Nil) {
  let decoder = {
    use index <- decode.field("index", decode.int)
    use delta <- decode.field("delta", delta_decoder())
    decode.success(
      ContentBlockDelta(ContentBlockDeltaEvent(index: index, delta: delta)),
    )
  }
  decode.run(data, decoder)
  |> result.replace_error(Nil)
}

fn delta_decoder() -> Decoder(ContentDelta) {
  use delta_type <- decode.field("type", decode.string)
  case delta_type {
    "text_delta" -> {
      use text <- decode.field("text", decode.string)
      decode.success(TextDelta(text: text))
    }
    _ -> decode.failure(TextDelta(""), expected: "ContentDelta")
  }
}

fn parse_content_block_stop(data: Dynamic) -> Result(StreamEvent, Nil) {
  let decoder = {
    use index <- decode.field("index", decode.int)
    decode.success(ContentBlockStop(ContentBlockStopEvent(index: index)))
  }
  decode.run(data, decoder)
  |> result.replace_error(Nil)
}

fn parse_message_delta(data: Dynamic) -> Result(StreamEvent, Nil) {
  let decoder = {
    use delta <- decode.field("delta", message_changes_decoder())
    use usage <- decode.field("usage", decode.optional(usage_delta_decoder()))
    decode.success(MessageDelta(MessageDeltaEvent(delta: delta, usage: usage)))
  }
  decode.run(data, decoder)
  |> result.replace_error(Nil)
}

fn message_changes_decoder() -> Decoder(MessageChanges) {
  use stop_reason <- decode.optional_field(
    "stop_reason",
    None,
    decode.optional(stop_reason_decoder()),
  )
  use stop_sequence <- decode.optional_field(
    "stop_sequence",
    None,
    decode.optional(decode.string),
  )
  decode.success(MessageChanges(
    stop_reason: stop_reason,
    stop_sequence: stop_sequence,
  ))
}

fn usage_delta_decoder() -> Decoder(UsageDelta) {
  use output_tokens <- decode.field("output_tokens", decode.int)
  decode.success(UsageDelta(output_tokens: output_tokens))
}
