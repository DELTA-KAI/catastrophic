import catastrophic
import gleam/http
import gleam/http/response
import gleam/json
import gleam/list
import gleam/option
import gleam/string
import gleeunit

pub fn main() -> Nil {
  gleeunit.main()
}

// gleeunit test functions end in `_test`

pub fn message_encoding_test() {
  // Test encoding a simple text message
  let msg =
    catastrophic.Message(role: catastrophic.User, content: [
      catastrophic.TextBlock("Hello, world!"),
    ])

  let encoded =
    catastrophic.message_to_json(msg)
    |> json.to_string

  // Should contain the role and text
  let assert True = string.contains(encoded, "\"role\":\"user\"")
  let assert True = string.contains(encoded, "\"text\":\"Hello, world!\"")
}

pub fn create_message_request_encoding_test() {
  // Test encoding a complete create message request
  let req =
    catastrophic.CreateMessageRequest(
      model: "claude-3-5-sonnet-20241022",
      messages: [
        catastrophic.Message(role: catastrophic.User, content: [
          catastrophic.TextBlock("Test message"),
        ]),
      ],
      max_tokens: 1024,
      system: option.Some("You are a helpful assistant"),
      temperature: option.Some(0.7),
      top_p: option.None,
      top_k: option.None,
      stop_sequences: option.None,
      tools: option.None,
    )

  let encoded =
    catastrophic.create_message_request_to_json(req)
    |> json.to_string

  // Should contain all the fields
  let assert True =
    string.contains(encoded, "\"model\":\"claude-3-5-sonnet-20241022\"")
  let assert True = string.contains(encoded, "\"max_tokens\":1024")
  let assert True =
    string.contains(encoded, "\"system\":\"You are a helpful assistant\"")
  let assert True = string.contains(encoded, "\"temperature\":0.7")
}

pub fn request_building_test() {
  // Test building an HTTP request
  let config = catastrophic.default_config("test-api-key")

  let msg_request =
    catastrophic.CreateMessageRequest(
      model: "claude-3-5-sonnet-20241022",
      messages: [
        catastrophic.Message(role: catastrophic.User, content: [
          catastrophic.TextBlock("Hello"),
        ]),
      ],
      max_tokens: 100,
      system: option.None,
      temperature: option.None,
      top_p: option.None,
      top_k: option.None,
      stop_sequences: option.None,
      tools: option.None,
    )

  let assert Ok(http_request) = catastrophic.create_message(config, msg_request)

  // Check the request properties
  let assert http.Post = http_request.method
  let assert "https://api.anthropic.com/v1/messages" =
    http_request.scheme
    |> http.scheme_to_string
    <> "://"
    <> http_request.host
    <> http_request.path

  // Check headers are set
  let headers = http_request.headers
  let assert True = has_header(headers, "x-api-key", "test-api-key")
  let assert True = has_header(headers, "content-type", "application/json")
  let assert True = has_header(headers, "anthropic-version", "2023-06-01")
}

pub fn missing_api_key_test() {
  // Test that missing API key returns an error
  let config = catastrophic.default_config("")

  let msg_request =
    catastrophic.CreateMessageRequest(
      model: "claude-3-5-sonnet-20241022",
      messages: [],
      max_tokens: 100,
      system: option.None,
      temperature: option.None,
      top_p: option.None,
      top_k: option.None,
      stop_sequences: option.None,
      tools: option.None,
    )

  let assert Error(catastrophic.MissingApiKey) =
    catastrophic.create_message(config, msg_request)
}

pub fn response_parsing_success_test() {
  // Test parsing a successful response
  let response_body =
    "{\"id\":\"msg_123\",\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"Hello!\"}],\"model\":\"claude-3-5-sonnet-20241022\",\"stop_reason\":\"end_turn\",\"usage\":{\"input_tokens\":10,\"output_tokens\":5}}"

  let http_response = response.new(200) |> response.set_body(response_body)

  let assert Ok(msg_response) =
    catastrophic.parse_create_message_response(http_response)
  let assert "msg_123" = msg_response.id
  let assert "claude-3-5-sonnet-20241022" = msg_response.model
  let assert catastrophic.Assistant = msg_response.role
  let assert option.Some(catastrophic.EndTurn) = msg_response.stop_reason
  let assert 10 = msg_response.usage.input_tokens
  let assert 5 = msg_response.usage.output_tokens
}

pub fn response_parsing_error_test() {
  // Test parsing an error response
  let error_body =
    "{\"type\":\"error\",\"error\":{\"type\":\"invalid_request_error\",\"message\":\"Invalid API key\"}}"

  let http_response = response.new(401) |> response.set_body(error_body)

  let assert Error(catastrophic.ApiError(status: 401, message: _, error_type: _)) =
    catastrophic.parse_create_message_response(http_response)
}

