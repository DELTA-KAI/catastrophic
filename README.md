# Catastrophic 🌋

[![Package Version](https://img.shields.io/hexpm/v/catastrophic)](https://hex.pm/packages/catastrophic)
[![Hex Docs](https://img.shields.io/badge/hex-docs-ffaff3)](https://hexdocs.pm/catastrophic/)

A SANS-IO Anthropic API client for Gleam.

This package provides a Sans I/O (SANS-IO) implementation of the Anthropic API client. Following the SANS-IO pattern, this library separates I/O operations from protocol logic, making it easier to test and compose with different HTTP clients.

## Installation

```sh
gleam add catastrophic
```

## What is SANS-IO?

SANS-IO is a pattern where libraries separate I/O (like network requests) from the protocol logic. This catastrophic library:

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
import catastrophic
import gleam/option.{None}

pub fn main() {
  // 1. Create configuration
  let config = catastrophic.new_config("your-api-key")

  // 2. Create a message request
  let msg_request = catastrophic.CreateMessageRequest(
    model: "claude-3-5-sonnet-20241022",
    messages: [
      catastrophic.text_message(catastrophic.User, "Hello, Claude!"),
    ],
    max_tokens: 1024,
    system: None,
    temperature: None,
    top_p: None,
    top_k: None,
    stop_sequences: None,
  )

  // 3. Build the HTTP request (SANS-IO - no I/O performed)
  case catastrophic.create_message(config, msg_request) {
    Ok(http_request) -> {
      // 4. Send http_request using your HTTP client of choice
      // For example, using gleam_httpc:
      // case httpc.send(http_request) {
      //   Ok(http_response) -> {
      //     // 5. Parse the response (SANS-IO)
      //     catastrophic.parse_create_message_response(http_response)
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
import catastrophic
import gleam/option.{None}
import gleam/io

pub fn stream_example() {
  let config = catastrophic.new_config("your-api-key")

  let msg_request = catastrophic.CreateMessageRequest(
    model: "claude-3-5-sonnet-20241022",
    messages: [
      catastrophic.text_message(catastrophic.User, "Write a haiku"),
    ],
    max_tokens: 1024,
    system: None,
    temperature: None,
    top_p: None,
    top_k: None,
    stop_sequences: None,
  )

  // Build the streaming request
  case catastrophic.create_message_stream(config, msg_request) {
    Ok(http_request) -> {
      // Use your HTTP client's streaming capabilities
      // For each chunk of text you receive:
      // 
      // let events = catastrophic.parse_sse_chunk(chunk)
      // list.each(events, fn(event) {
      //   case event {
      //     catastrophic.ContentBlockDelta(delta) -> {
      //       // Print incremental text as it arrives
      //       io.print(delta.delta.text)
      //     }
      //     catastrophic.MessageStop(_) -> {
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
import catastrophic
import gleam/option.{None, Some}

pub fn tool_use_example() {
  let config = catastrophic.new_config("your-api-key")

  // Define a tool with simple string parameters
  let get_weather_tool = catastrophic.simple_tool(
    "get_weather",
    "Get the current weather for a location",
    [
      #("location", "The city and state, e.g. San Francisco, CA"),
      #("unit", "Temperature unit (celsius or fahrenheit)"),
    ],
  )

  // Create a request with tools
  let msg_request = catastrophic.CreateMessageRequest(
    model: "claude-3-5-sonnet-20241022",
    messages: [
      catastrophic.text_message(
        catastrophic.User,
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
  case catastrophic.create_message(config, msg_request) {
    Ok(http_request) -> {
      // After sending with your HTTP client and parsing the response:
      // case catastrophic.parse_create_message_response(http_response) {
      //   Ok(response) -> {
      //     // Check if Claude wants to use a tool
      //     case response.stop_reason {
      //       Some(catastrophic.ToolUse) -> {
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
import catastrophic

case catastrophic.create_message(config, request) {
  Ok(http_request) -> {
    case httpc.send(http_request) {
      Ok(http_response) -> 
        catastrophic.parse_create_message_response(http_response)
      Error(_) -> Error(catastrophic.NetworkError("HTTP request failed"))
    }
  }
  Error(e) -> Error(e)
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

## Development

```sh
gleam run   # Run the project
gleam test  # Run the tests (14 tests)
gleam build # Build the project
```

## License

Apache-2.0
