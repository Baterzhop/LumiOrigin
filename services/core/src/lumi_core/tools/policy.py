from __future__ import annotations

from enum import StrEnum
from pydantic import BaseModel, Field


class RiskLevel(StrEnum):
    low = "low"
    medium = "medium"
    high = "high"
    critical = "critical"


class ToolSpec(BaseModel):
    name: str
    description: str
    risk: RiskLevel
    side_effects: bool = False
    timeout_seconds: float = Field(default=10, gt=0, le=120)
    arguments_schema: dict = Field(default_factory=dict)


class PolicyDecision(BaseModel):
    allowed: bool
    requires_confirmation: bool
    reason: str


class PolicyEngine:
    def evaluate(self, tool: ToolSpec, *, user_confirmed: bool = False) -> PolicyDecision:
        if tool.risk == RiskLevel.critical:
            return PolicyDecision(allowed=False, requires_confirmation=False, reason="critical_tools_disabled")
        if tool.risk == RiskLevel.high or tool.side_effects:
            if user_confirmed:
                return PolicyDecision(allowed=True, requires_confirmation=False, reason="explicit_user_confirmation")
            return PolicyDecision(allowed=False, requires_confirmation=True, reason="confirmation_required")
        return PolicyDecision(allowed=True, requires_confirmation=False, reason="policy_allows")
