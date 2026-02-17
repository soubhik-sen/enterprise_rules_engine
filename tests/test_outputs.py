import pytest
import sys
import os
from unittest.mock import MagicMock

# Add backend to path
sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))

from backend.engine import DecisionEngine
from backend.models import HitPolicy, DecisionRule

def test_multiple_output_attributes_single_rule():
    """Verify that a single rule can return multiple output attributes."""
    
    rule1 = MagicMock(spec=DecisionRule)
    rule1.id = "rule1"
    # Rule with 3 output attributes
    rule1.logic = {
        "inputs": {"category": "Electronics"},
        "outputs": {
            "tax_pct": 18,
            "shipping_days": 3,
            "handling_fee": 5.0
        }
    }
    
    table = MagicMock()
    table.slug = "commerce_rules"
    table.hit_policy = HitPolicy.FIRST_HIT
    table.rules = [rule1]
    
    db = MagicMock()
    db.query.return_value.filter.return_value.first.return_value = table
    
    context = {"category": "Electronics"}
    result = DecisionEngine.evaluate(db, "commerce_rules", context)
    
    # Assertions
    assert result["result"]["tax_pct"] == 18
    assert result["result"]["shipping_days"] == 3
    assert result["result"]["handling_fee"] == 5.0
    assert len(result["result"]) == 3

def test_multiple_output_attributes_collect_all():
    """Verify that 'COLLECT_ALL' merges multiple attributes from multiple matching rules."""
    
    # Rule 1 provides partial output
    rule1 = MagicMock(spec=DecisionRule)
    rule1.id = "rule1"
    rule1.logic = {
        "inputs": {"amount": ">100"},
        "outputs": {"discount_pct": 10, "label": "Voucher_Applied"}
    }
    
    # Rule 2 provides different partial output
    rule2 = MagicMock(spec=DecisionRule)
    rule2.id = "rule2"
    rule2.logic = {
        "inputs": {"user_tier": "VIP"},
        "outputs": {"shipping": "Free", "label": "VIP_Benefit"} # Overwrites 'label'
    }
    
    table = MagicMock()
    table.slug = "promotion_rules"
    table.hit_policy = HitPolicy.COLLECT_ALL
    table.rules = [rule1, rule2]
    
    db = MagicMock()
    db.query.return_value.filter.return_value.first.return_value = table
    
    context = {"amount": 500, "user_tier": "VIP"}
    result = DecisionEngine.evaluate(db, "promotion_rules", context)
    
    # Verify Merging
    # COLLECT_ALL uses .update(), so later rules overwrite earlier ones for the same key
    assert result["result"]["discount_pct"] == 10
    assert result["result"]["shipping"] == "Free"
    assert result["result"]["label"] == "VIP_Benefit"
    assert len(result["result"]) == 3

def test_empty_outputs_stability():
    """Ensure engine doesn't crash if a matching rule has no outputs."""
    rule1 = MagicMock(spec=DecisionRule)
    rule1.id = "rule1"
    rule1.logic = {"inputs": {"age": ">18"}, "outputs": {}}
    
    table = MagicMock()
    table.slug = "empty_test"
    table.hit_policy = HitPolicy.FIRST_HIT
    table.rules = [rule1]
    
    db = MagicMock()
    db.query.return_value.filter.return_value.first.return_value = table
    
    result = DecisionEngine.evaluate(db, "empty_test", {"age": 20})
    assert result["result"] == {}

if __name__ == "__main__":
    pytest.main([__file__])
