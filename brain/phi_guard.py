"""PHI Guard: detects patient data in a prompt.

Two layers:
1. Regex rules that always run (fast, no model): Pakistani CNIC, MR numbers,
   +92 phone numbers, emails, dates of birth.
2. Microsoft Presidio (optional, if installed) for names, locations, dates.

Recall matters more than precision here: a missed identifier means patient
data could reach a cloud model, while a false alarm only costs a slower
local answer.
"""
from __future__ import annotations

import re
from dataclasses import dataclass, field

RULES: dict[str, re.Pattern] = {
    "PK_CNIC": re.compile(r"\b\d{5}-\d{7}-\d\b|\b\d{13}\b"),
    "MRN": re.compile(r"\b(?:MRN|MR\s?No\.?|MR#|medical record(?: number)?)\s*[:#-]?\s*[A-Z0-9-]{4,12}\b", re.I),
    "PK_PHONE": re.compile(r"(?:\+92|0092|\b0)3\d{2}[-\s]?\d{7}\b"),
    "EMAIL": re.compile(r"\b[\w.+-]+@[\w-]+\.[\w.-]+\b"),
    "DOB": re.compile(r"\b(?:DOB|D\.O\.B\.?|date of birth)\s*[:-]?\s*\d{1,2}[/-]\d{1,2}[/-]\d{2,4}\b", re.I),
    "NAMED_PATIENT": re.compile(r"\b(?i:patient|pt\.?|mr\.?|mrs\.?|ms\.?)\s+[A-Z][a-z]+(?:\s+[A-Z][a-z]+)?\b"),
}

PRESIDIO_ENTITIES = ["PERSON", "PHONE_NUMBER", "EMAIL_ADDRESS", "DATE_TIME", "LOCATION"]
PRESIDIO_MIN_SCORE = 0.6


@dataclass
class PHIResult:
    phi: bool
    types: list[str] = field(default_factory=list)
    count: int = 0


class PHIGuard:
    def __init__(self, use_presidio: bool = True):
        self._analyzer = None
        if use_presidio:
            try:
                from presidio_analyzer import AnalyzerEngine
                from presidio_analyzer.nlp_engine import NlpEngineProvider

                provider = NlpEngineProvider(nlp_configuration={
                    "nlp_engine_name": "spacy",
                    "models": [{"lang_code": "en", "model_name": "en_core_web_sm"}],
                })
                self._analyzer = AnalyzerEngine(nlp_engine=provider.create_engine())
            except Exception:  # Presidio or the spaCy model missing: regex only
                self._analyzer = None

    @property
    def presidio_enabled(self) -> bool:
        return self._analyzer is not None

    def scan(self, text: str) -> PHIResult:
        if not text:
            return PHIResult(phi=False)
        found: list[str] = []
        for name, pattern in RULES.items():
            found += [name] * len(pattern.findall(text))
        if self._analyzer is not None:
            for r in self._analyzer.analyze(text=text, entities=PRESIDIO_ENTITIES, language="en"):
                # DATE_TIME alone ("today", "2 weeks") is not PHI; count it only with another hit.
                if r.score >= PRESIDIO_MIN_SCORE and r.entity_type != "DATE_TIME":
                    found.append(r.entity_type)
        return PHIResult(phi=bool(found), types=sorted(set(found)), count=len(found))


def mask(text: str) -> str:
    """Replace regex-detected identifiers with tags (used for logs, never raw PHI)."""
    for name, pattern in RULES.items():
        text = pattern.sub(f"<{name}>", text)
    return text
