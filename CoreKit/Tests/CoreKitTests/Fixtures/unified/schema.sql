PRAGMA foreign_keys = ON;

CREATE TABLE metadata (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
);

CREATE TABLE entity (
    uid TEXT PRIMARY KEY CHECK (length(trim(uid)) > 0),
    kind TEXT NOT NULL CHECK (kind IN
        ('drug', 'hospital', 'diagnosis', 'symptom', 'statement', 'address', 'department',
         'exam', 'drug_reference')),
    region TEXT NOT NULL CHECK (length(trim(region)) > 0),
    local_id TEXT NOT NULL CHECK (length(trim(local_id)) > 0),
    name TEXT NOT NULL,
    UNIQUE (kind, region, local_id),
    UNIQUE (uid, kind, region),
    UNIQUE (uid, region)
);

CREATE TABLE drug_identity (
    entity_uid TEXT PRIMARY KEY,
    kind TEXT NOT NULL DEFAULT 'drug' CHECK (kind = 'drug'),
    region TEXT NOT NULL,
    ingredient_text TEXT NOT NULL DEFAULT '',
    dosage_form TEXT NOT NULL DEFAULT '',
    strength_text TEXT NOT NULL DEFAULT '',
    FOREIGN KEY (entity_uid, kind, region) REFERENCES entity(uid, kind, region)
);

CREATE TABLE hospital_campus (
    entity_uid TEXT PRIMARY KEY,
    kind TEXT NOT NULL DEFAULT 'hospital' CHECK (kind = 'hospital'),
    region TEXT NOT NULL,
    campus_name TEXT NOT NULL,
    FOREIGN KEY (entity_uid, kind, region) REFERENCES entity(uid, kind, region)
);

CREATE TABLE source (
    uid TEXT PRIMARY KEY CHECK (length(trim(uid)) > 0),
    name TEXT NOT NULL CHECK (length(trim(name)) > 0)
);

CREATE TABLE source_version (
    source_uid TEXT NOT NULL REFERENCES source(uid),
    version TEXT NOT NULL CHECK (length(trim(version)) > 0),
    region TEXT NOT NULL CHECK (length(trim(region)) > 0),
    status TEXT NOT NULL CHECK (status IN ('current', 'historical')),
    PRIMARY KEY (source_uid, version),
    UNIQUE (source_uid, version, region)
);
CREATE INDEX source_version_current ON source_version(source_uid)
    WHERE status = 'current';

CREATE TABLE document (
    uid TEXT PRIMARY KEY CHECK (length(trim(uid)) > 0),
    source_uid TEXT NOT NULL,
    source_version TEXT NOT NULL,
    region TEXT NOT NULL,
    title TEXT NOT NULL,
    uri TEXT NOT NULL,
    full_text TEXT NOT NULL CHECK (length(trim(full_text)) > 0),
    UNIQUE (uid, region),
    FOREIGN KEY (source_uid, source_version, region)
        REFERENCES source_version(source_uid, version, region)
);

CREATE TABLE evidence (
    uid TEXT PRIMARY KEY CHECK (length(trim(uid)) > 0),
    document_uid TEXT NOT NULL,
    region TEXT NOT NULL,
    locator TEXT NOT NULL CHECK (length(trim(locator)) > 0),
    full_text TEXT NOT NULL CHECK (length(trim(full_text)) > 0),
    UNIQUE (uid, region),
    FOREIGN KEY (document_uid, region) REFERENCES document(uid, region)
);

CREATE TABLE relation_rule (
    relation TEXT NOT NULL CHECK (relation IN
        ('indication', 'adverse', 'contraindication', 'directions', 'spec', 'address', 'departments')),
    subject_kind TEXT NOT NULL,
    object_kind TEXT NOT NULL,
    PRIMARY KEY (relation, subject_kind, object_kind),
    CHECK (
        (subject_kind = 'drug' AND (
            (relation = 'indication' AND object_kind IN ('diagnosis', 'statement'))
            OR (relation IN ('adverse', 'contraindication') AND object_kind IN ('symptom', 'diagnosis', 'statement'))
            OR (relation IN ('directions', 'spec') AND object_kind = 'statement')
        ))
        OR (subject_kind = 'hospital' AND (
            (relation = 'address' AND object_kind = 'address')
            OR (relation = 'departments' AND object_kind = 'department')
        ))
    )
);
INSERT INTO relation_rule VALUES
    ('indication', 'drug', 'diagnosis'),
    ('indication', 'drug', 'statement'),
    ('adverse', 'drug', 'symptom'),
    ('adverse', 'drug', 'diagnosis'),
    ('adverse', 'drug', 'statement'),
    ('contraindication', 'drug', 'diagnosis'),
    ('contraindication', 'drug', 'symptom'),
    ('contraindication', 'drug', 'statement'),
    ('directions', 'drug', 'statement'),
    ('spec', 'drug', 'statement'),
    ('address', 'hospital', 'address'),
    ('departments', 'hospital', 'department');

