"""Read-only App storage gate shared by fetch, entlink and extraction.

The versioned JSON is a verbatim public contract, not a second schema mapper.
Publishers compute the logical digest; consumers bind the signed physical bytes
to R and inspect current bindings without scanning inactive revision history.
"""
from __future__ import annotations

import hashlib
import json
import re
import sqlite3
import stat
from dataclasses import dataclass
from pathlib import Path

CONTRACT_PATH = Path(__file__).with_name("unified-contract-v1.json")
CONTRACT = json.loads(CONTRACT_PATH.read_text(encoding="utf-8"))
MARKER = "unified-medical-kg/v1"
SUPPORTED_SCHEMAS = frozenset((4, 5, 6, 7, 9))
SHA256 = re.compile(r"[0-9a-f]{64}\Z")
SQLITE_ENTRY_NAME = "medical-catalog.sqlite"
MAX_SQLITE_BYTES = 4_294_967_296


@dataclass(frozen=True)
class CatalogIdentity:
    schema: int
    data_version: str
    content_sha256: str | None = None
    activation_id: str | None = None

    def descriptor(self) -> dict:
        result = {"sqliteSchemaVersion": self.schema, "dataVersion": self.data_version}
        if self.schema == 9:
            result.update(storageContract=MARKER, graphSchemaVersion=2,
                          appCatalogSchemaVersion=4, releaseID=self.data_version,
                          contentSha256=self.content_sha256, activationID=self.activation_id,
                          catalogReady=True, contentScope="full", lifecycle="versioned")
        else:
            result["storageContract"] = "legacy"
        return result


def readonly_connection(path: Path) -> sqlite3.Connection:
    return sqlite3.connect(path.resolve().as_uri() + "?mode=ro", uri=True)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _require(condition: bool, reason: str) -> None:
    if not condition:
        raise ValueError(f"catalog storage contract: {reason}")


def _values(conn: sqlite3.Connection, table: str) -> dict[str, str]:
    rows = list(conn.execute(f'SELECT key,value FROM "{table}"'))
    result = dict(rows)
    _require(len(rows) == len(result), f"{table} has duplicate keys")
    _require(all(isinstance(k, str) and isinstance(v, str) for k, v in rows),
             f"{table} key/value types")
    return result


def _object(conn: sqlite3.Connection, name: str, kind: str) -> bool:
    return conn.execute("SELECT 1 FROM sqlite_schema WHERE type=? AND name=?",
                        (kind, name)).fetchone() is not None


def _primary_key(conn: sqlite3.Connection, table: str) -> tuple[str, ...]:
    columns = sorted((r[5], r[1]) for r in conn.execute(f'PRAGMA table_info("{table}")') if r[5])
    return tuple(name for _, name in columns)


def _unique_keys(conn: sqlite3.Connection, table: str) -> set[tuple[str, ...]]:
    keys = set()
    for index in conn.execute(f'PRAGMA index_list("{table}")'):
        if index[2] and not index[4]:
            quoted = index[1].replace('"', '""')
            keys.add(tuple(r[2] for r in conn.execute(f'PRAGMA index_info("{quoted}")')))
    return keys


def _check_shape(conn: sqlite3.Connection) -> None:
    _require((CONTRACT["storage_contract"], CONTRACT["physical_schema"],
              CONTRACT["graph_schema"], CONTRACT["app_catalog_schema"]) == (MARKER, 9, 2, 4),
             "unsupported bundled contract")
    for exact, tables in ((True, CONTRACT["app_columns"]),
                          (False, CONTRACT["required_graph_columns"])):
        for table, expected in tables.items():
            _require(_object(conn, table, "table"), f"missing physical table {table}")
            actual = [r[1] for r in conn.execute(f'PRAGMA table_info("{table}")')]
            _require(actual == expected if exact else set(expected) <= set(actual),
                     f"{table} column contract")
    for view in CONTRACT["required_views"]:
        _require(_object(conn, view, "view"), f"missing view {view}")
        conn.execute(f'SELECT * FROM "{view}" LIMIT 0')
    for table, key in (
        ("catalog_meta", ("key",)), ("metadata", ("key",)), ("drug", ("id",)),
        ("drug_reference", ("reference_id",)), ("drug_detail", ("region", "source_id")),
        ("graph_release", ("release_id",)), ("graph_activation", ("activation_id",)),
        ("catalog_entry", ("entry_uid",)), ("catalog_revision", ("revision_uid",)),
        ("assertion_review", ("review_uid",)), ("current_assertion_review", ("assertion_uid",)),
        ("producer_import", ("input_sha256",)),
        ("catalog_history", ("activation_id", "entry_uid")),
        ("source_record_history", ("activation_id", "record_uid")),
        ("assertion_history", ("activation_id", "assertion_uid")),
    ):
        _require(_primary_key(conn, table) == key, f"{table} primary key")
    for table in ("drug", "hospital", "department", "diagnosis", "exam_item"):
        keys = _unique_keys(conn, table)
        _require(("region", "source_id") in keys and ("source_id",) not in keys,
                 f"{table} must use UNIQUE(region,source_id), not global source_id")
    _require(("sequence",) in _unique_keys(conn, "graph_activation"), "activation sequence key")
    keys = _unique_keys(conn, "catalog_entry")
    _require({("table_name", "app_row_id"), ("table_name", "record_id")} <= keys,
             "catalog_entry identity keys")


