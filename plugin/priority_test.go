package main

import (
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func TestClassifyPriority(t *testing.T) {
	cases := []struct{ hint, text, want string }{
		{"emergency", "anything", PriorityEmergency},
		{"", "Patient with crushing chest pain and sweating", PriorityEmergency},
		{"", "What is the usual dosage of amoxicillin for adults?", PriorityClinical},
		{"", "Summarize all discharge summaries from last night", PriorityBatch},
		{"", "Write a polite email to the vendor", PriorityRoutine},
		{"bogus", "hello", PriorityRoutine},
	}
	for _, c := range cases {
		if got := ClassifyPriority(c.hint, c.text); got != c.want {
			t.Errorf("ClassifyPriority(%q,%q)=%s want %s", c.hint, c.text, got, c.want)
		}
	}
}

func TestGateReservesCapacityForEmergency(t *testing.T) {
	g := NewPriorityGate(3, 1)
	if !g.Acquire(PriorityRoutine, 10*time.Millisecond) || !g.Acquire(PriorityRoutine, 10*time.Millisecond) {
		t.Fatal("routine should get the two unreserved slots")
	}
	if g.Acquire(PriorityRoutine, 20*time.Millisecond) {
		t.Fatal("routine must not take the reserved slot")
	}
	if !g.Acquire(PriorityEmergency, 10*time.Millisecond) {
		t.Fatal("emergency must get the reserved slot")
	}
	if g.InUse() != 3 {
		t.Fatalf("in use = %d, want 3", g.InUse())
	}
}

func TestGateReleaseWakesWaiter(t *testing.T) {
	g := NewPriorityGate(1, 0)
	g.Acquire(PriorityRoutine, time.Millisecond)
	done := make(chan bool)
	go func() { done <- g.Acquire(PriorityClinical, time.Second) }()
	time.Sleep(20 * time.Millisecond)
	g.Release()
	if !<-done {
		t.Fatal("waiter should be admitted after release")
	}
}

func TestBrainTimeoutFallsBack(t *testing.T) {
	slow := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		time.Sleep(200 * time.Millisecond)
	}))
	defer slow.Close()
	c := newBrainClient(slow.URL, 30*time.Millisecond)
	start := time.Now()
	if _, err := c.Decide(DecideRequest{Text: "x"}); err == nil {
		t.Fatal("expected timeout error")
	}
	if time.Since(start) > 150*time.Millisecond {
		t.Fatal("decide must not block the gateway")
	}
}
