from typing import Any, Dict, List, Optional
from sqlalchemy.orm import Session
from backend import models
from backend.models import HitPolicy
from backend.rule_parser import evaluate_rule, evaluate_rule_with_trace


class DecisionEngine:
    @staticmethod
    def _get_value(source: Any, key: str, default: Any = None) -> Any:
        if isinstance(source, dict):
            return source.get(key, default)
        return getattr(source, key, default)

    @staticmethod
    def _evaluate_rules(
        hit_policy: HitPolicy,
        rules: List[Any],
        context: Dict[str, Any],
        detailed: bool = False,
    ) -> Dict[str, Any]:
        matched_rules: List[Any] = []
        trace: List[Dict[str, Any]] = []

        for rule in rules:
            logic = DecisionEngine._get_value(rule, "logic", {}) or {}
            if detailed:
                trace_info = evaluate_rule_with_trace(logic, context)
                matched = bool(trace_info.get("matched", False))
                trace.append(
                    {
                        "rule_id": str(DecisionEngine._get_value(rule, "id", "")),
                        "priority": DecisionEngine._get_value(rule, "priority", 0),
                        "matched": matched,
                        "failed_fields": trace_info.get("failed_fields", []),
                        "field_results": trace_info.get("field_results", []),
                        "summary": trace_info.get("summary", ""),
                    }
                )
            else:
                matched = evaluate_rule(logic, context)

            if matched:
                matched_rules.append(rule)
                if hit_policy == HitPolicy.FIRST_HIT:
                    break
                if hit_policy == HitPolicy.UNIQUE and len(matched_rules) > 1:
                    break

        matched_rule_ids = [
            str(DecisionEngine._get_value(rule, "id", "")) for rule in matched_rules
        ]

        if not matched_rules:
            return {
                "result": {},
                "hit_policy": hit_policy,
                "rule_id": None,
                "matched_rule_ids": [],
                "error": None,
                "trace": trace if detailed else [],
            }

        if hit_policy == HitPolicy.UNIQUE and len(matched_rules) > 1:
            return {
                "result": {},
                "hit_policy": hit_policy,
                "rule_id": "CONFLICT",
                "matched_rule_ids": matched_rule_ids,
                "error": "Unique Hit Policy Violation: Multiple rules matched",
                "trace": trace if detailed else [],
            }

        if hit_policy == HitPolicy.COLLECT_ALL:
            final_output = {}
            for rule in matched_rules:
                final_output.update(
                    (DecisionEngine._get_value(rule, "logic", {}) or {}).get(
                        "outputs", {}
                    )
                )
            return {
                "result": final_output,
                "hit_policy": hit_policy,
                "rule_id": "MULTIPLE",
                "matched_rule_ids": matched_rule_ids,
                "error": None,
                "trace": trace if detailed else [],
            }

        best_rule = matched_rules[0]
        return {
            "result": (DecisionEngine._get_value(best_rule, "logic", {}) or {}).get(
                "outputs", {}
            ),
            "hit_policy": hit_policy,
            "rule_id": str(DecisionEngine._get_value(best_rule, "id", "")),
            "matched_rule_ids": matched_rule_ids,
            "error": None,
            "trace": trace if detailed else [],
        }

    @staticmethod
    def evaluate(
        db: Session,
        table_slug: str,
        context: Dict[str, Any],
        detailed: bool = False,
    ) -> Optional[Dict[str, Any]]:
        table = (
            db.query(models.DecisionTable)
            .filter(models.DecisionTable.slug == table_slug)
            .first()
        )
        if not table:
            return None

        return DecisionEngine._evaluate_rules(
            hit_policy=table.hit_policy,
            rules=list(table.rules),
            context=context,
            detailed=detailed,
        )

    @staticmethod
    def evaluate_definition(
        table_definition: Dict[str, Any],
        context: Dict[str, Any],
        detailed: bool = False,
    ) -> Dict[str, Any]:
        hit_policy = HitPolicy(
            table_definition.get("hit_policy", HitPolicy.FIRST_HIT)
        )
        rules = table_definition.get("rules", [])
        return DecisionEngine._evaluate_rules(
            hit_policy=hit_policy,
            rules=rules,
            context=context,
            detailed=detailed,
        )