def _check_current_bindings(conn: sqlite3.Connection, expected_count: int) -> None:
    total = 0
    for table in CONTRACT["app_columns"]:
        if table == "catalog_meta":
            continue
        for column in CONTRACT["app_columns"][table]:
            if column.endswith("_json"):
                _require(conn.execute(f'SELECT 1 FROM "{table}" WHERE NOT json_valid("{column}") LIMIT 1')
                         .fetchone() is None, f"{table}.{column} JSON")
        count = conn.execute(f'SELECT count(*) FROM "{table}"').fetchone()[0]
        bound = conn.execute("SELECT count(*) FROM catalog_entry WHERE table_name=? AND active=1",
                             (table,)).fetchone()[0]
        _require(count == bound, f"{table} binding count")
        record_check = (
            "json_array_length(c.record_id)!=1 OR json_extract(c.record_id,'$[0]') IS NOT t.reference_id"
            if table == "drug_reference" else
            "json_array_length(c.record_id)!=2 OR json_extract(c.record_id,'$[0]') IS NOT t.region "
            "OR json_extract(c.record_id,'$[1]') IS NOT t.source_id"
        )
        bad = conn.execute(f"""
            SELECT 1 FROM "{table}" t
            LEFT JOIN catalog_entry c ON c.table_name=? AND c.app_row_id=t.rowid AND c.active=1
            LEFT JOIN catalog_revision r ON r.revision_uid=c.current_revision_uid
            LEFT JOIN entity e ON e.uid=c.entity_uid
            LEFT JOIN entity_state s ON s.entity_uid=e.uid
            WHERE c.entry_uid IS NULL OR c.region IS NOT t.region OR c.source_id IS NOT t.source_id
               OR NOT json_valid(c.record_id) OR {record_check}
               OR r.revision_uid IS NULL OR r.entry_uid IS NOT c.entry_uid
               OR e.uid IS NULL OR e.region IS NOT t.region OR coalesce(s.active,1)!=1
            LIMIT 1""", (table,)).fetchone()
        _require(bad is None, f"{table} current revision/entity/row binding")
        total += count
    _require(total == expected_count
             and conn.execute("SELECT count(*) FROM catalog_entry WHERE active=1").fetchone()[0] == total,
             "release catalog_count/current bindings")


