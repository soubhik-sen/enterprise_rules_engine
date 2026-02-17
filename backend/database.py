from sqlalchemy.orm import sessionmaker, Session
from sqlalchemy import create_engine
import os

# Default to a local postgres for development if env not set
DATABASE_URL = os.getenv("DATABASE_URL", "postgresql://admin:QElc6lXUrtCwJzDNHmzwxdGiPtUBN5U4@dpg-d649vvshg0os73d1o6e0-a.oregon-postgres.render.com/decision_engine_i7ro")

_engine_kwargs = {
    # Prevent stale pooled connections from failing requests after DB restarts/idle timeouts.
    "pool_pre_ping": True,
    "pool_recycle": int(os.getenv("DB_POOL_RECYCLE_SECONDS", "1800")),
}

if not DATABASE_URL.startswith("sqlite"):
    _engine_kwargs["pool_size"] = int(os.getenv("DB_POOL_SIZE", "5"))
    _engine_kwargs["max_overflow"] = int(os.getenv("DB_MAX_OVERFLOW", "10"))

engine = create_engine(DATABASE_URL, **_engine_kwargs)
SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)

def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()
