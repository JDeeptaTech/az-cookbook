data/raw/*.csv
     │
   dlt  (ingest/pipeline.py)
     │
  bronze.*  ──── PostgreSQL ────  silver.*  ──── gold.*
              (same database,                      │
               same schemas)                       │
                                              Grafana reads here
