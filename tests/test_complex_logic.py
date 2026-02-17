import pytest
import sys
import os
from unittest.mock import MagicMock

# Add backend to path
sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))

from backend.rule_parser import evaluate_condition, evaluate_rule
from backend.engine import DecisionEngine
from backend.models import HitPolicy, DecisionRule

def test_complex_intersection_logic():
    """
    Scenario: 'Global Discount' table
    - user_age: 18..25, 26..60, >60
    - account_type: IN ('Gold', 'Platinum'), IN ('Silver')
    - purchase_value: >500, <=500
    """
    
    # Rule: Young Gold/Platinum High Spenders
    logic = {
        "inputs": {
            "user_age": "18..25",
            "account_type": "IN ('Gold', 'Platinum')",
            "purchase_value": ">500"
        },
        "outputs": {"discount": 20}
    }
    
    # Matching Case
    context_match = {
        "user_age": 22,
        "account_type": "Gold",
        "purchase_value": 600
    }
    assert evaluate_rule(logic, context_match) is True
    
    # Failing one condition: Age outside range
    context_fail_age = {
        "user_age": 30,
        "account_type": "Gold",
        "purchase_value": 600
    }
    assert evaluate_rule(logic, context_fail_age) is False
    
    # Failing one condition: Wrong account type
    context_fail_type = {
        "user_age": 22,
        "account_type": "Silver",
        "purchase_value": 600
    }
    assert evaluate_rule(logic, context_fail_type) is False
    
    # Failing one condition: Value too low
    context_fail_value = {
        "user_age": 22,
        "account_type": "Platinum",
        "purchase_value": 400
    }
    assert evaluate_rule(logic, context_fail_value) is False

def test_null_missing_attribute():
    """Null Values: What happens if account_type is missing?"""
    logic = {
        "inputs": {
            "user_age": "18..25",
            "account_type": "IN ('Gold', 'Platinum')"
        }
    }
    
    # Context missing 'account_type'
    context = {"user_age": 20}
    
    # According to evaluate_rule, if key not in context, it returns False.
    assert evaluate_rule(logic, context) is False

def test_type_mismatch_adversarial():
    """Type Mismatch: Input a string 'fifty' into a numeric range rule."""
    # This should not crash and should return False
    assert evaluate_condition("18..25", "thirty") is False
    assert evaluate_condition(">500", "too_much") is False

def test_boundary_overlap_first_hit():
    """Boundary Overlap: 10..50 and 50..100 on input 50."""
    
    rule1 = MagicMock(spec=DecisionRule)
    rule1.id = "rule1"
    rule1.logic = {"inputs": {"val": "10..50"}, "outputs": {"result": "A"}}
    
    rule2 = MagicMock(spec=DecisionRule)
    rule2.id = "rule2"
    rule2.logic = {"inputs": {"val": "50..100"}, "outputs": {"result": "B"}}
    
    table = MagicMock()
    table.slug = "overlap_test"
    table.hit_policy = HitPolicy.FIRST_HIT
    table.rules = [rule1, rule2] # Priority by list order
    
    db = MagicMock()
    db.query.return_value.filter.return_value.first.return_value = table
    
    context = {"val": 50}
    
    # Evaluation
    result = DecisionEngine.evaluate(db, "overlap_test", context)
    
    # With FIRST_HIT and 50 being in both ranges (10..50 and 50..100 are both inclusive)
    # it should return result of rule1 ("A")
    assert result["result"]["result"] == "A"
    assert result["rule_id"] == "rule1"

def test_all_discount_scenarios():
    """Mathematical Verification of the Global Discount Table."""
    rules = [
        {"inputs": {"user_age": "18..25", "account_type": "IN ('Gold', 'Platinum')", "purchase_value": ">500"}, "outputs": {"discount": 20}},
        {"inputs": {"user_age": "26..60", "account_type": "IN ('Gold', 'Platinum')", "purchase_value": ">500"}, "outputs": {"discount": 15}},
        {"inputs": {"user_age": ">60", "purchase_value": ">500"}, "outputs": {"discount": 25}}, # Senior discount
        {"inputs": {"account_type": "IN ('Silver')", "purchase_value": ">500"}, "outputs": {"discount": 10}},
        {"inputs": {"purchase_value": "<=500"}, "outputs": {"discount": 0}}
    ]
    
    # Senior (Age 70, Value 1000) -> 25%
    senior_context = {"user_age": 70, "purchase_value": 1000}
    assert evaluate_rule(rules[2], senior_context) is True
    
    # Mid-age Gold (Age 40, Type Gold, Value 1000) -> 15%
    mid_gold_context = {"user_age": 40, "account_type": "Gold", "purchase_value": 1000}
    assert evaluate_rule(rules[1], mid_gold_context) is True
    
    # Silver (Any age, Type Silver, Value 600) -> 10%
    silver_context = {"user_age": 30, "account_type": "Silver", "purchase_value": 600}
    assert evaluate_rule(rules[3], silver_context) is True

if __name__ == "__main__":
    pytest.main([__file__])