def inspect_connection(conn: sqlite3.Connection, *, schema: int | None = None,
                       data_version: str | None = None, content_sha256: str | None = None) -> CatalogIdentity:
    _require(_object(conn, "catalog_meta", "table"), "catalog_meta must be a physical table")
    meta = _values(conn, "catalog_meta")
    text = meta.get("schema_version", "")
    _require(text.isascii() and text.isdigit() and str(int(text)) == text, "schema_version")
    physical = int(text)
    _require(physical in SUPPORTED_SCHEMAS, f"unsupported physical schema {physical}")
    _require(conn.execute("PRAGMA user_version").fetchone()[0] == physical, "user_version mismatch")
    data = meta.get("data_version", "")
    _require(bool(data) and (schema is None or schema == physical)
             and (data_version is None or data_version == data), "signed schema/dataVersion binding")
    metadata_type = conn.execute("SELECT type FROM sqlite_schema WHERE name='metadata'").fetchone()
    _require(metadata_type is None or metadata_type[0] == "table", "metadata must be a physical table")
    graph = _values(conn, "metadata") if metadata_type is not None else {}
    if physical != 9:
        _require("storage_contract" not in meta and "storage_contract" not in graph
                 and graph.get("schema_version") != "2", "unified marker on legacy schema")
        return CatalogIdentity(physical, data)
    _require(meta.get("storage_contract") == MARKER
             and meta.get("app_catalog_schema_version") == "4"
             and meta.get("graph_schema_version") == "2", "unified marker/App4/graph2")
    _require(meta.get("catalog_ready") == "true" and meta.get("content_scope") == "full",
             "only catalog_ready=true/content_scope=full is installable")
    _require(SHA256.fullmatch(data) is not None
             and (content_sha256 is None or content_sha256 == data)
             and graph.get("format") == "vita_liber_evidence_graph"
             and graph.get("storage_contract", MARKER) == MARKER
             and graph.get("schema_version") == "2" and graph.get("release_id") == data,
             "R/content/metadata release binding")
    _require(graph.get("lifecycle") == "versioned", "only versioned lifecycle is installable")
    activation = graph.get("activation_id")
    _require(bool(activation), "metadata.activation_id missing")
    _check_shape(conn)
    input_sha = meta.get("producer_input_sha256", "")
    producer_version = meta.get("producer_data_version")
    _require(SHA256.fullmatch(input_sha) is not None and bool(producer_version)
             and conn.execute("SELECT 1 FROM producer_import WHERE input_sha256=? "
                              "AND producer_data_version=? AND json_valid(metadata_json)",
                              (input_sha, producer_version)).fetchone() is not None,
             "current producer_import pointer binding")
    release = conn.execute("""
        SELECT content_sha256,status,scope,catalog_count,entity_count,assertion_count,
               json_valid(source_manifest_json)
        FROM graph_release WHERE release_id=?""", (data,)).fetchone()
    _require(release is not None, "selected graph_release missing")
    _require(release[0] == data and release[1] == "validated" and release[2] == "full"
             and type(release[3]) is int and release[3] > 0
             and all(type(n) is int and n >= 0 for n in release[4:6]) and release[6] == 1,
             "graph_release content/status/scope/count")
    event = conn.execute("""
        SELECT release_id FROM graph_activation
        WHERE activation_id=? AND typeof(sequence)='integer' AND sequence>0""", (activation,)).fetchone()
    _require(event is not None and event[0] == data, "activation primary-key release binding")
    _check_current_bindings(conn, release[3])
    _require(conn.execute("""
        SELECT 1 FROM active_assertion a
        LEFT JOIN current_assertion_review c ON c.assertion_uid=a.uid
        LEFT JOIN assertion_review r ON r.review_uid=c.review_uid
        WHERE (a.review_status='approved' AND c.review_uid IS NULL)
           OR (c.review_uid IS NOT NULL AND (
                r.review_uid IS NULL OR r.assertion_uid IS NOT a.uid OR r.status IS NOT a.review_status
                OR coalesce(length(trim(r.actor)),0)=0 OR coalesce(length(trim(r.rationale)),0)=0))
        LIMIT 1
        """).fetchone() is None, "active approval/current review requires an actor/rationale decision")
    for table in ("catalog_history", "source_record_history", "assertion_history"):
        _require(conn.execute(f"SELECT 1 FROM {table} WHERE activation_id=? AND release_id IS NOT ? LIMIT 1",
                              (activation, data)).fetchone() is None, f"{table} current activation release")
    return CatalogIdentity(physical, data, data, activation)


def validate_sqlite(path: Path, *, schema: int | None = None, data_version: str | None = None,
                    content_sha256: str | None = None, sqlite_sha256: str | None = None) -> CatalogIdentity:
    _require(not path.is_symlink() and stat.S_ISREG(path.stat().st_mode), "SQLite must be a regular file")
    _require(0 < path.stat().st_size <= MAX_SQLITE_BYTES, "SQLite size limit")
    with path.open("rb") as stream:
        _require(stream.read(16) == b"SQLite format 3\x00", "SQLite header")
    if sqlite_sha256 is not None:
        _require(sha256_file(path) == sqlite_sha256, "signed SQLite SHA-256 mismatch")
    conn = readonly_connection(path)
    try:
        _require([r[0] for r in conn.execute("PRAGMA integrity_check")] == ["ok"], "integrity_check")
        _require(conn.execute("PRAGMA foreign_key_check").fetchone() is None, "foreign_key_check")
        identity = inspect_connection(conn, schema=schema, data_version=data_version, content_sha256=content_sha256)
        if identity.schema == 9:
            _require(conn.execute("PRAGMA journal_mode").fetchone()[0] == "delete", "sealed DELETE journal")
        return identity
    finally:
        conn.close()


def validate_source_descriptor(identity: CatalogIdentity, descriptor: dict, actual_sha256: str) -> None:
    _require(isinstance(descriptor, dict), "source descriptor object")
    for key, value in identity.descriptor().items():
        actual = descriptor.get(key)
        _require(type(actual) is type(value) and actual == value, f"source descriptor {key}")
    _require(descriptor.get("sqliteSha256") == actual_sha256, "source descriptor SQLite SHA")
    if descriptor.get("mode") == "cnb-release-v3":
        digest = descriptor.get("signedPointerDigest")
        _require(isinstance(digest, str) and SHA256.fullmatch(digest) is not None,
                 "source descriptor signed payload digest")
