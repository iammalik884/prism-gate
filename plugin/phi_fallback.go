package main

import "regexp"

// Local PHI rules inside the plugin. They run on every request, so patient
// data stays local even when the brain service is slow or down (fail-closed).
var phiRules = []*regexp.Regexp{
	regexp.MustCompile(`\b\d{5}-\d{7}-\d\b`), // Pakistani CNIC
	regexp.MustCompile(`\b\d{13}\b`),         // CNIC without dashes
	regexp.MustCompile(`(?i)\b(?:MRN|MR\s?No\.?|MR#|medical record(?: number)?)\s*[:#-]?\s*[A-Z0-9-]{4,12}\b`), // MR number
	regexp.MustCompile(`(?:\+92|0092|\b0)3\d{2}[-\s]?\d{7}\b`),                                                 // PK mobile
	regexp.MustCompile(`(?i)\b(?:DOB|date of birth)\s*[:-]?\s*\d{1,2}[/-]\d{1,2}[/-]\d{2,4}\b`),                // date of birth
}

// localPHI reports whether the text matches any local PHI rule.
func localPHI(text string) bool {
	for _, r := range phiRules {
		if r.MatchString(text) {
			return true
		}
	}
	return false
}
