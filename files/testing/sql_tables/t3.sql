CREATE TABLE t3 (
    id INT NOT NULL,
    fid_t1 INT NOT NULL,
    date DATETIME DEFAULT CURRENT_TIMESTAMP NOT NULL,
    str VARCHAR(500) NOT NULL,
    rid_t7_k_fid_t3 INT NOT NULL,
    PRIMARY KEY (id),
    UNIQUE KEY k_fid_t1 (fid_t1),
    CONSTRAINT k_rid_t7_fid_t3 FOREIGN KEY (rid_t7_k_fid_t3) REFERENCES t7 (fid_t3) ON DELETE CASCADE
) TABLESPACE ts_1 STORAGE DISK ENGINE = NDB;