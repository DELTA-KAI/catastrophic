# kai_anthropic

[![Package Version](https://img.shields.io/hexpm/v/kai_anthropic)](https://hex.pm/packages/kai_anthropic)
[![Hex Docs](https://img.shields.io/badge/hex-docs-ffaff3)](https://hexdocs.pm/kai_anthropic/)

A SANS-IO Anthropic API client for Gleam.

This package provides a Sans I/O (SANS-IO) implementation of the Anthropic API client. Following the SANS-IO pattern, this library separates I/O operations from protocol logic, making it easier to test and compose with different HTTP clients.

## Installation

```sh
gleam add kai_anthropic
```

## What is SANS-IO?

SANS-IO is a pattern where libraries separate I/O (like network requests) from the protocol logic. This kai_anthropic library:

- **Builds HTTP requests** without sending them
- **Parses HTTP responses** without receiving them
- Lets **you choose** your HTTP client (httpc, hackney, fetch, etc.)
- Makes testing easier (no mocking required)
- Follows Gleam conventions strictly

## Usage

The basic workflow is:

1. Create a configuration with your API key
2. Build a request using `create_message`
3. Send the request using your preferred HTTP client
4. Parse the response using `parse_create_message_response`

### Example

```gleam
import kai_anthropic
import gleam/option.{None}

pub fn main() {
  // 1. Create configuration
  let config = kai_anthropic.new_config("your-api-key")

  // 2. Create a message request
  let msg_request = kai_anthropic.CreateMessageRequest(
    model: "claude-3-5-sonnet-20241022",
    messages: [
      kai_anthropic.text_message(kai_anthropic.User, "Hello, Claude!"),
    ],
    max_tokens: 1024,
    system: None,
    temperature: None,
    top_p: None,
    top_k: None,
    stop_sequences: None,
  )

  // 3. Build the HTTP request (SANS-IO - no I/O performed)
  case kai_anthropic.create_message(config, msg_request) {
    Ok(http_request) -> {
      // 4. Send http_request using your HTTP client of choice
      // For example, using gleam_httpc:
      // case httpc.send(http_request) {
      //   Ok(http_response) -> {
      //     // 5. Parse the response (SANS-IO)
      //     kai_anthropic.parse_create_message_response(http_response)
      //   }
      //   Error(e) -> Error(...)
      // }
      todo as "Send request with your HTTP client"
    }
    Error(e) -> {
      // Handle error (e.g., missing API key)
      Error(e)
    }
  }
}
```

### Streaming Responses

For streaming responses (Server-Sent Events), use `create_message_stream` instead of `create_message`:

```gleam
import kai_anthropic
import gleam/option.{None}
import gleam/io

pub fn stream_example() {
  let config = kai_anthropic.new_config("your-api-key")

  let msg_request = kai_anthropic.CreateMessageRequest(
    model: "claude-3-5-sonnet-20241022",
    messages: [
      kai_anthropic.text_message(kai_anthropic.User, "Write a haiku"),
    ],
    max_tokens: 1024,
    system: None,
    temperature: None,
    top_p: None,
    top_k: None,
    stop_sequences: None,
  )

  // Build the streaming request
  case kai_anthropic.create_message_stream(config, msg_request) {
    Ok(http_request) -> {
      // Use your HTTP client's streaming capabilities
      // For each chunk of text you receive:
      // 
      // let events = kai_anthropic.parse_sse_chunk(chunk)
      // list.each(events, fn(event) {
      //   case event {
      //     kai_anthropic.ContentBlockDelta(delta) -> {
      //       // Print incremental text as it arrives
      //       io.print(delta.delta.text)
      //     }
      //     kai_anthropic.MessageStop(_) -> {
      //       io.println("\n[Stream complete]")
      //     }
      //     _ -> Nil
      //   }
      // })
      todo as "Stream with your HTTP client"
    }
    Error(e) -> Error(e)
  }
}
```

The `parse_sse_chunk` function is **SANS-IO** - you feed it text chunks from your streaming HTTP client, and it returns typed events.

### Tool Use (Function Calling)

Claude can use tools to interact with external systems. Define tools with type-safe JSON schemas using the `castor` package:

```gleam
import kai_anthropic
import gleam/option.{None, Some}

pub fn tool_use_example() {
  let config = kai_anthropic.new_config("your-api-key")

  // Define a tool with simple string parameters
  let get_weather_tool = kai_anthropic.simple_tool(
    "get_weather",
    "Get the current weather for a location",
    [
      #("location", "The city and state, e.g. San Francisco, CA"),
      #("unit", "Temperature unit (celsius or fahrenheit)"),
    ],
  )

  // Create a request with tools
  let msg_request = kai_anthropic.CreateMessageRequest(
    model: "claude-3-5-sonnet-20241022",
    messages: [
      kai_anthropic.text_message(
        kai_anthropic.User,
        "What's the weather in San Francisco?",
      ),
    ],
    max_tokens: 1024,
    system: None,
    temperature: None,
    top_p: None,
    top_k: None,
    stop_sequences: None,
    tools: Some([get_weather_tool]),
  )

  // Send request and parse response
  case kai_anthropic.create_message(config, msg_request) {
    Ok(http_request) -> {
      // After sending with your HTTP client and parsing the response:
      // case kai_anthropic.parse_create_message_response(http_response) {
      //   Ok(response) -> {
      //     // Check if Claude wants to use a tool
      //     case response.stop_reason {
      //       Some(kai_anthropic.ToolUse) -> {
      //         // Extract tool calls from response.content
      //         // Execute the tool
      //         // Send tool results back with tool_result_message()
      //       }
      //       _ -> // Handle regular response
      //     }
      //   }
      // }
      todo as "Send and handle response"
    }
    Error(e) -> Error(e)
  }
}
```

For more complex tool schemas, use the `castor` package directly. See [TOOLS.md](TOOLS.md) for detailed documentation.

### Using with different HTTP clients

#### gleam_httpc (Erlang)

```gleam
import gleam_httpc
import kai_anthropic

case kai_anthropic.create_message(config, request) {
  Ok(http_request) -> {
    case httpc.send(http_request) {
      Ok(http_response) -> 
        kai_anthropic.parse_create_message_response(http_response)
      Error(_) -> Error(kai_anthropic.NetworkError("HTTP request failed"))
    }
  }
  Error(e) -> Error(e)
}
```

#### gleam_fetch (JavaScript) - Non-streaming

```gleam
import gleam/fetch
import kai_anthropic

case kai_anthropic.create_message(config, request) {
  Ok(http_request) -> {
    use http_response <- promise.try_await(fetch.send(http_request))
    use body <- promise.try_await(fetch.read_text_body(http_response))
    promise.resolve(kai_anthropic.parse_create_message_response(
      response.set_body(http_response, body)
    ))
  }
  Error(e) -> promise.resolve(Error(e))
}
```

#### Streaming with JavaScript (fetch ReadableStream)

```gleam
import gleam/fetch
import gleam/io
import gleam/list
import kai_anthropic

pub fn stream_with_fetch() {
  let config = kai_anthropic.new_config("your-api-key")
  let request = // ... your CreateMessageRequest
  
  case kai_anthropic.create_message_stream(config, request) {
    Ok(http_request) -> {
      // Send the request
      use response <- promise.try_await(fetch.send(http_request))
      
      // Access the ReadableStream body
      // response.body is a ReadableStream
      // You'd use JavaScript's getReader() to read chunks
      // and feed them to parse_sse_chunk()
      
      // Pseudocode (would need FFI):
      // let reader = response.body.getReader()
      // loop {
      //   case reader.read() {
      //     Done -> break
      //     Chunk(text) -> {
      //       let events = kai_anthropic.parse_sse_chunk(text)
      //       list.each(events, handle_event)
      //     }
      //   }
      // }
      
      todo as "Implement with JavaScript FFI for ReadableStream"
    }
    Error(e) -> promise.resolve(Error(e))
  }
}

fn handle_event(event: kai_anthropic.StreamEvent) -> Nil {
  case event {
    kai_anthropic.ContentBlockDelta(delta) -> {
      // Print incremental text
      io.print(delta.delta.text)
    }
    kai_anthropic.MessageStop(_) -> {
      io.println("\n[Complete]")
    }
    _ -> Nil
  }
}
```

## Features

- ✅ SANS-IO design - bring your own HTTP client
- ✅ Messages API support
- ✅ **Streaming responses with Server-Sent Events (SSE)**
- ✅ **Tool use / Function calling** with type-safe schemas
- ✅ Comprehensive error handling
- ✅ Type-safe request building and response parsing
- ✅ Single module - simple and focused
- ✅ Follows Gleam conventions strictly:
  - Qualified imports for functions
  - Result types for fallible operations
  - Annotated function types
  - Singular module names
  - No panics in library code
- ✅ Zero runtime dependencies (except HTTP and JSON libraries)

## Conventions

This package follows the [Gleam conventions](https://github.com/gleam-lang/website/blob/patterns/documentation/conventions-patterns-anti-patterns.djot) strictly:

- **Qualified imports**: All functions are imported with their module name
- **Result over Option**: Fallible functions return `Result`, not `Option`
- **No panics**: The library never panics - all errors are returned as `Result`
- **Type annotations**: All public functions have complete type annotations
- **SANS-IO pattern**: I/O is completely separated from protocol logic
- **Single focused module**: All functionality in one module for simplicity

## API

### Core Functions

**Non-streaming:**
- `new_config(api_key: String) -> Config` - Create a new configuration
- `create_message(Config, CreateMessageRequest) -> Result(Request(String), Error)` - Build a create message request
- `parse_create_message_response(Response(String)) -> Result(MessageResponse, Error)` - Parse a create message response

**Streaming:**
- `create_message_stream(Config, CreateMessageRequest) -> Result(Request(String), Error)` - Build a streaming message request
- `parse_sse_chunk(String) -> List(StreamEvent)` - Parse Server-Sent Events from a text chunk

### Stream Events

When streaming, `parse_sse_chunk` returns a list of `StreamEvent`:

- `MessageStart(MessageStartEvent)` - Initial message metadata
- `ContentBlockStart(ContentBlockStartEvent)` - Start of a content block
- `ContentBlockDelta(ContentBlockDeltaEvent)` - Incremental text update
- `ContentBlockStop(ContentBlockStopEvent)` - End of content block
- `MessageDelta(MessageDeltaEvent)` - Message-level changes (stop reason, usage)
- `MessageStop(MessageStopEvent)` - End of stream
- `Ping` - Keep-alive ping
- `UnknownEvent(event_type: String, data: String)` - Forward compatibility

### Configuration

- `set_api_version(Config, String) -> Config` - Set a custom API version
- `set_base_url(Config, String) -> Config` - Set a custom base URL

### Helpers

- `text_message(Role, String) -> Message` - Create a simple text message
- `simple_tool(name, description, parameters) -> Tool` - Create a tool with string parameters
- `tool_result_message(tool_use_id, content, is_error) -> Message` - Create a tool result message
- `tool_to_json(Tool) -> Json` - Encode a tool to JSON (for debugging)
- `error_to_string(Error) -> String` - Convert an error to a human-readable string
- `is_success(Response(a)) -> Bool` - Check if response is successful (2xx)
- `is_client_error(Response(a)) -> Bool` - Check if response is client error (4xx)
- `is_server_error(Response(a)) -> Bool` - Check if response is server error (5xx)

## Development

```sh
gleam run   # Run the project
gleam test  # Run the tests (14 tests)
gleam build # Build the project
```

## License

Apache-2.0
