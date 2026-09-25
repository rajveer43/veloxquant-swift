#if os(macOS)

import Foundation
import VeloxQuantCore

/// Launch configuration for `python -m veloxquant_mlx serve` (plan §3.5's field list).
///
/// `port` defaults to 8000 — `serve.py`'s own default **and** `VeloxQuantClient`'s default
/// `baseURL` port, so this SDK never reproduces Go's split-default-port bug (Go's client
/// defaults to 8765 while its `ProcessConfig` defaults to 8000).
public struct ServeConfig: Sendable, Equatable {
    /// `--model`: Hugging Face id or local path (required).
    public var model: String
    /// `--method`; `nil` lets `serve` use its own default method.
    public var method: String?
    /// `--bits` (serve default 2).
    public var bits: Int
    /// `--host` (serve default `127.0.0.1`).
    public var host: String
    /// `--port` (serve default 8000).
    public var port: Int
    /// How long `start` waits for the `VELOXQUANT_READY` handshake. 300 s — Go's generous
    /// default (large quantized models load slowly), not TS's 120 s.
    public var readyTimeout: Duration
    /// `--max-tokens` (serve default 512).
    public var maxTokens: Int
    /// `--temp` (serve default 0.0).
    public var temperature: Double
    /// `--top-p` (serve default 1.0).
    public var topP: Double
    /// `--prompt-cache-size` (serve default 10).
    public var promptCacheSize: Int
    /// `--prompt-cache-bytes`. **Inert**: `serve` parses it but the installed `mlx_lm` server
    /// never applies it (serve prints a warning saying so). Surfaced for forward-compatibility
    /// only — setting it does not bound prompt-cache memory.
    public var promptCacheBytes: Int?
    /// `--set FIELD=VALUE` overrides. `bit_width_inlier`/`seed` are dropped (they collide with
    /// `--bits`/`--seed` and crash the server — `VeloxQuantCLI.serverOwnedOverrideKeys`).
    /// Invalid values are not "fixed up": `serve` fails fast, and so does `start`.
    public var setOverrides: [String: String]

    /// Creates a config; every field except `model` defaults to `serve`'s own default.
    public init(
        model: String,
        method: String? = nil,
        bits: Int = 2,
        host: String = "127.0.0.1",
        port: Int = 8000,
        readyTimeout: Duration = .seconds(300),
        maxTokens: Int = 512,
        temperature: Double = 0.0,
        topP: Double = 1.0,
        promptCacheSize: Int = 10,
        promptCacheBytes: Int? = nil,
        setOverrides: [String: String] = [:]
    ) {
        self.model = model
        self.method = method
        self.bits = bits
        self.host = host
        self.port = port
        self.readyTimeout = readyTimeout
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.topP = topP
        self.promptCacheSize = promptCacheSize
        self.promptCacheBytes = promptCacheBytes
        self.setOverrides = setOverrides
    }

    /// `serve`'s argument list (after `-m veloxquant_mlx`), with `serve.py`'s real kebab-case
    /// flag names: `--max-tokens`, `--temp`, `--top-p`, `--prompt-cache-size`,
    /// `--prompt-cache-bytes`. (Kotlin's builder emits `--max_tokens`/`--temperature`/`--top_p`/
    /// `--prompt_cache_size`, none of which `serve.py`'s argparse accepts.)
    public static func serveArguments(for config: ServeConfig) -> [String] {
        var arguments = [
            "serve",
            "--model", config.model,
            "--host", config.host,
            "--port", String(config.port),
            "--bits", String(config.bits)
        ]
        if let method = config.method {
            arguments += ["--method", method]
        }
        arguments += [
            "--max-tokens", String(config.maxTokens),
            "--temp", String(config.temperature),
            "--top-p", String(config.topP),
            "--prompt-cache-size", String(config.promptCacheSize)
        ]
        if let promptCacheBytes = config.promptCacheBytes {
            arguments += ["--prompt-cache-bytes", String(promptCacheBytes)]
        }
        return arguments + VeloxQuantCLI.setArguments(config.setOverrides)
    }
}

/// The handshake's `endpoints` object.
public struct ServeReadyEndpoints: Decodable, Sendable, Equatable {
    /// OpenAI-compatible base URL (`http://host:port/v1`).
    public let openaiBaseURL: String
    /// Chat completions URL.
    public let chatCompletions: String
    /// Completions URL.
    public let completions: String
    /// Models URL.
    public let models: String
    /// KV stats URL (newer `serve` versions only).
    public let kvStats: String?

    enum CodingKeys: String, CodingKey {
        case openaiBaseURL = "openai_base_url"
        case chatCompletions = "chat_completions"
        case completions, models
        case kvStats = "kv_stats"
    }
}

/// The `VELOXQUANT_READY {...}` stdout handshake `serve` prints once the model is loaded and
/// the cache wired (`emit_ready()` in `cli/serve.py`). Port of Studio's `ServeReadyPayload`.
public struct ServeReadyPayload: Decodable, Sendable, Equatable {
    /// Handshake schema version.
    public let schemaVersion: Int
    /// Model being served.
    public let model: String
    /// KV-cache method in use (useful when `ServeConfig.method` was `nil`).
    public let method: String
    /// Inlier bit width.
    public let bits: Int
    /// Listen host.
    public let host: String
    /// Listen port.
    public let port: Int
    /// Number of wired layer caches.
    public let layerCaches: Int?
    /// Endpoints `mlx_lm.server` actually serves.
    public let endpoints: Endpoints
    /// Decoded `?? true` when absent (Studio's fail-toward-`true` pattern).
    public let accountingOnly: Bool
    /// The accounting caveat, in words.
    public let accountingNote: String?

    /// The handshake's `endpoints` object.
    public typealias Endpoints = ServeReadyEndpoints

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case model, method, bits, host, port
        case layerCaches = "layer_caches"
        case endpoints
        case accountingOnly = "accounting_only"
        case accountingNote = "accounting_note"
    }

    /// Decodes the handshake.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        model = try container.decode(String.self, forKey: .model)
        method = try container.decode(String.self, forKey: .method)
        bits = try container.decode(Int.self, forKey: .bits)
        host = try container.decode(String.self, forKey: .host)
        port = try container.decode(Int.self, forKey: .port)
        layerCaches = try container.decodeIfPresent(Int.self, forKey: .layerCaches)
        endpoints = try container.decode(Endpoints.self, forKey: .endpoints)
        accountingOnly = try container.decodeIfPresent(Bool.self, forKey: .accountingOnly) ?? true
        accountingNote = try container.decodeIfPresent(String.self, forKey: .accountingNote)
    }

    /// The prefix `serve` prints before the JSON payload.
    public static let linePrefix = "VELOXQUANT_READY "

    /// Parses a stdout line: `nil` if it is not a handshake line, throws if it is one whose JSON
    /// does not decode.
    static func parse(line: String) throws -> ServeReadyPayload? {
        guard line.hasPrefix(linePrefix) else { return nil }
        return try JSONDecoder().decode(ServeReadyPayload.self, from: Data(line.dropFirst(linePrefix.count).utf8))
    }
}

#else

#error("VeloxQuantRuntime requires macOS — process management and CLI shell-outs are not available on this platform.")

#endif
