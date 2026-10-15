CREATE TABLE catalog_meta (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL);
CREATE TABLE drug (id INTEGER PRIMARY KEY, region TEXT NOT NULL, source_id TEXT NOT NULL, license_no TEXT, name_zh TEXT, name_en TEXT, brand_name TEXT, dosage_form TEXT, spec TEXT, drug_category TEXT, license_holder TEXT, manufacturer TEXT, insurance_code TEXT, drug_code TEXT, active_ingredients TEXT, usage_ref_json TEXT NOT NULL, region_specific_json TEXT NOT NULL, aliases_json TEXT NOT NULL, UNIQUE(region,source_id));
CREATE TABLE drug_reference (reference_id TEXT PRIMARY KEY NOT NULL, region TEXT NOT NULL, source_id TEXT NOT NULL, license_no TEXT, name_zh TEXT, name_en TEXT, brand_name TEXT, normalized_keys_json TEXT NOT NULL, spec_raw TEXT, spec_ref_json TEXT NOT NULL, source_fields_json TEXT NOT NULL, image_urls_json TEXT NOT NULL, match_status TEXT NOT NULL);
CREATE TABLE drug_detail (region TEXT NOT NULL, source_id TEXT NOT NULL, usage_text TEXT, indications TEXT, active_ingredients TEXT, usage_ref_json TEXT NOT NULL, raw_json TEXT NOT NULL, PRIMARY KEY(region, source_id));
CREATE TABLE hospital (region TEXT NOT NULL, source_id TEXT NOT NULL, code TEXT, name_zh TEXT NOT NULL, short_name TEXT, type_zh TEXT, level_zh TEXT, address TEXT, phone TEXT, admin_area TEXT, depts_json TEXT NOT NULL, aliases_json TEXT NOT NULL, match_status TEXT, UNIQUE(region,source_id));
CREATE TABLE department (region TEXT NOT NULL, source_id TEXT NOT NULL, code TEXT NOT NULL, name_zh TEXT NOT NULL, category_zh TEXT, aliases_json TEXT NOT NULL, match_status TEXT, UNIQUE(region,source_id));
CREATE TABLE diagnosis (region TEXT NOT NULL, source_id TEXT NOT NULL, code TEXT NOT NULL, name_zh TEXT NOT NULL, code_system TEXT NOT NULL, chapter_zh TEXT, aliases_json TEXT NOT NULL, match_status TEXT, UNIQUE(region,source_id));
CREATE TABLE exam_item (region TEXT NOT NULL, source_id TEXT NOT NULL, code TEXT NOT NULL, name_zh TEXT NOT NULL, name_en TEXT, category TEXT, method TEXT, specimen TEXT, unit TEXT, price_ref TEXT, loinc_concept_id TEXT, aliases_json TEXT NOT NULL, match_status TEXT, UNIQUE(region,source_id));

CREATE VIRTUAL TABLE drug_fts USING fts5(name_zh, name_en, brand_name, aliases_json, content='drug', content_rowid='id');
CREATE VIRTUAL TABLE hospital_fts USING fts5(name_zh, short_name, aliases_json, depts_json, content='hospital', content_rowid='rowid');
CREATE VIRTUAL TABLE diagnosis_fts USING fts5(code, name_zh, aliases_json, content='diagnosis', content_rowid='rowid');
CREATE VIRTUAL TABLE exam_fts USING fts5(code, name_zh, name_en, aliases_json, content='exam_item', content_rowid='rowid');

CREATE TABLE graph_release (
    release_id TEXT PRIMARY KEY NOT NULL,
    sequence INTEGER NOT NULL UNIQUE CHECK (sequence >= 0),
    content_sha256 TEXT NOT NULL,
    scope TEXT NOT NULL CHECK (scope IN ('full', 'partial', 'legacy', 'empty')),
    status TEXT NOT NULL CHECK (status IN ('validated', 'legacy')),
    source_manifest_json TEXT NOT NULL CHECK (json_valid(source_manifest_json)),
    catalog_count INTEGER NOT NULL CHECK (catalog_count >= 0),
    entity_count INTEGER NOT NULL CHECK (entity_count >= 0),
    assertion_count INTEGER NOT NULL CHECK (assertion_count >= 0),
    created_at TEXT NOT NULL
);

CREATE TABLE producer_import (
    input_sha256 TEXT PRIMARY KEY NOT NULL,
    producer_data_version TEXT NOT NULL,
    metadata_json TEXT NOT NULL CHECK (json_valid(metadata_json)),
    imported_at TEXT NOT NULL
);

