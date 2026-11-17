package main

import "testing"

func TestLocalPHI(t *testing.T) {
	yes := []string{
		"Patient CNIC 35202-1234567-1 has fever",
		"MRN: 88231 follow up",
		"call 0321-1234567 tomorrow",
		"+923211234567",
		"DOB 12/04/1990",
	}
	no := []string{
		"What is the first-line treatment for type 2 diabetes?",
		"Dose of amoxicillin 500 mg three times a day",
	}
	for _, s := range yes {
		if !localPHI(s) {
			t.Errorf("expected PHI in %q", s)
		}
	}
	for _, s := range no {
		if localPHI(s) {
			t.Errorf("unexpected PHI in %q", s)
		}
	}
}
