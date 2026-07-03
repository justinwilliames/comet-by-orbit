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
            if case .rateLimited = error {
                // Prefer quality. Groq's per-minute window rolls quickly, and
                // the 8B fallback's output is so often mangled that the
                // pipeline's guardrails discard it back to the raw transcript
                // anyway. So back off briefly and retry the PRIMARY (70B) model
                // once — a good cleaned result beats a bad one that gets thrown
                // away. Only if the retry is ALSO rate-limited do we drop to
                // the small fallback as a last resort.
                logger.warning("Groq primary model rate-limited — backing off and retrying primary once before any fallback")
                try? await Task.sleep(for: .seconds(2))
                do {
                    return try await primaryInner.complete(request: request)
                } catch let retryError as LLMError {
                    guard case .rateLimited = retryError else { throw retryError }
                    logger.warning(
                        "Groq primary still rate-limited after retry — falling back to \(self.fallbackModelName, privacy: .public) with simplified prompt"
                    )
                    // Swap to the simplified cleanup prompt for the 8B
                    // fallback. The full ~1,400-token default prompt
                    // overwhelms small models — they pattern-match on
                    // conversation cues, refuse, frame output, or drop
                    // content. The simplified prompt (~250 tokens, three
                    // few-shot examples, structured `<output>` tags) anchors
                    // 8B on the transformation task. The user's tone-of-voice
                    // override and any custom prompt are dropped on this
                    // path — small models can't reliably honour layered
                    // instructions, and the pipeline's compression /
                    // framing guardrails catch the obvious failures.
                    let downgradedRequest = LLMRequest(
                        systemPrompt: Prompts.simplifiedCleanup,
                        userMessage: request.userMessage,
                        temperature: request.temperature,
                        maxTokens: request.maxTokens
                    )
                    return try await fallbackInner.complete(request: downgradedRequest)
                }
            }
            throw error
        }
    }
}
