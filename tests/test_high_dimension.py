import pytest
import sys
import os
import time

# Add backend to path
sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))

from backend.rule_parser import evaluate_rule

def test_high_dimensional_delivery_rules():
    """
    Scenario: Finding acceptable delivery windows with 11 attributes.
    Attributes: source, dest, customer, supplier, priority, sla, weight, distance, temp_mode, insurance, day_of_week
    """
    
    # Define a complex rule for Next-Day Express Delivery
    logic = {
        "inputs": {
            "source": "IN ('NYC', 'PHL', 'BOS')",
            "destination": "IN ('DC', 'BAL', 'RIC')",
            "customer_tier": "IN ('Platinum', 'Gold')",
            "supplier_code": "IN ('FEDX', 'UPSN')",
            "delivery_priority": "Express",
            "service_level_agreement": "24H",
            "package_weight_kg": "0..30",
            "route_distance_miles": "<400",
            "temperature_requirement": "IN ('Ambient', 'None')",
            "insurance_covered": "True",
            "order_day": "IN ('Mon', 'Tue', 'Wed', 'Thu')"
        },
        "outputs": {
            "delivery_window": "08:00-12:00",
            "cost_multiplier": 1.5
        }
    }
    
    # 1. PERFECT MATCH CASE
    context_match = {
        "source": "NYC",
        "destination": "DC",
        "customer_tier": "Platinum",
        "supplier_code": "FEDX",
        "delivery_priority": "Express",
        "service_level_agreement": "24H",
        "package_weight_kg": 15.5,
        "route_distance_miles": 225,
        "temperature_requirement": "Ambient",
        "insurance_covered": "True",
        "order_day": "Tue"
    }
    
    start_time = time.perf_counter()
    is_match = evaluate_rule(logic, context_match)
    end_time = time.perf_counter()
    
    assert is_match is True
    print(f"\n[Performance] High-dimensional match evaluated in {(end_time - start_time)*1000:.4f}ms")

    # 2. FAIL ON ATTRIBUTE #7 (Weight)
    context_fail_weight = context_match.copy()
    context_fail_weight["package_weight_kg"] = 50 # Limit is 30
    assert evaluate_rule(logic, context_fail_weight) is False

    # 3. FAIL ON ATTRIBUTE #11 (Day of week)
    context_fail_day = context_match.copy()
    context_fail_day["order_day"] = "Fri" # Limit is Mon-Thu
    assert evaluate_rule(logic, context_fail_day) is False

    # 4. FAIL ON ATTRIBUTE #1 (Source)
    context_fail_source = context_match.copy()
    context_fail_source["source"] = "LAX"
    assert evaluate_rule(logic, context_fail_source) is False

    # 5. MISSING ATTRIBUTE
    context_missing = context_match.copy()
    del context_missing["insurance_covered"]
    assert evaluate_rule(logic, context_missing) is False

def test_large_rule_set_performance():
    """
    Test evaluation speed against 100 rules, each with 10 attributes.
    """
    num_rules = 100
    big_rule_set = []
    
    for i in range(num_rules):
        rule = {
            "inputs": {
                f"attr_{j}": f"IN ('val_{i}_{j}', 'other')" for j in range(10)
            },
            "outputs": {"rule_id": i}
        }
        big_rule_set.append(rule)
        
    # Context that matches the 50th rule
    context = {f"attr_{j}": f"val_50_{j}" for j in range(10)}
    
    start_time = time.perf_counter()
    matches = [r for r in big_rule_set if evaluate_rule(r, context)]
    end_time = time.perf_counter()
    
    assert len(matches) == 1
    assert matches[0]["outputs"]["rule_id"] == 50
    print(f"\n[Performance] Scanned {num_rules} rules (10 attrs each) in {(end_time - start_time)*1000:.2f}ms")

if __name__ == "__main__":
    pytest.main([__file__, "-s"])
