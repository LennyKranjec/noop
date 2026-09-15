import Foundation

// ThinkingFilter.swift — dropping a reasoning model's thinking block from the visible answer.
//
// Pure + deterministic so it is unit-testable without a model or an app target, and so it behaves
// identically to the Android twin `com.noop.ai.ThinkingFilter` (the cross-platform parity contract).
//
// A reasoning model writes its working inside `<think> … </think>` before the answer it means to give.
// Streamed straight through, the user watches a wall of deliberation arrive, then the actual reply,
// with the tags themselves in the middle of it.
//
// THIS IS A STREAMING FILTER because the tags do not arrive whole: a tag can be split across two tokens
// ("<th" then "ink>"), so a stateless replace on each delta would let the halves through. It holds back
// any trailing text that could still turn into a tag and releases it once it cannot.
//
// AN UNTERMINATED `<think>` IS KEPT, NOT BINNED. A small model given a long system prompt can spend its
// whole token budget deliberating and never reach an answer; dropping that leaves the user with "(no
// reply)" after a minute of waiting, which reads as a broken app rather than a model that ran out of
// room. The reasoning is held in `strandedReasoning` so the caller can show it — labelled as the
// working it is — instead of a blank.

public final class ThinkingFilter {

    private let openTag: String
    private let closeTag: String
    private var inside = false

    /// Text held back because it is a possible partial tag, and must be re-examined next delta.
    private var pending = ""

    /// The span being dropped right now. Emptied into `closedSpans` whenever one closes.
    private var dropped = ""

    /// Each span that was dropped AND properly closed, in the order they arrived.
    private var closedSpans: [String] = []

    public init(openTag: String = "<think>", closeTag: String = "</think>") {
        self.openTag = openTag
        self.closeTag = closeTag
    }

    /// Feed one streamed chunk; returns the part of it that belongs in the visible answer.
    ///
    /// The return is often empty — while inside a thinking block, or while holding a few characters
    /// that might be the start of a tag.
    public func push(_ delta: String) -> String {
        pending += delta
        var out = ""

        while true {
            if !inside {
                if let open = pending.range(of: openTag) {
                    out += pending[..<open.lowerBound]
                    pending = String(pending[open.upperBound...])
                    inside = true
                    continue
                }
                // No complete open tag. Emit everything that cannot be the start of one, and keep the
                // tail that still could be.
                let keep = partialTagSuffix(pending, openTag)
                let cut = pending.index(pending.endIndex, offsetBy: -keep)
                out += pending[..<cut]
                pending = String(pending[cut...])
                return out
            } else {
                if let close = pending.range(of: closeTag) {
                    // The span is complete: bank it whole, before `dropped` accumulates the next one.
                    closedSpans.append(dropped + pending[..<close.lowerBound])
                    dropped = ""
                    pending = String(pending[close.upperBound...])
                    inside = false
                    continue
                }
                // Still thinking: drop everything except a possible partial closing tag.
                let keep = partialTagSuffix(pending, closeTag)
                let cut = pending.index(pending.endIndex, offsetBy: -keep)
                dropped += pending[..<cut]
                pending = String(pending[cut...])
                return out
            }
        }
    }

    /// Whatever is left once the stream ends.
    ///
    /// Inside a thinking block this is empty: the model never reached its answer, and printing its
    /// half-finished reasoning HERE would be presenting working as conclusion. `strandedReasoning` is
    /// the deliberate, labelled way to show it instead.
    public func flush() -> String {
        if inside { return "" }
        let out = pending
        pending = ""
        return out
    }

    /// The reasoning of a model that ran out of budget before it closed its thinking block — empty
    /// whenever the model did reach its answer, so a caller can treat "not empty" as "there is no
    /// answer, only working".
    public func strandedReasoning() -> String {
        inside ? (dropped + pending).trimmingCharacters(in: .whitespacesAndNewlines) : ""
    }

    /// The completed dropped spans.
    ///
    /// A second instance of this filter runs with `[[` / `]]` to keep the coach's reminder directives
    /// off the screen; those spans are not noise to be discarded like reasoning, they are instructions
    /// to be carried out, so they are handed back here.
    public func captured() -> [String] { closedSpans }

    /// How many trailing characters of `text` could still grow into `tag`.
    private func partialTagSuffix(_ text: String, _ tag: String) -> Int {
        let max = Swift.min(tag.count - 1, text.count)
        guard max > 0 else { return 0 }
        for n in stride(from: max, through: 1, by: -1) {
            let tail = text.suffix(n)
            if tag.hasPrefix(tail) { return n }
        }
        return 0
    }
}
