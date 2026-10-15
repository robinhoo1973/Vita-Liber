-- TEST-ONLY consumer gate fixture. R is supplied as a signed expectation by tests;
-- this is not a publisher digest golden or an installable production artifact.
PRAGMA user_version = 9;
INSERT INTO catalog_meta VALUES
 ('schema_version','9'),
 ('storage_contract','unified-medical-kg/v1'),
 ('app_catalog_schema_version','4'),
 ('graph_schema_version','2'),
 ('catalog_ready','true'),
 ('content_scope','full'),
 ('producer_input_sha256','cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc'),
 ('producer_data_version','consumer-fixture-v7'),
 ('data_version','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa');
INSERT INTO metadata VALUES
 ('format','vita_liber_evidence_graph'),('schema_version','2'),('lifecycle','versioned'),
 ('release_id','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'),
 ('activation_id','activation-A-1');
INSERT INTO producer_import VALUES
 ('cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc',
  'consumer-fixture-v7','{}','2026-10-01T00:00:00Z');
INSERT INTO drug(id,region,source_id,name_zh,usage_ref_json,region_specific_json,aliases_json) VALUES
 (1,'CN','shared-source','药品甲','{"未知":"保留😀"}','{}','["甲别名"]'),
 (2,'TW','shared-source','藥品乙','{}','{}','["乙別名"]');
INSERT INTO drug_reference(rowid,reference_id,region,source_id,name_zh,normalized_keys_json,spec_ref_json,source_fields_json,image_urls_json,match_status) VALUES
 (21,'ref-cn','CN','shared-source','药品甲说明','[]','{"容量":null}','{}','["https://example.invalid/甲.png"]','exact'),
 (22,'ref-tw','TW','shared-source','藥品乙說明','[]','{}','{}','[]','candidate');
INSERT INTO drug_detail(rowid,region,source_id,usage_text,indications,usage_ref_json,raw_json) VALUES
 (31,'CN','shared-source','CN 原文😀','甲适应症','{}','{"unknown":{"null":null,"integer":9007199254740993}}'),
 (32,'TW','shared-source','TW 原文😀','乙適應症','{}','{"原文":"不截断"}');
INSERT INTO hospital(rowid,region,source_id,code,name_zh,depts_json,aliases_json) VALUES
 (41,'TW','shared-hospital','H1','合成醫院','[{"name_zh":"內科"}]','["測試醫院"]');
INSERT INTO department(rowid,region,source_id,code,name_zh,aliases_json) VALUES
 (51,'TW','shared-department','D1','內科','["内科"]');
INSERT INTO diagnosis(rowid,region,source_id,code,name_zh,code_system,aliases_json) VALUES
 (61,'CN','shared-diagnosis','R05','咳嗽','icd10_cn','["咳痰"]');
INSERT INTO exam_item(rowid,region,source_id,code,name_zh,unit,price_ref,loinc_concept_id,aliases_json) VALUES
 (71,'TW','shared-exam','E1','合成檢驗',NULL,NULL,NULL,'[]');
INSERT INTO entity(uid,kind,region,local_id,name) VALUES
 ('canonical-drug-甲','drug','CN','canonical-key-1','药品甲'),
 ('canonical-drug-乙','drug','TW','canonical-key-2','藥品乙'),
 ('canonical-ref-甲','drug_reference','CN','canonical-key-3','药品甲说明'),
 ('canonical-ref-乙','drug_reference','TW','canonical-key-4','藥品乙說明'),
 ('canonical-hospital','hospital','TW','canonical-key-5','合成醫院'),
 ('canonical-department','department','TW','canonical-key-6','內科'),
 ('canonical-diagnosis','diagnosis','CN','canonical-key-7','咳嗽'),
 ('canonical-exam','exam','TW','canonical-key-8','合成檢驗');
INSERT INTO catalog_entry(entry_uid,table_name,region,source_id,record_id,entity_uid,app_row_id,current_revision_uid,active) VALUES
 ('entry-drug-cn','drug','CN','shared-source','["CN","shared-source"]','canonical-drug-甲',1,NULL,1),
 ('entry-drug-tw','drug','TW','shared-source','["TW","shared-source"]','canonical-drug-乙',2,NULL,1),
 ('entry-ref-cn','drug_reference','CN','shared-source','["ref-cn"]','canonical-ref-甲',21,NULL,1),
 ('entry-ref-tw','drug_reference','TW','shared-source','["ref-tw"]','canonical-ref-乙',22,NULL,1),
 ('entry-detail-cn','drug_detail','CN','shared-source','["CN","shared-source"]','canonical-drug-甲',31,NULL,1),
 ('entry-detail-tw','drug_detail','TW','shared-source','["TW","shared-source"]','canonical-drug-乙',32,NULL,1),
 ('entry-hospital','hospital','TW','shared-hospital','["TW","shared-hospital"]','canonical-hospital',41,NULL,1),
 ('entry-department','department','TW','shared-department','["TW","shared-department"]','canonical-department',51,NULL,1),
 ('entry-diagnosis','diagnosis','CN','shared-diagnosis','["CN","shared-diagnosis"]','canonical-diagnosis',61,NULL,1),
 ('entry-exam','exam_item','TW','shared-exam','["TW","shared-exam"]','canonical-exam',71,NULL,1);
INSERT INTO catalog_revision(revision_uid,entry_uid,content_sha256,row_json,provenance_json,created_at)
 SELECT 'revision-'||entry_uid,entry_uid,
 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb','{}','{}','2026-10-01T00:00:00Z'
 FROM catalog_entry;
UPDATE catalog_entry SET current_revision_uid='revision-'||entry_uid;
INSERT INTO graph_release VALUES
 ('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',1,
 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','full','validated','{}',10,8,0,'2026-10-01T00:00:00Z');
INSERT INTO graph_activation VALUES
 ('activation-A-1',1,'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','2026-10-01T00:00:00Z');
