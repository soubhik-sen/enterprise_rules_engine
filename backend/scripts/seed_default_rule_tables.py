from __future__ import annotations

from backend.database import SessionLocal
from backend.models import DecisionRule, DecisionTable, HitPolicy


SEED_TABLES = [
    {
        "slug": "shipment_default_profile_v1",
        "object_type": "SHIPMENT",
        "description": "Default profile resolver for shipment events",
        "hit_policy": HitPolicy.FIRST_HIT,
        "input_schema": {"shipment_number": "string"},
        "output_schema": {"profile_name": "string"},
        "rule_logic": {
            "inputs": {"shipment_number": ""},
            "outputs": {"profile_name": "SHIPMENT_EVENTS_DEFAULT_V1"},
        },
    },
    {
        "slug": "purchase_order_default_profile_v1",
        "object_type": "PURCHASE_ORDER",
        "description": "Default profile resolver for purchase order events",
        "hit_policy": HitPolicy.FIRST_HIT,
        "input_schema": {"purchase_order_number": "string"},
        "output_schema": {"profile_name": "string"},
        "rule_logic": {
            "inputs": {"purchase_order_number": ""},
            "outputs": {"profile_name": "PO_EVENTS_DEFAULT_V1"},
        },
    },
]


def upsert_table_with_single_rule(db, definition: dict) -> None:
    table = (
        db.query(DecisionTable)
        .filter(DecisionTable.slug == definition["slug"])
        .first()
    )

    created = table is None
    if created:
        table = DecisionTable(slug=definition["slug"])
        db.add(table)

    table.description = definition["description"]
    table.object_type = definition.get("object_type", "")
    table.hit_policy = definition["hit_policy"]
    table.input_schema = definition["input_schema"]
    table.output_schema = definition["output_schema"]
    db.flush()

    db.query(DecisionRule).filter(DecisionRule.table_id == table.id).delete(
        synchronize_session=False
    )
    db.add(
        DecisionRule(
            table_id=table.id,
            priority=0,
            logic=definition["rule_logic"],
        )
    )
    db.flush()

    action = "Created" if created else "Updated"
    print(
        f"{action} table '{table.slug}' with default profile "
        f"'{definition['rule_logic']['outputs']['profile_name']}'"
    )


def main() -> None:
    db = SessionLocal()
    try:
        for definition in SEED_TABLES:
            upsert_table_with_single_rule(db, definition)
        db.commit()
        print("Seed completed.")
    except Exception:
        db.rollback()
        raise
    finally:
        db.close()


if __name__ == "__main__":
    main()
