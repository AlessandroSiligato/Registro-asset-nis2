   # Registro asset, servizi e dipendenze NIS2
   Project Work PW19 - Informatica per le Aziende Digitali (L-31), Università Pegaso.
   Base dati PostgreSQL 16 per catalogare asset, servizi erogati, dipendenze
   da fornitori terzi e responsabilità, con versioning, audit trail ed export CSV
   per i profili ACN.
   Installazione: psql -U postgres -d registro_nis2 -v ON_ERROR_STOP=1 -f nis2_asset_inventory.sql
