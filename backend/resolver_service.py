import json
import re
from typing import Any

from jsonpath_ng import parse as jsonpath_parse
from sqlalchemy import text
from sqlalchemy.orm import Session

from backend import models
_IDENTIFIER_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
_DEFAULT_OBJECT_TABLES = {
    "PURCHASE_ORDER": "po_headers",
}

from backend.external_data_client import ExternalDataClient
from backend.resolver_errors import ResolverConfigurationError, ResolverDataError


def _validate_identifier(value: str, label: str) -> str:
    token = str(value or "").strip()
    if not token:
        raise ResolverConfigurationError(f"Missing '{label}' in path_logic.")
    if not _IDENTIFIER_RE.fullmatch(token):
        raise ResolverConfigurationError(
            f"Invalid SQL identifier for '{label}': '{token}'."
        )
    return token


def _normalize_object_type(object_type: str) -> str:
    normalized = str(object_type or "").strip().upper()
    if not normalized:
        raise ResolverConfigurationError("object_type is required for attribute resolution.")
    return normalized


def _normalize_strategy(value: Any) -> str:
    raw = str(value or "")
    return raw.split(".")[-1].upper()


def _jsonpath_extract(payload: Any, expression: str) -> Any | None:
    try:
        matches = jsonpath_parse(expression).find(payload)
    except Exception as e:
        raise ResolverConfigurationError(
            f"Invalid jsonpath expression '{expression}'."
        ) from e
    if not matches:
        return None
    if len(matches) == 1:
        return matches[0].value
    return [match.value for match in matches]


def _stable_json(value: Any) -> str:
    return json.dumps(value, sort_keys=True, default=str)


def _render_endpoint(template: str, *, object_id: str, object_type: str) -> str:
    try:
        return template.format(object_id=object_id, object_type=object_type)
    except KeyError as e:
        raise ResolverConfigurationError(
            f"Unsupported placeholder in endpoint template: {e}"
        ) from e


