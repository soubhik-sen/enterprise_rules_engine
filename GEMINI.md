# Project: BRF+ Zen Enterprise Engine (2026 Edition)
# Role: Global Context & Environment

## Infrastructure
- Backend: FastAPI (Python 3.12+)
- Database: PostgreSQL 18+ (using JSONB for rule storage)
- ORM: SQLAlchemy 2.0+ with Alembic for migrations
- Protocol: Use PostgreSQL MCP for schema verification
- Frontend: Flutter (Web)
- AI Strategy: Use Gemini 3 Pro for Planning; Flash for Implementation.


## Data Strategy
- Storage: Hybrid Model. Relational columns for search; JSONB for logic.
- Primary Keys: UUIDv7 (for ordered B-tree performance).
- Standards: Rules must follow the JDM (JSON Decision Model) structure.
- Logic: Decoupled from code. The engine must be a pure "stateless evaluator."

- Schema Metadata: Each DecisionTable must define its `input_schema` and `output_schema` (JSONB) to drive UI form generation and backend validation.

## Quota Governance
- Avoid complex loops in Python. Push filtering logic to SQL using JSONB operators (@>).

## Frontend
- Framework: Flutter 3.x (Web)
- State Management: Riverpod (Enterprise Standard for testability)
- API Integration: Chopper or Dio (with interceptors for logging)
- Design Language: Material 3 (Clean, Data-Dense for Admin use)

- UI Flow: Wizard (Schema Creation) -> Grid (Rule Entry) -> Split-View (Simulation/Audit).
- UX Requirement: Visual feedback for rule matching (Highlighting).
- Components: DataGrid for rules, JSON Editor for test context.