from datetime import date

import numpy as np

from brain.freshness.pipeline import Evidence, freshness_score, label_for
from brain.phi_guard import PHIGuard, mask
from brain.router_linucb import Arm, LinUCBRouter, features, reward

guard = PHIGuard(use_presidio=False)


def test_phi_cnic_mrn_phone():
    r = guard.scan("Patient Ahmed Raza, CNIC 35202-1234567-1, MRN: 88231, call 0321-1234567")
    assert r.phi
    assert {"PK_CNIC", "MRN", "PK_PHONE", "NAMED_PATIENT"} <= set(r.types)


def test_no_phi_in_general_question():
    assert not guard.scan("What is the first-line treatment for type 2 diabetes?").phi


def test_mask_hides_identifiers():
    out = mask("CNIC 35202-1234567-1 email a.b@x.com")
    assert "35202" not in out and "a.b@x.com" not in out


def test_reward_shape():
    assert reward(False, "routine", 100, 0.1) == 0.0
    fast = reward(True, "emergency", 500, 0.5)
    slow = reward(True, "emergency", 9000, 0.5)
    assert 0 <= slow < fast <= 1


def test_bandit_learns_better_arm():
    arms = [Arm("p", "good", 1), Arm("p", "bad", 1)]
    r = LinUCBRouter(arms, alpha=0.3)
    x = features("routine", False, 100)
    rng = np.random.default_rng(0)
    for _ in range(300):
        arm, _ = r.choose(x)
        mean = 0.9 if arm.model == "good" else 0.3
        r.update(arm.key, x, float(np.clip(rng.normal(mean, 0.05), 0, 1)))
    assert r.pulls["p/good"] > r.pulls["p/bad"] * 3


def test_disabled_arm_is_skipped():
    r = LinUCBRouter([Arm("a", "x", 1), Arm("b", "y", 1)])
    r.disabled.add("a/x")
    arm, _ = r.choose(features("batch", False, 10))
    assert arm.key == "b/y"


def test_freshness_score_and_labels():
    today = date(2026, 11, 18)
    fresh_trusted = [Evidence("WHO", "https://www.who.int/news/x", "", "2026-10-01")]
    old = [Evidence("blog", "https://example.com/a", "", "2021-01-01")]
    assert freshness_score("supported", fresh_trusted, today) == 100
    assert freshness_score("contradicted", old, today) == 0
    assert label_for(freshness_score("unclear", [], today)) == "check"
    assert label_for(None) == "stable"
