"""RL Router: a LinUCB contextual bandit that picks a (provider, model) arm.

Context features (9): one-hot priority (4), PHI flag, prompt-length bucket (3), bias.
Reward in [0, 1]: 0 on failure; on success 1 minus weighted latency and cost
penalties. The weights depend on priority: Emergency cares most about latency,
Batch most about cost.

Cost uses relative units from config/arms.json (not USD) unless real prices
are filled in there.
"""
from __future__ import annotations

import json
import threading
from dataclasses import dataclass
from pathlib import Path

import numpy as np

PRIORITIES = ["emergency", "clinical", "routine", "batch"]
LATENCY_CAP_MS = 10_000.0

# (latency weight, cost weight) per priority
WEIGHTS = {
    "emergency": (0.7, 0.1),
    "clinical": (0.4, 0.3),
    "routine": (0.3, 0.5),
    "batch": (0.1, 0.8),
}


@dataclass
class Arm:
    provider: str
    model: str
    relative_cost: float  # per 1k tokens, relative units; normalised by the max arm

    @property
    def key(self) -> str:
        return f"{self.provider}/{self.model}"


def load_arms(path: str | Path) -> list[Arm]:
    data = json.loads(Path(path).read_text())
    return [Arm(a["provider"], a["model"], float(a["relative_cost"])) for a in data["arms"]]


def features(priority: str, phi: bool, prompt_chars: int) -> np.ndarray:
    x = np.zeros(9)
    x[PRIORITIES.index(priority) if priority in PRIORITIES else 2] = 1.0
    x[4] = 1.0 if phi else 0.0
    bucket = 0 if prompt_chars < 500 else (1 if prompt_chars < 3000 else 2)
    x[5 + bucket] = 1.0
    x[8] = 1.0
    return x


def reward(success: bool, priority: str, latency_ms: float, cost_norm: float) -> float:
    if not success:
        return 0.0
    w_lat, w_cost = WEIGHTS.get(priority, WEIGHTS["routine"])
    lat = min(latency_ms / LATENCY_CAP_MS, 1.0)
    return float(max(0.0, 1.0 - w_lat * lat - w_cost * min(cost_norm, 1.0)))


class LinUCBRouter:
    def __init__(self, arms: list[Arm], alpha: float = 0.6, dim: int = 9):
        if not arms:
            raise ValueError("at least one arm is required")
        self.arms = arms
        self.alpha = alpha
        self.dim = dim
        self.A = {a.key: np.identity(dim) for a in arms}
        self.b = {a.key: np.zeros(dim) for a in arms}
        self.pulls = {a.key: 0 for a in arms}
        self.total_reward = 0.0
        self.history: list[dict] = []  # for the learning curve
        self.disabled: set[str] = set()
        self._lock = threading.Lock()
        self._max_cost = max(a.relative_cost for a in arms) or 1.0

    def cost_norm(self, arm_key: str, tokens: int) -> float:
        arm = next(a for a in self.arms if a.key == arm_key)
        return (arm.relative_cost / self._max_cost) * min(tokens / 2000.0, 1.0)

    def choose(self, x: np.ndarray) -> tuple[Arm, dict[str, float]]:
        with self._lock:
            scores: dict[str, float] = {}
            for a in self.arms:
                if a.key in self.disabled:
                    continue
                A_inv = np.linalg.inv(self.A[a.key])
                theta = A_inv @ self.b[a.key]
                scores[a.key] = float(theta @ x + self.alpha * np.sqrt(x @ A_inv @ x))
            if not scores:  # everything disabled: fall back to all arms
                scores = {a.key: 0.0 for a in self.arms}
            best = max(scores, key=scores.get)
            return next(a for a in self.arms if a.key == best), scores

    def update(self, arm_key: str, x: np.ndarray, r: float) -> None:
        with self._lock:
            if arm_key not in self.A:
                return
            self.A[arm_key] += np.outer(x, x)
            self.b[arm_key] += r * x
            self.pulls[arm_key] += 1
            self.total_reward += r
            self.history.append({"n": len(self.history) + 1, "arm": arm_key, "reward": r})

    def stats(self) -> dict:
        with self._lock:
            n = len(self.history)
            return {
                "updates": n,
                "mean_reward": (self.total_reward / n) if n else None,
                "pulls": dict(self.pulls),
                "disabled": sorted(self.disabled),
                "recent": self.history[-200:],
            }
