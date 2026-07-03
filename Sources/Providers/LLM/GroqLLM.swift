import Foundation
import os

private let logger = Logger(subsystem: "team.yourorbit.OrbitDictation", category: "GroqLLM")

/// Groq LLM provider (OpenAI-compatible endpoint).
///
/// Two-model fallback chain on Groq's free tier: tries the higher-quality
/// primary model first, automatically falls back to the faster + much
/// higher-headroom secondary model on rate-limit errors. Free-tier daily
/// token budgets are per-model, so the fallback typically still has plenty
/// of budget when the primary is exhausted, and per-request token usage on
/// the smaller model is also lower — net effect is "the user keeps working
/// through a rate-limit window instead of seeing raw transcripts".
struct GroqLLM: LLMProvider {
    static let providerID: LLMProviderID = .groq

    private let primaryInner: OpenAILLM
    private let fallbackInner: OpenAILLM
    private let fallbackModelName: String

    init(
        apiKey: String,
        httpClient: ProviderHTTPClient,
        primaryModel: String = "llama-3.3-70b-versatile",
        fallbackModel: String = "llama-3.1-8b-instant",
        timeoutSeconds: TimeInterval = 20
    ) {
        // Groq uses an OpenAI-compatible API, so we delegate to OpenAILLM
        // with the Groq base URL. Two instances — one per model — so each
        // call can pick the right one without re-allocating per request.
        self.primaryInner = OpenAILLM(
            apiKey: apiKey,
            httpClient: httpClient,
            baseURL: "https://api.groq.com/openai/v1",
            providerID: .groq,
            model: primaryModel,
            timeoutSeconds: timeoutSeconds
        )
        self.fallbackInner = OpenAILLM(
            apiKey: apiKey,
            httpClient: httpClient,
            baseURL: "https://api.groq.com/openai/v1",
            providerID: .groq,
            model: fallbackModel,
            timeoutSeconds: timeoutSeconds
        )
        self.fallbackModelName = fallbackModel
    }

    var endpointOrigin: URL? { primaryInner.endpointOrigin }

    func complete(request: LLMRequest) async throws -> LLMResponse {
        do {
            return try await primaryInner.complete(request: request)
        } catch let error as LLMError {
            // Auto-fallback only on rate-limit. Other errors (missing key,
            // bad request, transport failure, server 5xx) propagate so the
            // pipeline can decide how to degrade — typically by skipping
            // cleanup and pasting the raw transcript.
            if case let .rateLimited(_, retryAfter) = error {
                // Prefer quality: the 8B fallback's output is so often mangled
                // that the pipeline's guardrails discard it back to the raw
                // transcript anyway, so retrying the PRIMARY (70B) model is
                // worth a SHORT wait. But only if the rate-limit window is
                // actually short — Groq's `retry-after` tells us exactly. A
                // blind wait into a long (e.g. 30s TPM) window would just 429
                // again, then fall back anyway: slower with no gain, and it
                // double-spends the shared minute budget. So honour the real
                // retry-after (capped); if it exceeds the cap, skip the retry
                // and use the fast fallback now rather than stalling the paste.
                //
                // The simplified cleanup prompt is used for the 8B fallback:
                // the full ~1,400-token default prompt overwhelms small models
                // (they pattern-match on conversation cues, refuse, frame
                // output, or drop content). The ~250-token simplified prompt
                // with structured `<output>` tags anchors 8B on the transform;
                // the user's tone/custom-prompt overrides are dropped on this
                // path and the pipeline's guardrails catch obvious failures.
                let downgraded = LLMRequest(
                    systemPrompt: Prompts.simplifiedCleanup,
                    userMessage: request.userMessage,
                    temperature: request.temperature,
                    maxTokens: request.maxTokens
                )
                let maxWait: TimeInterval = 8
                if let retryAfter, retryAfter > maxWait {
                    logger.warning(
                        "Groq primary rate-limited (retry-after \(Int(retryAfter), privacy: .public)s > \(Int(maxWait), privacy: .public)s cap) — using \(self.fallbackModelName, privacy: .public) now instead of stalling"
                    )
                    return try await fallbackInner.complete(request: downgraded)
                }
                let backoff = min(retryAfter ?? 2, maxWait)
                logger.warning(
                    "Groq primary rate-limited — backing off \(String(format: "%.1f", backoff), privacy: .public)s and retrying primary once before any fallback"
                )
                try? await Task.sleep(for: .seconds(backoff))
                do {
                    return try await primaryInner.complete(request: request)
                } catch let retryError as LLMError {
                    guard case .rateLimited = retryError else { throw retryError }
                    logger.warning(
                        "Groq primary still rate-limited after retry — falling back to \(self.fallbackModelName, privacy: .public) with simplified prompt"
                    )
                    return try await fallbackInner.complete(request: downgraded)
                }
            }
            throw error
        }
    }
}
