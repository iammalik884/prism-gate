package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"time"
)

// DecideRequest is sent to the brain's POST /decide.
type DecideRequest struct {
	Text         string `json:"text"`
	PriorityHint string `json:"priority_hint"`
	Department   string `json:"department,omitempty"`
	Provider     string `json:"provider"`
	Model        string `json:"model"`
}

// Decision is the brain's answer.
type Decision struct {
	ID       string   `json:"id"`
	PHI      bool     `json:"phi"`
	PHITypes []string `json:"phi_types"`
	Priority string   `json:"priority"`
	Provider string   `json:"provider"`
	Model    string   `json:"model"`
	Reason   string   `json:"reason"`
}

// Feedback is sent to POST /feedback after each attempt (bandit reward).
type Feedback struct {
	DecisionID       string `json:"decision_id"`
	Priority         string `json:"priority"`
	Provider         string `json:"provider"`
	Model            string `json:"model"`
	Success          bool   `json:"success"`
	LatencyMS        int64  `json:"latency_ms"`
	PromptTokens     int    `json:"prompt_tokens"`
	CompletionTokens int    `json:"completion_tokens"`
}

type brainClient struct {
	base string
	fast *http.Client // decisions: strict timeout, gateway must not wait
	slow *http.Client // feedback: async, more patient
}

func newBrainClient(base string, timeout time.Duration) *brainClient {
	if timeout <= 0 {
		timeout = 50 * time.Millisecond
	}
	return &brainClient{
		base: base,
		fast: &http.Client{Timeout: timeout},
		slow: &http.Client{Timeout: 2 * time.Second},
	}
}

func (c *brainClient) Decide(r DecideRequest) (Decision, error) {
	var d Decision
	body, _ := json.Marshal(r)
	resp, err := c.fast.Post(c.base+"/decide", "application/json", bytes.NewReader(body))
	if err != nil {
		return d, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return d, fmt.Errorf("brain /decide status %d", resp.StatusCode)
	}
	err = json.NewDecoder(resp.Body).Decode(&d)
	return d, err
}

func (c *brainClient) Feedback(f Feedback) {
	body, _ := json.Marshal(f)
	resp, err := c.slow.Post(c.base+"/feedback", "application/json", bytes.NewReader(body))
	if err == nil {
		resp.Body.Close()
	}
}