CREATE TABLE assertion (
    uid TEXT PRIMARY KEY CHECK (length(trim(uid)) > 0),
    subject_uid TEXT NOT NULL,
    subject_kind TEXT NOT NULL,
    object_uid TEXT NOT NULL,
    object_kind TEXT NOT NULL,
    region TEXT NOT NULL,
    relation TEXT NOT NULL,
    polarity TEXT NOT NULL CHECK (polarity IN ('positive', 'negative', 'uncertain')),
    derivation TEXT NOT NULL CHECK (derivation IN ('explicit', 'mapped', 'inferred')),
    review_status TEXT NOT NULL CHECK (review_status IN ('approved', 'pending', 'conflict')),
    condition_text TEXT NOT NULL DEFAULT '',
    condition_json TEXT NOT NULL DEFAULT '{}' CHECK (json_valid(condition_json)),
    condition_status TEXT NOT NULL DEFAULT 'unevaluated' CHECK (condition_status = 'unevaluated'),
    qualifier_text TEXT NOT NULL DEFAULT '',
    qualifier_json TEXT NOT NULL DEFAULT '{}' CHECK (json_valid(qualifier_json)),
    UNIQUE (uid, region),
    FOREIGN KEY (subject_uid, subject_kind, region) REFERENCES entity(uid, kind, region),
    FOREIGN KEY (object_uid, object_kind, region) REFERENCES entity(uid, kind, region),
    FOREIGN KEY (relation, subject_kind, object_kind)
        REFERENCES relation_rule(relation, subject_kind, object_kind)
);
CREATE INDEX assertion_forward ON assertion(subject_uid, relation);
CREATE INDEX assertion_reverse ON assertion(object_uid, relation);

CREATE TABLE assertion_evidence (
    assertion_uid TEXT NOT NULL,
    evidence_uid TEXT NOT NULL,
    region TEXT NOT NULL,
    role TEXT NOT NULL CHECK (role IN ('support', 'refute')),
    PRIMARY KEY (assertion_uid, evidence_uid, role),
    FOREIGN KEY (assertion_uid, region) REFERENCES assertion(uid, region),
    FOREIGN KEY (evidence_uid, region) REFERENCES evidence(uid, region)
);

CREATE TABLE alias (
    uid TEXT PRIMARY KEY,
    entity_uid TEXT NOT NULL,
    region TEXT NOT NULL,
    text TEXT NOT NULL CHECK (length(trim(text)) > 0),
    status TEXT NOT NULL CHECK (status IN ('approved', 'candidate')),
    FOREIGN KEY (entity_uid, region) REFERENCES entity(uid, region)
);
CREATE INDEX alias_approved ON alias(region, text) WHERE status = 'approved';

CREATE TABLE closure (
    scheme TEXT NOT NULL,
    version TEXT NOT NULL,
    ancestor_uid TEXT NOT NULL,
    descendant_uid TEXT NOT NULL,
    region TEXT NOT NULL,
    depth INTEGER NOT NULL CHECK (depth >= 0),
    PRIMARY KEY (scheme, version, ancestor_uid, descendant_uid),
    FOREIGN KEY (ancestor_uid, region) REFERENCES entity(uid, region),
    FOREIGN KEY (descendant_uid, region) REFERENCES entity(uid, region)
);

CREATE VIEW graph_projection AS
SELECT uid AS assertion_id, subject_uid, object_uid, region, relation,
       polarity, derivation, review_status, condition_text, condition_json,
       condition_status, qualifier_text, qualifier_json
FROM assertion a
WHERE NOT EXISTS (
    SELECT 1 FROM assertion_state s WHERE s.assertion_uid=a.uid AND s.active=0
);

CREATE VIEW effective_facts AS
SELECT a.uid AS assertion_uid, a.subject_uid AS entity_uid, a.relation,
       a.condition_text, a.polarity, a.qualifier_text,
       e.uid AS evidence_uid, e.full_text AS evidence_full_text, e.locator,
       d.full_text AS document_full_text, d.source_uid, d.source_version
FROM assertion a
JOIN assertion_evidence ae ON ae.assertion_uid = a.uid AND ae.role = 'support'
JOIN evidence e ON e.uid = ae.evidence_uid AND e.region = a.region
JOIN document d ON d.uid = e.document_uid AND d.region = a.region
JOIN source_version sv ON sv.source_uid = d.source_uid
    AND sv.version = d.source_version AND sv.region = a.region
WHERE a.review_status = 'approved'
  AND a.derivation IN ('explicit', 'mapped')
  AND sv.status = 'current'
  AND NOT EXISTS (
      SELECT 1 FROM assertion_state s WHERE s.assertion_uid = a.uid AND s.active = 0
  )
  AND NOT EXISTS (
      SELECT 1 FROM assertion_evidence r
      WHERE r.assertion_uid = a.uid AND r.role = 'refute'
  )
  AND NOT EXISTS (
      SELECT 1 FROM assertion_evidence x
      JOIN evidence xe ON xe.uid = x.evidence_uid
      JOIN document xd ON xd.uid = xe.document_uid
      JOIN source_version xs ON xs.source_uid = xd.source_uid AND xs.version = xd.source_version
      WHERE x.assertion_uid = a.uid AND xs.status != 'current'
  );

CREATE TABLE IF NOT EXISTS source_import_history (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    batch_id TEXT UNIQUE NOT NULL,
    imported_at TEXT NOT NULL,
    source_name TEXT NOT NULL,
    source_db_path TEXT NOT NULL,
    total_records INTEGER NOT NULL,
    valid_records INTEGER NOT NULL,
    duplicate_records INTEGER NOT NULL,
    entities_added INTEGER NOT NULL,
    relations_added INTEGER NOT NULL,
    total_entities INTEGER NOT NULL,
    total_relations INTEGER NOT NULL,
    status TEXT NOT NULL,
    duration_seconds REAL NOT NULL
);