CREATE TABLE producer_state_history (
    history_uid TEXT PRIMARY KEY NOT NULL,
    input_sha256 TEXT NOT NULL REFERENCES producer_import(input_sha256),
    table_name TEXT NOT NULL,
    row_key TEXT NOT NULL CHECK (json_valid(row_key)),
    previous_row_json TEXT NOT NULL CHECK (json_valid(previous_row_json)),
    current_row_json TEXT NOT NULL CHECK (json_valid(current_row_json)),
    recorded_at TEXT NOT NULL
);
CREATE INDEX producer_state_history_input ON producer_state_history(input_sha256, table_name);

CREATE TABLE catalog_entry (
    entry_uid TEXT PRIMARY KEY NOT NULL,
    table_name TEXT NOT NULL CHECK (table_name IN
        ('drug', 'drug_reference', 'drug_detail', 'hospital', 'department', 'diagnosis', 'exam_item')),
    region TEXT NOT NULL,
    source_id TEXT NOT NULL,
    record_id TEXT NOT NULL CHECK (json_valid(record_id)),
    entity_uid TEXT NOT NULL REFERENCES entity(uid),
    app_row_id INTEGER NOT NULL CHECK (app_row_id > 0),
    current_revision_uid TEXT REFERENCES catalog_revision(revision_uid),
    active INTEGER NOT NULL CHECK (active IN (0, 1)),
    UNIQUE (table_name, record_id),
    UNIQUE (table_name, app_row_id)
);
CREATE INDEX catalog_entry_entity ON catalog_entry(entity_uid, active);

CREATE TABLE catalog_revision (
    revision_uid TEXT PRIMARY KEY NOT NULL,
    entry_uid TEXT NOT NULL REFERENCES catalog_entry(entry_uid),
    content_sha256 TEXT NOT NULL,
    row_json TEXT NOT NULL CHECK (json_valid(row_json)),
    provenance_json TEXT NOT NULL CHECK (json_valid(provenance_json)),
    created_at TEXT NOT NULL,
    UNIQUE (entry_uid, content_sha256, provenance_json)
);

CREATE TABLE catalog_history (
    activation_id TEXT NOT NULL REFERENCES graph_activation(activation_id),
    release_id TEXT NOT NULL REFERENCES graph_release(release_id),
    entry_uid TEXT NOT NULL REFERENCES catalog_entry(entry_uid),
    revision_uid TEXT REFERENCES catalog_revision(revision_uid),
    active INTEGER NOT NULL CHECK (active IN (0, 1)),
    PRIMARY KEY (activation_id, entry_uid),
    CHECK (active = 0 OR revision_uid IS NOT NULL)
);

CREATE TABLE field_provenance (
    revision_uid TEXT NOT NULL REFERENCES catalog_revision(revision_uid),
    field_path TEXT NOT NULL CHECK (field_path = '' OR substr(field_path, 1, 1) = '/'),
    source_uid TEXT NOT NULL REFERENCES source(uid),
    document_uid TEXT NOT NULL REFERENCES document(uid),
    source_key TEXT NOT NULL,
    snapshot_id TEXT NOT NULL,
    role TEXT NOT NULL CHECK (role IN ('main', 'fill', 'reference', 'link', 'candidate')),
    locator_json TEXT NOT NULL CHECK (json_valid(locator_json)),
    PRIMARY KEY (revision_uid, field_path, document_uid, role, locator_json)
);
CREATE INDEX field_provenance_document ON field_provenance(document_uid);

CREATE TABLE source_record (
    record_uid TEXT PRIMARY KEY NOT NULL,
    source_uid TEXT NOT NULL REFERENCES source(uid),
    namespace TEXT NOT NULL,
    region TEXT NOT NULL,
    domain TEXT NOT NULL,
    source_key TEXT NOT NULL,
    entity_uid TEXT NOT NULL REFERENCES entity(uid),
    current_document_uid TEXT REFERENCES document(uid),
    active INTEGER NOT NULL CHECK (active IN (0, 1)),
    UNIQUE (namespace, region, domain, source_key)
);
CREATE INDEX source_record_document ON source_record(current_document_uid, active);

CREATE TABLE source_record_history (
    activation_id TEXT NOT NULL REFERENCES graph_activation(activation_id),
    release_id TEXT NOT NULL REFERENCES graph_release(release_id),
    record_uid TEXT NOT NULL REFERENCES source_record(record_uid),
    document_uid TEXT REFERENCES document(uid),
    active INTEGER NOT NULL CHECK (active IN (0, 1)),
    PRIMARY KEY (activation_id, record_uid)
);

CREATE TABLE graph_activation (
    activation_id TEXT PRIMARY KEY NOT NULL,
    sequence INTEGER NOT NULL UNIQUE CHECK (sequence > 0),
    release_id TEXT NOT NULL REFERENCES graph_release(release_id),
    activated_at TEXT NOT NULL
);

