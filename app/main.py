import logging
import os
import time
from contextlib import contextmanager
from typing import Any

import psycopg
from fastapi import FastAPI, HTTPException, Request, status
from pydantic import BaseModel, Field
from psycopg.rows import dict_row


logging.basicConfig(
    level=os.getenv("LOG_LEVEL", "INFO"),
    format="%(asctime)s %(levelname)s %(message)s",
)
logger = logging.getLogger("zenyard-api")


class TodoCreate(BaseModel):
    title: str = Field(..., min_length=1, max_length=255)


class Todo(BaseModel):
    id: int
    title: str
    completed: bool
    created_at: str
    completed_at: str | None = None


def database_url() -> str:
    host = os.environ["DB_HOST"]
    port = os.getenv("DB_PORT", "5432")
    db_name = os.environ["DB_NAME"]
    user = os.environ["DB_USER"]
    password = os.environ["DB_PASSWORD"]
    return f"postgresql://{user}:{password}@{host}:{port}/{db_name}"


@contextmanager
def db_connection():
    try:
        with psycopg.connect(database_url(), row_factory=dict_row, connect_timeout=5) as conn:
            yield conn
    except KeyError as exc:
        logger.exception("missing_database_configuration key=%s", exc)
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="database configuration is incomplete",
        ) from exc
    except psycopg.Error as exc:
        logger.exception("database_error")
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="database is unavailable",
        ) from exc


app = FastAPI(title="Zenyard TODO API", version="0.1.0")


@app.middleware("http")
async def log_requests(request: Request, call_next):
    started = time.monotonic()
    response = await call_next(request)
    duration_ms = (time.monotonic() - started) * 1000
    logger.info(
        "request method=%s path=%s status=%s duration_ms=%.2f",
        request.method,
        request.url.path,
        response.status_code,
        duration_ms,
    )
    return response


@app.get("/healthz")
def healthz() -> dict[str, str]:
    with db_connection() as conn:
        conn.execute("SELECT 1")
    return {"status": "ok"}


@app.get("/todos", response_model=list[Todo])
def list_todos() -> list[dict[str, Any]]:
    with db_connection() as conn:
        rows = conn.execute(
            """
            SELECT id, title, completed, created_at::text, completed_at::text
            FROM todos
            ORDER BY id
            """
        ).fetchall()
    return rows


@app.post("/todos", response_model=Todo, status_code=status.HTTP_201_CREATED)
def create_todo(todo: TodoCreate) -> dict[str, Any]:
    with db_connection() as conn:
        row = conn.execute(
            """
            INSERT INTO todos (title)
            VALUES (%s)
            RETURNING id, title, completed, created_at::text, completed_at::text
            """,
            (todo.title,),
        ).fetchone()
        conn.commit()

    if row is None:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="failed to create todo",
        )
    return row


@app.patch("/todos/{todo_id}/complete", response_model=Todo)
def complete_todo(todo_id: int) -> dict[str, Any]:
    with db_connection() as conn:
        row = conn.execute(
            """
            UPDATE todos
            SET completed = TRUE,
                completed_at = COALESCE(completed_at, now())
            WHERE id = %s
            RETURNING id, title, completed, created_at::text, completed_at::text
            """,
            (todo_id,),
        ).fetchone()
        conn.commit()

    if row is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="todo not found",
        )
    return row
