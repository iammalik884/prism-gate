// PRISM-Gate: a Bifrost native plugin for healthcare LLM traffic.
//
// It keeps prompts that contain patient data (PHI) on a local model, gives
// Emergency requests reserved capacity, and lets a learned router (a LinUCB
// contextual bandit in the Python "brain" service) pick the provider/model.
//
// Hooks used (public extension points of Bifrost):
//   - HTTPTransportPreHook : read x-prism-* headers into the request context
//   - PreRequestHook       : ask the brain for a decision, then set provider/model/fallbacks
//   - PreLLMHook           : priority-aware admission control
//   - PostLLMHook          : release the slot and report the outcome (reward) to the brain
//
// The plugin never blocks on the brain: if the brain is slow or down, the
// request keeps its original provider and Bifrost's own fallbacks.
package main

import (
	"fmt"
	"strings"
	"time"

	"github.com/maximhq/bifrost/core/schemas"
)

// Context keys (namespaced to avoid clashing with Bifrost's own keys).
const (
	ctxPriorityHint = schemas.BifrostContextKey("prism-priority-hint")
	ctxDepartment   = schemas.BifrostContextKey("prism-department")
	ctxDecision     = schemas.BifrostContextKey("prism-decision")
	ctxStart        = schemas.BifrostContextKey("prism-start")
	ctxSlotHeld     = schemas.BifrostContextKey("prism-slot-held")
	ctxBypass       = schemas.BifrostContextKey("prism-bypass")
)

var (
	cfg  = defaultConfig()
	gate *PriorityGate
	bc   *brainClient
)

// Init is called once when Bifrost loads the plugin. config = plugins[].config.
func Init(config any) error {
	if m, ok := config.(map[string]interface{}); ok {
		cfg.apply(m)
	}
	gate = NewPriorityGate(cfg.MaxConcurrent, cfg.EmergencyReserved)
	bc = newBrainClient(cfg.BrainURL, time.Duration(cfg.BrainTimeoutMS)*time.Millisecond)
	fmt.Printf("[prism-gate] loaded: brain=%s local=%s/%s slots=%d reserved=%d\n",
		cfg.BrainURL, cfg.LocalProvider, cfg.LocalModel, cfg.MaxConcurrent, cfg.EmergencyReserved)
	return nil
}

// GetName returns the plugin's system identifier.
func GetName() string { return "prism-gate" }

// Cleanup is called on shutdown.
func Cleanup() error { return nil }

// HTTPTransportPreHook copies PRISM headers into the context. Returning nil
// response means "continue normally".
func HTTPTransportPreHook(ctx *schemas.BifrostContext, req *schemas.HTTPRequest) (*schemas.HTTPResponse, error) {
	if p := req.CaseInsensitiveHeaderLookup("x-prism-priority"); p != "" {
		ctx.SetValue(ctxPriorityHint, strings.ToLower(strings.TrimSpace(p)))
	}
	// Baseline runs for the evaluation: same gateway, plugin logic switched off.
	if req.CaseInsensitiveHeaderLookup("x-prism-bypass") == "1" {
		ctx.SetValue(ctxBypass, true)
	}
	if d := req.CaseInsensitiveHeaderLookup("x-prism-department"); d != "" {
		ctx.SetValue(ctxDepartment, d)
	}
	return nil, nil
}

// HTTPTransportPostHook is unused but declared so all HTTP hooks resolve.
func HTTPTransportPostHook(ctx *schemas.BifrostContext, req *schemas.HTTPRequest, resp *schemas.HTTPResponse) error {
	return nil
}

