package main

import (
	"strings"
	"sync"
	"time"
)

// Priority classes, highest first.
const (
	PriorityEmergency = "emergency"
	PriorityClinical  = "clinical"
	PriorityRoutine   = "routine"
	PriorityBatch     = "batch"
)

var emergencyTerms = []string{
	"chest pain", "cardiac arrest", "stroke", "overdose", "anaphylaxis", "unconscious",
	"not breathing", "severe bleeding", "seizure", "sepsis", "stat ", "code blue", "suicidal",
}

var clinicalTerms = []string{
	"dose", "dosage", "diagnosis", "patient", "symptom", "treatment", "drug interaction",
	"contraindication", "lab result", "prescription", "guideline", "side effect",
}

var batchTerms = []string{"summarize all", "batch", "discharge summaries", "nightly", "bulk"}

// ClassifyPriority uses the header hint when valid, else simple keyword rules.
// The brain may override this with a better classifier.
func ClassifyPriority(hint, text string) string {
	switch hint {
	case PriorityEmergency, PriorityClinical, PriorityRoutine, PriorityBatch:
		return hint
	}
	t := " " + strings.ToLower(text) + " "
	for _, k := range emergencyTerms {
		if strings.Contains(t, k) {
			return PriorityEmergency
		}
	}
	for _, k := range batchTerms {
		if strings.Contains(t, k) {
			return PriorityBatch
		}
	}
	for _, k := range clinicalTerms {
		if strings.Contains(t, k) {
			return PriorityClinical
		}
	}
	return PriorityRoutine
}

// PriorityGate is admission control with capacity reserved for Emergency.
// Emergency may use any free slot; other classes may only use a slot while
// more than `reserved` slots stay free. Batch gives up sooner than others.
type PriorityGate struct {
	mu       sync.Mutex
	cond     *sync.Cond
	max      int
	reserved int
	inUse    int
}

func NewPriorityGate(max, reserved int) *PriorityGate {
	if max < 1 {
		max = 1
	}
	if reserved < 0 || reserved >= max {
		reserved = max / 4
	}
	g := &PriorityGate{max: max, reserved: reserved}
	g.cond = sync.NewCond(&g.mu)
	return g
}

func (g *PriorityGate) canAdmit(priority string) bool {
	free := g.max - g.inUse
	if priority == PriorityEmergency {
		return free > 0
	}
	return free > g.reserved
}

// Acquire waits up to timeout for a slot. Batch waits a quarter of it.
func (g *PriorityGate) Acquire(priority string, timeout time.Duration) bool {
	if priority == PriorityBatch {
		timeout /= 4
	}
	deadline := time.Now().Add(timeout)
	g.mu.Lock()
	defer g.mu.Unlock()
	for !g.canAdmit(priority) {
		remaining := time.Until(deadline)
		if remaining <= 0 {
			return false
		}
		// Wake up periodically to re-check the deadline.
		t := time.AfterFunc(minDur(remaining, 50*time.Millisecond), func() {
			g.mu.Lock()
			g.cond.Broadcast()
			g.mu.Unlock()
		})
		g.cond.Wait()
		t.Stop()
	}
	g.inUse++
	return true
}

// Release frees one slot.
func (g *PriorityGate) Release() {
	g.mu.Lock()
	if g.inUse > 0 {
		g.inUse--
	}
	g.cond.Broadcast()
	g.mu.Unlock()
}

// InUse reports the slots currently taken (for tests and metrics).
func (g *PriorityGate) InUse() int {
	g.mu.Lock()
	defer g.mu.Unlock()
	return g.inUse
}

func minDur(a, b time.Duration) time.Duration {
	if a < b {
		return a
	}
	return b
}