CREATE TABLE document_origin (
    document_uid TEXT PRIMARY KEY NOT NULL REFERENCES document(uid),
    namespace TEXT NOT NULL,
    source_key TEXT NOT NULL,
    snapshot_id TEXT NOT NULL,
    payload_sha256 TEXT NOT NULL,
    origin_kind TEXT NOT NULL CHECK (origin_kind IN ('raw', 'canonical', 'legacy')),
    input_sha256 TEXT NOT NULL
);

CREATE TABLE entity_state (
    entity_uid TEXT PRIMARY KEY NOT NULL REFERENCES entity(uid),
    active INTEGER NOT NULL CHECK (active IN (0, 1)),
    training_subject INTEGER NOT NULL DEFAULT 1 CHECK (training_subject IN (0, 1))
);

CREATE TABLE assertion_state (
    assertion_uid TEXT PRIMARY KEY NOT NULL REFERENCES assertion(uid),
    source_record_uid TEXT REFERENCES source_record(record_uid),
    active INTEGER NOT NULL CHECK (active IN (0, 1))
);
CREATE INDEX assertion_state_source ON assertion_state(source_record_uid, active);

CREATE TABLE assertion_review (
    review_uid TEXT PRIMARY KEY NOT NULL,
    assertion_uid TEXT NOT NULL REFERENCES assertion(uid),
    status TEXT NOT NULL CHECK (status IN ('approved', 'pending', 'conflict')),
    actor TEXT NOT NULL CHECK (length(trim(actor)) > 0),
    rationale TEXT NOT NULL CHECK (length(trim(rationale)) > 0),
    created_at TEXT NOT NULL
);
CREATE TABLE current_assertion_review (
    assertion_uid TEXT PRIMARY KEY NOT NULL REFERENCES assertion(uid),
    review_uid TEXT NOT NULL REFERENCES assertion_review(review_uid)
);
CREATE TABLE assertion_history (
    activation_id TEXT NOT NULL REFERENCES graph_activation(activation_id),
    release_id TEXT NOT NULL REFERENCES graph_release(release_id),
    assertion_uid TEXT NOT NULL REFERENCES assertion(uid),
    review_status TEXT NOT NULL CHECK (review_status IN ('approved', 'pending', 'conflict')),
    review_uid TEXT REFERENCES assertion_review(review_uid),
    active INTEGER NOT NULL CHECK (active IN (0, 1)),
    PRIMARY KEY (activation_id, assertion_uid)
);

CREATE TABLE alias_state (
    alias_uid TEXT PRIMARY KEY NOT NULL REFERENCES alias(uid),
    active INTEGER NOT NULL CHECK (active IN (0, 1))
);

CREATE TABLE catalog_relation (
    uid TEXT PRIMARY KEY NOT NULL,
    subject_uid TEXT NOT NULL REFERENCES entity(uid),
    predicate TEXT NOT NULL CHECK (predicate IN ('hospital_department', 'reference_for')),
    object_uid TEXT NOT NULL REFERENCES entity(uid),
    region TEXT NOT NULL,
    revision_uid TEXT NOT NULL REFERENCES catalog_revision(revision_uid),
    status TEXT NOT NULL CHECK (status IN ('explicit', 'candidate', 'conflict')),
    active INTEGER NOT NULL CHECK (active IN (0, 1))
);
CREATE INDEX catalog_relation_forward ON catalog_relation(subject_uid, predicate, active);

CREATE VIEW active_entity AS
SELECT e.* FROM entity e LEFT JOIN entity_state s ON s.entity_uid = e.uid
WHERE coalesce(s.active, 1) = 1;

CREATE VIEW active_alias AS
SELECT a.* FROM alias a
WHERE NOT EXISTS (SELECT 1 FROM alias_state s WHERE s.alias_uid=a.uid AND s.active=0)
  AND EXISTS (SELECT 1 FROM active_entity e WHERE e.uid=a.entity_uid);

CREATE VIEW active_assertion AS
SELECT a.* FROM assertion a LEFT JOIN assertion_state s ON s.assertion_uid = a.uid
WHERE coalesce(s.active, 1) = 1;

CREATE VIEW active_document AS
SELECT d.* FROM document d WHERE
EXISTS (SELECT 1 FROM source_record s WHERE s.current_document_uid = d.uid AND s.active = 1)
OR EXISTS (
    SELECT 1 FROM field_provenance p JOIN catalog_entry c
    ON c.current_revision_uid = p.revision_uid AND c.active = 1
    WHERE p.document_uid = d.uid
)
OR EXISTS (
    SELECT 1 FROM evidence e JOIN assertion_evidence ae ON ae.evidence_uid = e.uid
    JOIN active_assertion a ON a.uid = ae.assertion_uid WHERE e.document_uid = d.uid
);
