import re
import fnmatch
from typing import Any, Dict

_SIGNED_NUMBER = r'[-+]?(?:\d+(?:\.\d+)?|\.\d+)'

def parse_range(s: str, input_value: Any) -> bool:
    """Parses 'min..max' syntax."""
    match = re.match(rf'^({_SIGNED_NUMBER})\.\.({_SIGNED_NUMBER})$', s)
    if match:
        try:
            val = float(input_value)
            min_v, max_v = float(match.group(1)), float(match.group(2))
            return min_v <= val <= max_v
        except (ValueError, TypeError):
            return False
    return False

def parse_comparison(s: str, input_value: Any) -> bool:
    """Parses '>10', '<=5.5', etc."""
    match = re.match(rf'^(>|>=|<|<=)\s*({_SIGNED_NUMBER})$', s)
    if match:
        try:
            val = float(input_value)
            op, limit = match.group(1), float(match.group(2))
            if op == '>': return val > limit
            if op == '>=': return val >= limit
            if op == '<': return val < limit
            if op == '<=': return val <= limit
        except (ValueError, TypeError):
            return False
    return False

def parse_in_operator(s: str, input_value: Any) -> bool:
    """
    Parses 'IN (val1, val2, ...)' syntax using Regex.
    Avoids ast.literal_eval for security.
    Supports escaped quotes and mixed quotes.
    """
    match = re.match(r'(?i)^IN\s*\((.*)\)$', s)
    if not match:
        return False
    
    inner = match.group(1)
    
    if isinstance(input_value, (int, float)):
        # Extract numbers: -123, 45.67
        items = re.findall(r"([-+]?\d*\.\d+|[-+]?\d+)", inner)
        try:
            val = float(input_value)
            return any(float(item) == val for item in items)
        except (ValueError, TypeError):
            return False
    else:
        # Improved Regex to handle escaped quotes: 'O\'Connor' or "O'Connor"
        # Matches content within single or double quotes, allowing escaped characters
        pattern = r"'(?P<sq>(?:[^'\\]|\\.)*)'|\"(?P<dq>(?:[^\"\\]|\\.)*)\""
        matches = re.finditer(pattern, inner)
        items = []
        for m in matches:
            content = m.group('sq') if m.group('sq') is not None else m.group('dq')
            # Unescape characters (e.g., \' -> ')
            items.append(content.replace("\\'", "'").replace('\\"', '"'))
        
        return str(input_value) in items


def parse_cp_operator(s: str, input_value: Any) -> bool:
    """
    Parses SAP-style contains-pattern syntax:
    - CP <pattern>
    Wildcards supported:
    - * : any sequence
    - + : any single character
    """
    match = re.match(r'(?i)^CP\s+(.+)$', s.strip())
    if not match:
        return False
    raw_pattern = match.group(1).strip()
    if not raw_pattern:
        return False

    if (
        len(raw_pattern) >= 2
        and raw_pattern[0] == raw_pattern[-1]
        and raw_pattern[0] in {"'", '"'}
    ):
        raw_pattern = raw_pattern[1:-1]

    # SAP CP single-char wildcard '+' maps to fnmatch '?'
    pattern = raw_pattern.replace("+", "?")
    if not pattern:
        return False
    return fnmatch.fnmatchcase(str(input_value), pattern)

def evaluate_condition(condition_str: str, input_value: Any) -> bool:
    """
    Main entry point for condition evaluation.
    Supports: Range (..), Comparison (>, <, >=, <=), Set (IN), and Equality.
    Now robust against TypeError (e.g. passing list/dict to numeric rules).
    """
    matched, _ = evaluate_condition_with_reason(condition_str, input_value)
    return matched


def evaluate_condition_with_reason(condition_str: Any, input_value: Any) -> tuple[bool, str]:
    """
    Evaluates a single condition and returns (matched, reason).
    Blank condition behaves as wildcard and matches any value.
    """
    s = str(condition_str or "").strip()

    if s == "":
        return True, "blank condition (wildcard)"
    if input_value is None:
        return False, "input value is missing"

    # 1. CP Operator Check
    if s.upper().startswith("CP"):
        ok = parse_cp_operator(s, input_value)
        return ok, "pattern matched" if ok else "pattern mismatch"

    # 2. Range Check
    if ".." in s:
        if not re.match(rf'^({_SIGNED_NUMBER})\.\.({_SIGNED_NUMBER})$', s):
            return False, "invalid range syntax"
        ok = parse_range(s, input_value)
        return ok, "value in range" if ok else "value outside range"

    # 3. Comparison Check
    if re.match(r'^(>=|<=|>|<)', s):
        if not re.match(rf'^(>|>=|<|<=)\s*({_SIGNED_NUMBER})$', s):
            return False, "invalid comparison syntax"
        ok = parse_comparison(s, input_value)
        return ok, "comparison matched" if ok else "comparison failed"

    # 4. IN Operator Check
    if s.upper().startswith("IN"):
        if not re.match(r'(?i)^IN\s*\(.*\)$', s):
            return False, "invalid IN syntax"
        ok = parse_in_operator(s, input_value)
        return ok, "value in set" if ok else "value not in set"

    # 5. Fallback: Exact Equality
    try:
        # Try numeric comparison first
        if isinstance(input_value, (int, float)):
             ok = float(s) == float(input_value)
             return ok, "numeric equality matched" if ok else "numeric equality failed"
    except (ValueError, TypeError):
        pass

    ok = s == str(input_value)
    return ok, "exact match" if ok else "exact mismatch"

