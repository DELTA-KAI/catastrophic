import birdie
import catastrophic
import gleam/http
import gleam/http/response
import gleam/json
import gleam/option
import gleeunit
import pprint

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

  catastrophic.message_to_json(msg)
  |> json.to_string
  |> birdie.snap("message_encoding_test")
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

  catastrophic.create_message_request_to_json(req)
  |> json.to_string
  |> birdie.snap("create_message_request_encoding_test")
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
  assert http.Post == http_request.method
  assert "https://api.anthropic.com/v1/messages"
    == http_request.scheme
    |> http.scheme_to_string
    <> "://"
    <> http_request.host
    <> http_request.path
  assert [
      #("content-type", "application/json"),
      #("x-api-key", "test-api-key"),
      #("anthropic-version", "2023-06-01"),
    ]
    == http_request.headers
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

  catastrophic.parse_create_message_response(http_response)
  |> pprint.format
  |> birdie.snap("response_parsing_error_test")
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

  catastrophic.create_message_stream(config, msg_request)
  |> pprint.format
  |> birdie.snap("stream_request_building_test")
}

pub fn parse_sse_text_delta_test() {
  // Test parsing a content_block_delta SSE event
  let sse_text =
    "event: content_block_delta
data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Hello\"}}

"

  let events = catastrophic.parse_sse_chunk(sse_text)

  let assert [
    catastrophic.ContentBlockDelta(catastrophic.ContentBlockDeltaEvent(
      0,
      catastrophic.TextDelta("Hello"),
    )),
  ] = events
}

pub fn parse_sse_multiple_events_test() {
  // Test parsing multiple SSE events in one chunk
  let sse_text =
    "event: content_block_delta
data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Hello\"}}

event: content_block_delta
data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\" world\"}}

"

  let assert [
    catastrophic.ContentBlockDelta(catastrophic.ContentBlockDeltaEvent(
      0,
      catastrophic.TextDelta("Hello"),
    )),
    catastrophic.ContentBlockDelta(catastrophic.ContentBlockDeltaEvent(
      // TODO: Shouldn't this be 1?
      0,
      catastrophic.TextDelta(" world"),
    )),
  ] = catastrophic.parse_sse_chunk(sse_text)
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

pub fn request_with_all_optional_fields_test() {
  // Test encoding a request with all optional fields populated
  let req =
    catastrophic.CreateMessageRequest(
      model: "claude-3-5-sonnet-20241022",
      messages: [catastrophic.text_message(catastrophic.User, "Test")],
      max_tokens: 500,
      system: option.Some("System prompt"),
      temperature: option.Some(0.8),
      top_p: option.Some(0.9),
      top_k: option.Some(50),
      stop_sequences: option.Some(["STOP", "END"]),
      tools: option.None,
    )

  catastrophic.create_message_request_to_json(req)
  |> json.to_string
  |> birdie.snap("request_with_all_optional_fields_test")
}

pub fn tool_result_message_test() {
  // Test creating and encoding a tool result message
  let msg =
    catastrophic.tool_result_message(
      "tool_123",
      "{\"result\": \"success\"}",
      False,
    )

  catastrophic.message_to_json(msg)
  |> json.to_string
  |> birdie.snap("tool_result_message_test")
}

pub fn multiple_tools_in_request_test() {
  // Test that multiple tools are correctly encoded in request
  let tool1 =
    catastrophic.simple_tool("get_weather", "Get weather data", [
      #("location", "City name"),
    ])

  let tool2 =
    catastrophic.simple_tool("search", "Search the web", [
      #("query", "Search query"),
    ])

  let config = catastrophic.default_config("test-api-key")

  let msg_request =
    catastrophic.CreateMessageRequest(
      model: "claude-3-5-sonnet-20241022",
      messages: [catastrophic.text_message(catastrophic.User, "Help me")],
      max_tokens: 100,
      system: option.None,
      temperature: option.None,
      top_p: option.None,
      top_k: option.None,
      stop_sequences: option.None,
      tools: option.Some([tool1, tool2]),
    )

  catastrophic.create_message(config, msg_request)
  |> pprint.format
  |> birdie.snap("multiple_tools_in_request_test")
}

pub fn response_with_tool_use_test() {
  // Test parsing a response that contains a tool use
  let response_body =
    "{\"id\":\"msg_123\",\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"tool_use\",\"id\":\"toolu_456\",\"name\":\"get_weather\",\"input\":{\"location\":\"San Francisco\"}}],\"model\":\"claude-3-5-sonnet-20241022\",\"stop_reason\":\"tool_use\",\"usage\":{\"input_tokens\":10,\"output_tokens\":20}}"

  let http_response = response.new(200) |> response.set_body(response_body)

  catastrophic.parse_create_message_response(http_response)
  |> pprint.format
  |> birdie.snap("response_with_tool_use_test")
}

pub fn image_content_block_test() {
  // Test encoding a message with an image content block
  let msg =
    catastrophic.Message(role: catastrophic.User, content: [
      catastrophic.ImageBlock(catastrophic.Base64Image(
        media_type: "image/png",
        data: "iVBORw0KGgo...",
      )),
    ])

  catastrophic.message_to_json(msg)
  |> json.to_string
  |> birdie.snap("image_content_block_test")
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

  // Encode the tool to JSON and parse to verify structure
  catastrophic.tool_to_json(tool)
  |> json.to_string
  |> birdie.snap("simple_tool_test")
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

  catastrophic.create_message(config, msg_request)
  |> pprint.format
  |> birdie.snap("tool_in_request_test")
}