class AttributeResolverService:
    @staticmethod
    def list_attributes(db: Session, object_type: str) -> list[Any]:
        target_object = _normalize_object_type(object_type)
        return (
            db.query(models.AttributeRegistry)
            .filter(models.AttributeRegistry.target_object == target_object)
            .order_by(models.AttributeRegistry.attribute_name.asc())
            .all()
        )

    @staticmethod
    def hydrate_context(
        db: Session,
        *,
        object_type: str,
        object_id: str,
        required_attributes: list[str],
        context: dict[str, Any] | None = None,
        external_client: ExternalDataClient | None = None,
    ) -> dict[str, Any]:
        hydrated = dict(context or {})
        if not object_id:
            return hydrated

        target_object = _normalize_object_type(object_type)
        required = [key for key in required_attributes if str(key).strip()]
        to_resolve = [
            key
            for key in required
            if key not in hydrated or hydrated.get(key) is None or hydrated.get(key) == ""
        ]
        if not to_resolve:
            return hydrated

        rows = (
            db.query(models.AttributeRegistry)
            .filter(models.AttributeRegistry.target_object == target_object)
            .filter(models.AttributeRegistry.attribute_name.in_(to_resolve))
            .all()
        )
        registry_by_attr = {row.attribute_name: row for row in rows}

        missing_registry = [key for key in to_resolve if key not in registry_by_attr]
        if missing_registry:
            raise ResolverConfigurationError(
                "No attribute registry entry for "
                f"{target_object}: {', '.join(sorted(missing_registry))}"
            )

        unresolved = []
        external_entries = {}
        for key in to_resolve:
            entry = registry_by_attr[key]
            strategy = _normalize_strategy(entry.resolution_strategy)
            if strategy == models.ResolutionStrategy.EXTERNAL.value:
                external_entries[key] = entry
                continue
            value = AttributeResolverService._resolve_single(
                db,
                entry,
                target_object=target_object,
                object_id=object_id,
            )
            if value is None:
                unresolved.append(key)
            else:
                hydrated[key] = value

        if external_entries:
            external_values = AttributeResolverService._resolve_external_batch(
                external_entries,
                object_id=object_id,
                target_object=target_object,
                external_client=external_client or ExternalDataClient(),
            )
            for key, value in external_values.items():
                hydrated[key] = value
            for key in external_entries:
                if key not in hydrated:
                    unresolved.append(key)

        if unresolved:
            raise ResolverDataError(
                f"Could not resolve attributes for {target_object} {object_id}: "
                + ", ".join(sorted(unresolved))
            )

        return hydrated

    @staticmethod
    def _resolve_single(
        db: Session,
        entry: Any,
        *,
        target_object: str,
        object_id: str,
    ) -> Any:
        strategy = str(entry.resolution_strategy)
        strategy = strategy.split(".")[-1]
        path_logic = dict(getattr(entry, "path_logic", {}) or {})

        if strategy == models.ResolutionStrategy.DIRECT.value:
            return AttributeResolverService._resolve_direct(db, path_logic, object_id)
        if strategy == models.ResolutionStrategy.ASSOCIATION.value:
            return AttributeResolverService._resolve_association(
                db,
                path_logic,
                target_object=target_object,
                object_id=object_id,
            )
        if strategy == models.ResolutionStrategy.EXTERNAL.value:
            raise ResolverConfigurationError(
                "EXTERNAL attributes must be resolved in batch."
            )
        raise ResolverConfigurationError(
            f"Unsupported resolution_strategy '{entry.resolution_strategy}'."
        )

    @staticmethod
    def _resolve_direct(db: Session, path_logic: dict[str, Any], object_id: str) -> Any:
        table_name = _validate_identifier(path_logic.get("table"), "table")
        id_field = _validate_identifier(path_logic.get("id_field", "id"), "id_field")
        field = _validate_identifier(path_logic.get("field"), "field")

        stmt = text(
            f"SELECT {field} AS value "
            f"FROM {table_name} "
            f"WHERE {id_field} = :object_id "
            "LIMIT 1"
        )
        row = db.execute(stmt, {"object_id": object_id}).mappings().first()
        if not row:
            return None
        return row.get("value")

    @staticmethod
    def _resolve_association(
        db: Session,
        path_logic: dict[str, Any],
        *,
        target_object: str,
        object_id: str,
    ) -> Any:
        base_table = (
            path_logic.get("base_table")
            or path_logic.get("source_table")
            or _DEFAULT_OBJECT_TABLES.get(target_object)
        )
        join_table = path_logic.get("join_table") or path_logic.get("join")
        join_on = (
            path_logic.get("join_on")
            or path_logic.get("on")
            or path_logic.get("foreign_key")
        )
        base_id_field = (
            path_logic.get("base_id_field")
            or path_logic.get("source_id_field")
            or path_logic.get("id_field")
            or "id"
        )
        field = path_logic.get("field") or path_logic.get("select_field")

        base_table_name = _validate_identifier(base_table, "base_table")
        join_table_name = _validate_identifier(join_table, "join_table")
        join_on_field = _validate_identifier(join_on, "join_on")
        base_id_column = _validate_identifier(base_id_field, "base_id_field")
        value_field = _validate_identifier(field, "field")

        order_by = path_logic.get("order_by")
        order_direction = str(path_logic.get("order_direction", "asc")).strip().lower()
        order_clause = ""
        if order_by:
            order_by_col = _validate_identifier(order_by, "order_by")
            direction = "DESC" if order_direction == "desc" else "ASC"
            order_clause = f" ORDER BY j.{order_by_col} {direction}"

        stmt = text(
            f"SELECT j.{value_field} AS value "
            f"FROM {join_table_name} j "
            f"JOIN {base_table_name} b "
            f"ON j.{join_on_field} = b.{base_id_column} "
            f"WHERE b.{base_id_column} = :object_id"
            f"{order_clause} "
            "LIMIT 1"
        )
        row = db.execute(stmt, {"object_id": object_id}).mappings().first()
        if not row:
            return None
        return row.get("value")

    @staticmethod
    def _resolve_external_batch(
        entries: dict[str, Any],
        *,
        object_id: str,
        target_object: str,
        external_client: ExternalDataClient,
    ) -> dict[str, Any]:
        groups: dict[str, list[tuple[str, str]]] = {}
        group_payloads: dict[str, dict[str, Any]] = {}

        for attribute_name, entry in entries.items():
            path_logic = dict(getattr(entry, "path_logic", {}) or {})
            source_service = path_logic.get("source_service") or path_logic.get("service")
            endpoint_template = path_logic.get("endpoint") or path_logic.get("path")
            jsonpath_expr = path_logic.get("jsonpath") or path_logic.get("json_path")
            method = str(path_logic.get("method", "GET")).upper()
            params = path_logic.get("query_params") or path_logic.get("params") or {}
            headers = path_logic.get("headers") or {}

            if not source_service:
                raise ResolverConfigurationError(
                    f"Missing source_service for attribute '{attribute_name}'."
                )
            if not endpoint_template:
                raise ResolverConfigurationError(
                    f"Missing endpoint for attribute '{attribute_name}'."
                )
            if not jsonpath_expr:
                raise ResolverConfigurationError(
                    f"Missing jsonpath for attribute '{attribute_name}'."
                )

            endpoint = _render_endpoint(
                str(endpoint_template),
                object_id=object_id,
                object_type=target_object,
            )

            group_key = "|".join(
                [
                    str(source_service),
                    method,
                    endpoint,
                    _stable_json(params),
                    _stable_json(headers),
                ]
            )
            groups.setdefault(group_key, []).append((attribute_name, str(jsonpath_expr)))
            group_payloads[group_key] = {
                "source_service": str(source_service),
                "endpoint": endpoint,
                "method": method,
                "params": params,
                "headers": headers,
            }

        resolved: dict[str, Any] = {}
        for group_key, attributes in groups.items():
            payload = group_payloads[group_key]
            response_json = external_client.fetch_json(**payload)
            for attribute_name, jsonpath_expr in attributes:
                value = _jsonpath_extract(response_json, jsonpath_expr)
                if value is not None:
                    resolved[attribute_name] = value

        return resolved