def evaluate_rule(logic: Dict[str, Any], context: Dict[str, Any]) -> bool:
    """
    Evaluates a full rule logic against a context.
    Match(R) iff every input condition is satisfied.
    
    logic: {"inputs": {"age": "18..65", "type": "IN ('Gold', 'Silver')"}, ...}
    context: {"age": 25, "type": "Gold"}
    """
    return evaluate_rule_with_trace(logic, context)["matched"]


def evaluate_rule_with_trace(logic: Dict[str, Any], context: Dict[str, Any]) -> Dict[str, Any]:
    """
    Evaluates rule and returns trace details for each input column.
    Blank condition is treated as wildcard.
    """
    inputs = logic.get("inputs", {}) or {}
    if not inputs:
        return {
            "matched": True,
            "field_results": [],
            "summary": "Rule has no input conditions",
        }

    field_results = []
    matched = True
    failed_fields = []
    for key, condition in inputs.items():
        condition_text = "" if condition is None else str(condition)
        if condition_text.strip() == "":
            field_results.append(
                {
                    "field": key,
                    "condition": "",
                    "actual": context.get(key),
                    "matched": True,
                    "reason": "blank condition (wildcard)",
                }
            )
            continue

        if key not in context:
            matched = False
            failure = {
                "field": key,
                "condition": condition_text,
                "actual": None,
                "matched": False,
                "reason": "input missing in context",
            }
            field_results.append(failure)
            failed_fields.append(failure)
            continue

        result, reason = evaluate_condition_with_reason(condition_text, context.get(key))
        item = {
            "field": key,
            "condition": condition_text,
            "actual": context.get(key),
            "matched": result,
            "reason": reason,
        }
        field_results.append(item)
        if not result:
            matched = False
            failed_fields.append(item)

    return {
        "matched": matched,
        "field_results": field_results,
        "failed_fields": failed_fields,
        "summary": "matched" if matched else "failed",
    }
def validate_syntax(condition_str: str) -> bool:
    """
    Checks if the condition string has valid syntax and logical sense.
    Returns True if valid, False if it contains 'garbage' syntax (e.g., inverted ranges).
    """
    s = str(condition_str).strip()
    
    # 1. Check for Range Syntax
    range_match = re.match(rf'^({_SIGNED_NUMBER})\.\.({_SIGNED_NUMBER})$', s)
    if range_match:
        try:
            min_v, max_v = float(range_match.group(1)), float(range_match.group(2))
            if min_v > max_v:
                return False # Inverted range is 'garbage'
            return True
        except ValueError:
            return False

    # 2. Check for Comparison Syntax
    if any(op in s for op in [">", "<"]):
        if re.match(rf'^(>|>=|<|<=)\s*({_SIGNED_NUMBER})$', s):
            return True
        # If it has > or < but doesn't match the regex, it might be malformed
        if any(s.startswith(op) for op in [">", "<"]):
            return False

    # 3. Check for IN Syntax
    if s.upper().startswith("IN"):
        # Must match IN (...) structure
        if not re.match(r'(?i)^IN\s*\(.*\)$', s):
            return False
        # Optionally could check if it contains valid quoted strings or numbers
        return True

    # 4. Check for CP Syntax
    if s.upper().startswith("CP"):
        match = re.match(r'(?i)^CP\s+(.+)$', s)
        if not match:
            return False
        pattern = match.group(1).strip()
        if (
            len(pattern) >= 2
            and pattern[0] == pattern[-1]
            and pattern[0] in {"'", '"'}
        ):
            pattern = pattern[1:-1]
        return bool(pattern)

    # 5. Fallback: Everything else is treated as literal equality, which is always "syntactically" valid
    return True
def validate_rule_against_schema(rule_logic: Dict[str, Any], input_schema: Dict[str, str], output_schema: Dict[str, str]) -> None:
    """
    Validates rule logic against the allowed schema.
    Raises ValueError if a key is not present in the schema or if types are incompatible.
    """
    inputs = rule_logic.get("inputs", {})
    outputs = rule_logic.get("outputs", {})

    # 1. Check for required fields (assuming all schema fields are required for now)
    for key in input_schema:
        if key not in inputs:
            raise ValueError(f"Missing required input field '{key}'")

    for key, condition in inputs.items():
        if key not in input_schema:
            raise ValueError(f"Input field '{key}' not defined in table schema")
        
        # 2. Type Poisoning Check
        field_type = input_schema[key].lower()
        condition_str = str(condition)
        stripped = condition_str.strip()
        is_cp = bool(re.match(r'(?i)^CP\s+.+$', stripped))
        is_numeric_range = bool(
            re.match(rf'^({_SIGNED_NUMBER})\.\.({_SIGNED_NUMBER})$', stripped)
        )
        has_comparison_prefix = bool(re.match(r'^(>=|<=|>|<)', stripped))
        
        if field_type == "boolean":
            # Boolean fields should only allow exact match 'True'/'False' or 'IN' with booleans
            # Range or Comparison is mathematically incompatible
            if is_numeric_range or has_comparison_prefix:
                 raise ValueError(f"Field '{key}' is boolean and does not support range or comparison logic")
            if is_cp:
                 raise ValueError(f"Field '{key}' is boolean and does not support CP pattern logic")
        if field_type in {"number", "decimal"} and is_cp:
            raise ValueError(f"Field '{key}' is numeric and does not support CP pattern logic")
        if field_type == "string" and (is_numeric_range or has_comparison_prefix):
            raise ValueError(
                f"Field '{key}' is string and does not support numeric range/comparison operators"
            )

    for key in outputs:
        if key not in output_schema:
            raise ValueError(f"Output field '{key}' not defined in table schema")
