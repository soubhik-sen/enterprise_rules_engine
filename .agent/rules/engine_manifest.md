---
trigger: always_on
---

# Rule: Decision Logic & Schema Standards
# Scope: /backend

## Database Schema (Lookup Architecture)
1. **Table: `decision_tables`**
   - `id`: UUIDv7 (Primary Key)
   - `slug`: String (Unique Index)
   - `hit_policy`: Enum (FIRST_HIT, COLLECT_ALL, UNIQUE)

2. **Table: `decision_rules`**
   - `id`: UUIDv7 (Primary Key)
   - `table_id`: FK -> decision_tables.id
   - `priority`: Integer (Ascending)
   - `logic`: JSONB (Format: `{"inputs": {...}, "outputs": {...}}`)
   - **Index**: GIN Index on `logic` for high-speed lookups.

## Evaluation Math
A rule $R$ matches if every input condition is satisfied:
$$Match(R) \iff \forall i \in Inputs: \text{eval}(Context_i, R_i) = \text{True}$$

## Range Syntax Parser
The engine must parse string-based logic into Python comparisons:
- `10..50` $\rightarrow$ $x \ge 10 \text{ and } x \le 50$
- `>100` $\rightarrow$ $x > 100$
- `IN ('Gold', 'Silver')` $\rightarrow$ $x \in \{\text{'Gold', 'Silver'}\}$