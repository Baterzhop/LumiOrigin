from lumi_core.tools.policy import PolicyEngine, RiskLevel, ToolSpec


def test_read_only_low_risk_tool_is_allowed():
    decision = PolicyEngine().evaluate(ToolSpec(name="search", description="Search", risk=RiskLevel.low))
    assert decision.allowed is True
    assert decision.requires_confirmation is False


def test_side_effect_requires_confirmation():
    tool = ToolSpec(name="write_file", description="Write", risk=RiskLevel.high, side_effects=True)
    denied = PolicyEngine().evaluate(tool)
    allowed = PolicyEngine().evaluate(tool, user_confirmed=True)
    assert denied.allowed is False
    assert denied.requires_confirmation is True
    assert allowed.allowed is True