// PreRequestHook runs once per request (routing phase). Changes to provider,
// model and fallbacks here apply to every attempt.
func PreRequestHook(ctx *schemas.BifrostContext, req *schemas.BifrostRequest) error {
	if req == nil || req.ChatRequest == nil || bypassed(ctx) {
		return nil // only chat completions are routed in this version
	}
	text := lastUserText(req.ChatRequest.Input)
	hint, _ := ctx.Value(ctxPriorityHint).(string)
	dept, _ := ctx.Value(ctxDepartment).(string)
	provider, model, _ := req.GetRequestFields()

	d := Decision{Priority: ClassifyPriority(hint, text), Provider: string(provider), Model: model, Reason: "default"}
	if bd, err := bc.Decide(DecideRequest{Text: text, PriorityHint: d.Priority, Department: dept, Provider: string(provider), Model: model}); err == nil {
		d = bd
	} else {
		// Fail closed for privacy: without the brain, keep the original route
		// only if the local rules find no patient data.
		d.Reason = "brain-unavailable"
		fmt.Printf("[prism-gate] brain unavailable (%v), using local PHI rules\n", err)
	}
	if !d.PHI && localPHI(text) {
		d.PHI = true
		d.Reason += "+local-phi-rule"
	}

	switch {
	case d.PHI:
		// Patient data never leaves: pin to the local model, no cloud fallbacks.
		req.SetProvider(schemas.ModelProvider(cfg.LocalProvider))
		req.SetModel(cfg.LocalModel)
		req.SetFallbacks(nil)
		d.Provider, d.Model = cfg.LocalProvider, cfg.LocalModel
	case d.Provider != "" && d.Model != "":
		req.SetProvider(schemas.ModelProvider(d.Provider))
		req.SetModel(d.Model)
	}
	ctx.SetValue(ctxDecision, d)
	fmt.Printf("[prism-gate] route priority=%s phi=%v -> %s/%s (%s)\n", d.Priority, d.PHI, d.Provider, d.Model, d.Reason)
	return nil
}

// PreLLMHook runs before each provider attempt: priority-aware admission.
func PreLLMHook(ctx *schemas.BifrostContext, req *schemas.BifrostRequest) (*schemas.BifrostRequest, *schemas.LLMPluginShortCircuit, error) {
	if bypassed(ctx) {
		return req, nil, nil
	}
	if held, _ := ctx.Value(ctxSlotHeld).(bool); !held {
		d, _ := ctx.Value(ctxDecision).(Decision)
		if !gate.Acquire(d.Priority, time.Duration(cfg.AdmitTimeoutMS)*time.Millisecond) {
			msg := "prism-gate: capacity reserved for emergency traffic, retry later"
			status := 429
			return req, &schemas.LLMPluginShortCircuit{Error: &schemas.BifrostError{
				StatusCode: &status,
				Error:      &schemas.ErrorField{Message: msg},
			}}, nil
		}
		ctx.SetValue(ctxSlotHeld, true)
	}
	if ctx.Value(ctxStart) == nil {
		ctx.SetValue(ctxStart, time.Now())
	}
	return req, nil, nil
}

// PostLLMHook releases the slot and reports the outcome to the bandit.
func PostLLMHook(ctx *schemas.BifrostContext, resp *schemas.BifrostResponse, bifrostErr *schemas.BifrostError) (*schemas.BifrostResponse, *schemas.BifrostError, error) {
	if held, _ := ctx.Value(ctxSlotHeld).(bool); held {
		gate.Release()
		ctx.SetValue(ctxSlotHeld, false)
	}
	d, ok := ctx.Value(ctxDecision).(Decision)
	if !ok {
		return resp, bifrostErr, nil
	}
	fb := Feedback{DecisionID: d.ID, Priority: d.Priority, Provider: d.Provider, Model: d.Model, Success: bifrostErr == nil}
	if start, ok := ctx.Value(ctxStart).(time.Time); ok {
		fb.LatencyMS = time.Since(start).Milliseconds()
	}
	if resp != nil && resp.ChatResponse != nil && resp.ChatResponse.Usage != nil {
		fb.PromptTokens = resp.ChatResponse.Usage.PromptTokens
		fb.CompletionTokens = resp.ChatResponse.Usage.CompletionTokens
	}
	go bc.Feedback(fb) // never delay the response
	return resp, bifrostErr, nil
}

func bypassed(ctx *schemas.BifrostContext) bool {
	b, _ := ctx.Value(ctxBypass).(bool)
	return b
}

// lastUserText returns the text of the last user message.
func lastUserText(msgs []schemas.ChatMessage) string {
	for i := len(msgs) - 1; i >= 0; i-- {
		m := msgs[i]
		if m.Role != schemas.ChatMessageRoleUser || m.Content == nil {
			continue
		}
		if m.Content.ContentStr != nil {
			return *m.Content.ContentStr
		}
		var b strings.Builder
		for _, blk := range m.Content.ContentBlocks {
			if blk.Text != nil {
				b.WriteString(*blk.Text)
				b.WriteString(" ")
			}
		}
		return strings.TrimSpace(b.String())
	}
	return ""
}