pub fn error_to_string_test() {
  // Test error to string conversion
  let err = catastrophic.MissingApiKey
  let msg = catastrophic.describe_error(err)
  let assert True = string.contains(msg, "API key")

  let api_err =
    catastrophic.ApiError(
      status: 400,
      message: "Bad request",
      error_type: "invalid_request",
    )
  let api_msg = catastrophic.describe_error(api_err)
  let assert True = string.contains(api_msg, "400")
  let assert True = string.contains(api_msg, "Bad request")
}

pub fn stream_request_building_test() {
  // Test building a streaming HTTP request
  let config = catastrophic.default_config("test-api-key")

  let msg_request =
    catastrophic.CreateMessageRequest(
      model: "claude-3-5-sonnet-20241022",
      messages: [
        catastrophic.Message(role: catastrophic.User, content: [
          catastrophic.TextBlock("Hello"),
        ]),
      ],
      max_tokens: 100,
      system: option.None,
      temperature: option.None,
      top_p: option.None,
      top_k: option.None,
      stop_sequences: option.None,
      tools: option.None,
    )

  let assert Ok(http_request) =
    catastrophic.create_message_stream(config, msg_request)

  // Check that Accept header is set for SSE
  let headers = http_request.headers
  let assert True = has_header(headers, "accept", "text/event-stream")

  // Check that body contains stream: true
  let assert True = string.contains(http_request.body, "\"stream\":true")
}

pub fn parse_sse_text_delta_test() {
  // Test parsing a content_block_delta SSE event
  let sse_text =
    "event: content_block_delta
data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Hello\"}}

"

  let events = catastrophic.parse_sse_chunk(sse_text)

  let assert [catastrophic.ContentBlockDelta(delta)] = events
  let assert 0 = delta.index
  let assert catastrophic.TextDelta(text: "Hello") = delta.delta
}

pub fn parse_sse_multiple_events_test() {
  // Test parsing multiple SSE events in one chunk
  let sse_text =
    "event: content_block_delta
data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Hello\"}}

event: content_block_delta
data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\" world\"}}

"

  let events = catastrophic.parse_sse_chunk(sse_text)
  let assert 2 = list.length(events)
}

pub fn parse_sse_ping_test() {
  // Test parsing a ping event
  let sse_text =
    "event: ping

"

  let events = catastrophic.parse_sse_chunk(sse_text)
  let assert [catastrophic.Ping] = events
}

pub fn parse_sse_message_stop_test() {
  // Test parsing a message_stop event
  let sse_text =
    "event: message_stop
data: {\"type\":\"message_stop\"}

"

  let events = catastrophic.parse_sse_chunk(sse_text)
  let assert [catastrophic.MessageStop(catastrophic.MessageStopEvent)] = events
}

// Helper functions

fn has_header(
  headers: List(#(String, String)),
  key: String,
  value: String,
) -> Bool {
  case headers {
    [] -> False
    [#(k, v), ..] if k == key && v == value -> True
    [_, ..rest] -> has_header(rest, key, value)
  }
}

pub fn simple_tool_test() {
  // Test creating a simple tool with castor
  let tool =
    catastrophic.simple_tool(
      "get_weather",
      "Get the current weather for a location",
      [
        #("location", "The city and state, e.g. San Francisco, CA"),
        #("unit", "Temperature unit (celsius or fahrenheit)"),
      ],
    )

  let assert "get_weather" = tool.name
  let assert "Get the current weather for a location" = tool.description

  // Encode the tool to JSON and check it contains the schema
  let tool_json =
    catastrophic.tool_to_json(tool)
    |> json.to_string

  let assert True = string.contains(tool_json, "\"name\":\"get_weather\"")
  let assert True = string.contains(tool_json, "\"location\"")
  let assert True = string.contains(tool_json, "\"unit\"")
}

pub fn tool_in_request_test() {
  // Test that tools are included in the request JSON
  let tool =
    catastrophic.simple_tool("calculator", "Perform basic arithmetic", [
      #("expression", "The mathematical expression to evaluate"),
    ])

  let config = catastrophic.default_config("test-api-key")

  let msg_request =
    catastrophic.CreateMessageRequest(
      model: "claude-3-5-sonnet-20241022",
      messages: [
        catastrophic.text_message(catastrophic.User, "What is 2+2?"),
      ],
      max_tokens: 100,
      system: option.None,
      temperature: option.None,
      top_p: option.None,
      top_k: option.None,
      stop_sequences: option.None,
      tools: option.Some([tool]),
    )

  let assert Ok(http_request) = catastrophic.create_message(config, msg_request)

  // Check that the body contains the tools
  let assert True = string.contains(http_request.body, "\"tools\"")
  let assert True = string.contains(http_request.body, "\"calculator\"")
  let assert True = string.contains(http_request.body, "\"expression\"")
}
