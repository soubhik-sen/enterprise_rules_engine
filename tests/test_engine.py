import pytest
import sys
import os

# Add backend to path so we can import rule_parser
sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "backend")))

from rule_parser import evaluate_condition, evaluate_rule

def test_range_logical_correctness():
    """Verify boundary conditions for ranges."""
    assert evaluate_condition("10..50", 10) is True
    assert evaluate_condition("10..50", 50) is True
    assert evaluate_condition("10..50", 10.0) is True
    assert evaluate_condition("10..50", 9.99) is False
    assert evaluate_condition("10..50", 50.01) is False

def test_malformed_ranges_robustness():
    """Verify how the parser handles garbage or logically inverted ranges."""
    assert evaluate_condition("50..10", 30) is False
    assert evaluate_condition("10...50", 30) is False
    assert evaluate_condition("10..", 10) is False
    assert evaluate_condition("..50", 50) is False

def test_injection_security():
    """Verify that execution strings are treated as literals and not evaluated."""
    injection = "__import__('os').system('echo pwned')"
    
    # 1. As a standalone condition (should fail unless exactly equal)
    assert evaluate_condition(injection, "any") is False
    assert evaluate_condition(injection, injection) is True # Literal equality is fine
    
    # 2. Inside a range
    bad_range = f"10..50; {injection}"
    assert evaluate_condition(bad_range, 30) is False
    
    # 3. Inside IN clause (Unquoted)
    bad_in = f"IN ('Gold', {injection})"
    assert evaluate_condition(bad_in, "Gold") is True
    assert evaluate_condition(bad_in, injection) is False # Injection not quoted
    
    # 4. Quoted injection inside IN (Using double quotes to encapsulate single quotes safely)
    quoted_bad_in = f'IN ("Gold", "{injection}")'
    assert evaluate_condition(quoted_bad_in, injection) is True
    # If the above passes, it means the parser treated the injection as a literal string.

def test_escaped_quotes_and_mixed_quotes():
    """Verify the fix for complex strings in IN clauses."""
    # Single quotes inside double quotes
    assert evaluate_condition('IN ("O\'Connor", "Gold")', "O'Connor") is True
    
    # Escaped single quotes
    assert evaluate_condition("IN ('O\\'Connor', 'Gold')", "O'Connor") is True
    
    # Mixed quotes in set
    assert evaluate_condition("IN ('Gold', \"Silver Platinum\")", "Silver Platinum") is True

def test_type_error_resilience():
    """Verify that the parser doesn't crash on unexpected input types (LIST/DICT)."""
    # These should all return False gracefully instead of raising TypeError
    assert evaluate_condition("10..50", [20, 30]) is False
    assert evaluate_condition(">10", {"age": 20}) is False
    assert evaluate_condition("IN (1, 2, 3)", {"key": "val"}) is False

def test_large_payloads():
    """Test performance/correctness with large IN sets."""
    size = 5000
    items = [f"Item_{i}" for i in range(size)]
    items_str = ", ".join(['"' + item + '"' for item in items])
    condition = f"IN ({items_str})"
    
    assert evaluate_condition(condition, "Item_2500") is True
    assert evaluate_condition(condition, "Item_5001") is False

def test_type_coercion():
    """Test how engine handles mixed types."""
    assert evaluate_condition("18..65", "25") is True
    assert evaluate_condition("Gold", "Gold") is True
    assert evaluate_condition("100", 100) is True
    assert evaluate_condition("> 100", "150") is True

def test_full_rule_missing_keys():
    logic = {"inputs": {"age": "18..65", "type": "IN ('Gold', 'Silver')"}}
    context = {"age": 25} # Missing 'type'
    assert evaluate_rule(logic, context) is False

def test_hit_policy_logic():
    rule1 = {"inputs": {"age": "<18"}, "outputs": {"result": "Minor"}}
    rule2 = {"inputs": {"age": ">=18"}, "outputs": {"result": "Adult"}}
    
    assert evaluate_rule(rule1, {"age": 15}) is True
    assert evaluate_rule(rule1, {"age": 20}) is False
    assert evaluate_rule(rule2, {"age": 20}) is True

if __name__ == "__main__":
    pytest.main([__file__])
