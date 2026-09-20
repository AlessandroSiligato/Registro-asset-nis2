-- =====================================================================
--  PROJECT WORK - INVENTARIO ASSET / SERVIZI / FORNITORI (NIS2 - ACN)
--  Ente fittizio:  Comune di Valmontana (Ente Pubblico - soggetto essenziale)
--  DBMS:           PostgreSQL 14+ (verificato su PostgreSQL 16)
--  Autore:         Alessandro Pio Siligato - matricola 0312301028
--  Corso:          Informatica per le Aziende Digitali (L-31) - Universita' Pegaso
--  Project Work:   PW 19 - Tema 2 "Privacy e sicurezza aziendale"
--  Riferimenti:    Direttiva (UE) 2022/2555 - D.Lgs. 138/2024 (NIS2) - profili ACN
--  NOTA:           tutti i dati di popolamento (ente, persone, fornitori, contratti,
--                  indirizzi IP e seriali) sono interamente simulati.
--
--  Struttura dello script (eseguibile "as-is" in ordine):
--    0. Reset ambiente e creazione schema
--    1. Tipi enumerati
--    2. Tabelle anagrafiche di supporto (lookup / dimensioni)
--    3. Tabelle principali: responsabili, fornitori, asset, servizi
--    4. Tabelle di relazione N:N (asset<->servizio, servizio<->fornitore,
--       asset<->fornitore)
--    5. Versioning + storico: tabella di log e trigger di audit
--    6. Indici di performance
--    7. Popolamento dati simulati (INSERT)
--    8. VIEW finale per export CSV (profilo ACN)
--    9. Test funzionale del trigger di audit
--
--  Nota di normalizzazione (3NF):
--    - Nessun gruppo ripetuto: le relazioni molti-a-molti sono risolte con
--      tabelle ponte (asset_servizio, servizio_fornitore, asset_fornitore).
--    - Nessuna dipendenza parziale: tutte le tabelle ponte hanno PK composita
--      e attributi dipendenti dall'intera chiave.
--    - Nessuna dipendenza transitiva: vendor, categorie, sedi, unità
--      organizzative e tipologie fornitore sono estratti in tabelle dedicate.
-- =====================================================================


-- =====================================================================
-- 0. RESET AMBIENTE E CREAZIONE SCHEMA
-- =====================================================================
DROP SCHEMA IF EXISTS nis2 CASCADE;
CREATE SCHEMA nis2;
COMMENT ON SCHEMA nis2 IS 'Inventario centralizzato asset/servizi/fornitori ai fini NIS2 - Comune di Valmontana';

SET search_path TO nis2, public;


-- =====================================================================
-- 1. TIPI ENUMERATI (domini controllati - evitano valori liberi)
-- =====================================================================

-- Livello di criticità unificato (asset e servizi) - scala ACN a 4 livelli
CREATE TYPE livello_criticita AS ENUM ('BASSA', 'MEDIA', 'ALTA', 'CRITICA');

-- Stato del ciclo di vita di un asset
CREATE TYPE stato_asset AS ENUM ('IN_PRODUZIONE', 'IN_TEST', 'DISMESSO', 'IN_MANUTENZIONE', 'STOCK');

-- Tipologia di ambiente
CREATE TYPE tipo_ambiente AS ENUM ('PRODUZIONE', 'DISASTER_RECOVERY', 'TEST', 'SVILUPPO');

-- Esposizione del servizio
CREATE TYPE esposizione_servizio AS ENUM ('INTERNET', 'INTRANET', 'EXTRANET_PA');

-- Ruolo che un asset ricopre verso un servizio
CREATE TYPE ruolo_asset_servizio AS ENUM (
    'HOSTING',            -- ospita l'applicazione / DB
    'CONNETTIVITA',       -- switch / router / link
    'PROTEZIONE',         -- firewall / WAF / IPS
    'AUTENTICAZIONE',     -- IdP / AD / SPID proxy
    'STORAGE',            -- SAN / NAS / backup
    'MONITORAGGIO'        -- SIEM / NMS
);

-- Natura della dipendenza da un fornitore
CREATE TYPE tipo_dipendenza AS ENUM (
    'CONNETTIVITA', 'CLOUD_HOSTING', 'SAAS', 'MANUTENZIONE_HW',
    'MANUTENZIONE_SW', 'SUPPORTO_SPECIALISTICO', 'INTEROPERABILITA_PA'
);

-- Operazione registrata dal trigger di audit
CREATE TYPE operazione_audit AS ENUM ('INSERT', 'UPDATE', 'DELETE');


-- =====================================================================
-- 2. TABELLE ANAGRAFICHE DI SUPPORTO
-- =====================================================================

-- --- Unità organizzative dell'Ente ------------------------------------
CREATE TABLE unita_organizzativa (
    id_unita          SERIAL       PRIMARY KEY,
    codice            VARCHAR(20)  NOT NULL UNIQUE,      -- es. 'SIC', 'ANAG'
    denominazione     VARCHAR(150) NOT NULL,
    id_unita_padre    INTEGER      REFERENCES unita_organizzativa(id_unita)
                                   ON DELETE SET NULL,   -- gerarchia (self-FK)
    CONSTRAINT chk_unita_no_self CHECK (id_unita_padre IS NULL OR id_unita_padre <> id_unita)
);
COMMENT ON TABLE unita_organizzativa IS 'Organigramma dell''Ente (settori, servizi, uffici)';

-- --- Sedi / ubicazioni fisiche ----------------------------------------
CREATE TABLE sede (
    id_sede           SERIAL       PRIMARY KEY,
    codice            VARCHAR(20)  NOT NULL UNIQUE,      -- es. 'DC1', 'DC2'
    denominazione     VARCHAR(150) NOT NULL,
    indirizzo         VARCHAR(250) NOT NULL,
    citta             VARCHAR(100) NOT NULL,
    tipo_sede         VARCHAR(30)  NOT NULL
        CHECK (tipo_sede IN ('DATACENTER', 'SEDE_ISTITUZIONALE', 'SEDE_DECENTRATA', 'CLOUD_ESTERNO')),
    controllo_accessi BOOLEAN      NOT NULL DEFAULT TRUE
);
COMMENT ON TABLE sede IS 'Ubicazioni fisiche/logiche degli asset (data center, sedi, cloud)';

-- --- Vendor / produttori hardware e software ---------------------------
CREATE TABLE vendor (
    id_vendor         SERIAL       PRIMARY KEY,
    nome              VARCHAR(100) NOT NULL UNIQUE,      -- Juniper, Fortinet, ...
    sito_psirt        VARCHAR(250),                      -- URL advisory sicurezza
    paese_sede        CHAR(2)      NOT NULL DEFAULT 'US' -- ISO 3166-1 alpha-2
);
COMMENT ON TABLE vendor IS 'Produttori degli apparati/software (per tracciare advisory e supply chain)';

-- --- Categorie di asset ----------------------------------------------
CREATE TABLE categoria_asset (
    id_categoria      SERIAL       PRIMARY KEY,
    codice            VARCHAR(20)  NOT NULL UNIQUE,      -- 'SWITCH','FIREWALL',...
    descrizione       VARCHAR(150) NOT NULL,
    livello_iso       VARCHAR(30)  NOT NULL              -- famiglia ISO/IEC 27001 A.8
        CHECK (livello_iso IN ('RETE', 'SICUREZZA', 'ELABORAZIONE', 'STORAGE', 'END_USER', 'VIRTUALE'))
);
COMMENT ON TABLE categoria_asset IS 'Tassonomia degli asset (rete, sicurezza, elaborazione, ...)';

-- --- Tipologie di fornitore --------------------------------------------
CREATE TABLE tipo_fornitore (
    id_tipo_fornitore SERIAL       PRIMARY KEY,
    codice            VARCHAR(20)  NOT NULL UNIQUE,      -- 'ISP','CLOUD','SW_HOUSE'
    descrizione       VARCHAR(150) NOT NULL
);
COMMENT ON TABLE tipo_fornitore IS 'Classificazione delle terze parti';


-- =====================================================================
-- 3. TABELLE PRINCIPALI
-- =====================================================================

-- --- Responsabili / Punti di contatto ----------------------------------
CREATE TABLE responsabile (
    id_responsabile   SERIAL       PRIMARY KEY,
    nome              VARCHAR(80)  NOT NULL,
    cognome           VARCHAR(80)  NOT NULL,
    ruolo             VARCHAR(120) NOT NULL,             -- es. 'CISO', 'RTD', ...
    email             VARCHAR(150) NOT NULL UNIQUE,
    telefono          VARCHAR(30),
    telefono_reperibilita VARCHAR(30),                   -- H24 per incidenti
    id_unita          INTEGER      NOT NULL REFERENCES unita_organizzativa(id_unita)
                                   ON DELETE RESTRICT,
    punto_contatto_acn BOOLEAN     NOT NULL DEFAULT FALSE, -- referente notifiche CSIRT
    attivo            BOOLEAN      NOT NULL DEFAULT TRUE,
    CONSTRAINT chk_resp_email CHECK (email ~* '^[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}$')
);
COMMENT ON TABLE responsabile IS 'Owner organizzativi e punti di contatto (art. 7 D.Lgs. 138/2024)';

-- --- Fornitori terzi -----------------------------------------------
CREATE TABLE fornitore (
    id_fornitore      SERIAL       PRIMARY KEY,
    ragione_sociale   VARCHAR(200) NOT NULL,
    partita_iva       VARCHAR(16)  NOT NULL UNIQUE,
    id_tipo_fornitore INTEGER      NOT NULL REFERENCES tipo_fornitore(id_tipo_fornitore)
                                   ON DELETE RESTRICT,
    paese             CHAR(2)      NOT NULL DEFAULT 'IT',
    referente_nome    VARCHAR(150),
    referente_email   VARCHAR(150),
    telefono_noc      VARCHAR(30),                       -- contatto operativo H24
    numero_contratto  VARCHAR(50),
    data_inizio_contratto DATE,
    data_fine_contratto   DATE,
    sla_ripristino_ore    NUMERIC(6,2),                  -- SLA contrattuale (ore)
    certificazione_iso27001 BOOLEAN NOT NULL DEFAULT FALSE,
    qualificato_acn       BOOLEAN NOT NULL DEFAULT FALSE, -- catalogo cloud ACN
    CONSTRAINT chk_forn_date CHECK (data_fine_contratto IS NULL OR data_fine_contratto >= data_inizio_contratto),
    CONSTRAINT chk_forn_sla  CHECK (sla_ripristino_ore IS NULL OR sla_ripristino_ore > 0)
);
COMMENT ON TABLE fornitore IS 'Terze parti da cui dipendono asset/servizi (supply chain NIS2, art. 24)';

-- --- ASSET (tabella centrale, soggetta a versioning e audit) -----------
CREATE TABLE asset (
    id_asset          SERIAL       PRIMARY KEY,
    codice_inventario VARCHAR(30)  NOT NULL UNIQUE,      -- es. 'CVM-NET-0001'
    hostname          VARCHAR(100) NOT NULL UNIQUE,
    ip_gestione       INET,                              -- IP management (OOB/inband)
    id_categoria      INTEGER      NOT NULL REFERENCES categoria_asset(id_categoria) ON DELETE RESTRICT,
    id_vendor         INTEGER      NOT NULL REFERENCES vendor(id_vendor)             ON DELETE RESTRICT,
    modello           VARCHAR(100) NOT NULL,
    numero_seriale    VARCHAR(80)  UNIQUE,
    versione_firmware VARCHAR(80),
    sistema_operativo VARCHAR(100),
    id_sede           INTEGER      NOT NULL REFERENCES sede(id_sede)                 ON DELETE RESTRICT,
    rack_posizione    VARCHAR(30),                       -- es. 'R03-U12'
    ambiente          tipo_ambiente NOT NULL DEFAULT 'PRODUZIONE',
    criticita         livello_criticita NOT NULL,
    stato             stato_asset  NOT NULL DEFAULT 'IN_PRODUZIONE',
    id_responsabile   INTEGER      NOT NULL REFERENCES responsabile(id_responsabile) ON DELETE RESTRICT,
    id_responsabile_backup INTEGER REFERENCES responsabile(id_responsabile)          ON DELETE SET NULL,
    data_installazione DATE,
    data_fine_supporto DATE,                             -- End of Support del vendor
    ultimo_patch      DATE,
    cifratura_dati    BOOLEAN      NOT NULL DEFAULT FALSE,
    mfa_amministrativo BOOLEAN     NOT NULL DEFAULT FALSE,
    note              TEXT,
    -- ---- campi di versioning ----
    versione          INTEGER      NOT NULL DEFAULT 1,
    creato_il         TIMESTAMPTZ  NOT NULL DEFAULT now(),
    creato_da         VARCHAR(100) NOT NULL DEFAULT current_user,
    modificato_il     TIMESTAMPTZ  NOT NULL DEFAULT now(),
    modificato_da     VARCHAR(100) NOT NULL DEFAULT current_user,
    CONSTRAINT chk_asset_resp_diverso CHECK (id_responsabile_backup IS NULL OR id_responsabile_backup <> id_responsabile),
    CONSTRAINT chk_asset_date CHECK (data_fine_supporto IS NULL OR data_installazione IS NULL OR data_fine_supporto >= data_installazione)
);
COMMENT ON TABLE asset IS 'Inventario asset ICT (server, switch, firewall, storage, ...) - tabella auditata';
COMMENT ON COLUMN asset.versione IS 'Numero di versione del record, incrementato automaticamente ad ogni UPDATE';

-- --- Servizi erogati ---------------------------------------------------
CREATE TABLE servizio (
    id_servizio       SERIAL       PRIMARY KEY,
    codice            VARCHAR(20)  NOT NULL UNIQUE,      -- 'SRV-ANPR'
    nome              VARCHAR(150) NOT NULL,
    descrizione       TEXT,
    esposizione       esposizione_servizio NOT NULL,
    url_pubblico      VARCHAR(250),
    criticita         livello_criticita NOT NULL,
    servizio_essenziale BOOLEAN    NOT NULL DEFAULT FALSE, -- perimetro NIS2 / PSNC
    tratta_dati_personali BOOLEAN  NOT NULL DEFAULT TRUE,
    rto_ore           NUMERIC(6,2) NOT NULL,             -- Recovery Time Objective
    rpo_ore           NUMERIC(6,2) NOT NULL,             -- Recovery Point Objective
    id_responsabile   INTEGER      NOT NULL REFERENCES responsabile(id_responsabile) ON DELETE RESTRICT,
    id_unita_erogante INTEGER      NOT NULL REFERENCES unita_organizzativa(id_unita) ON DELETE RESTRICT,
    attivo            BOOLEAN      NOT NULL DEFAULT TRUE,
    CONSTRAINT chk_srv_rto CHECK (rto_ore >= 0),
    CONSTRAINT chk_srv_rpo CHECK (rpo_ore >= 0),
    CONSTRAINT chk_srv_url CHECK (esposizione <> 'INTERNET' OR url_pubblico IS NOT NULL)
);
COMMENT ON TABLE servizio IS 'Servizi erogati ai cittadini / interni (catalogo servizi)';


-- =====================================================================
-- 4. TABELLE DI RELAZIONE (N:N)
-- =====================================================================

-- Asset -> Servizio: quali asset sostengono ciascun servizio
CREATE TABLE asset_servizio (
    id_asset          INTEGER      NOT NULL REFERENCES asset(id_asset)       ON DELETE CASCADE,
    id_servizio       INTEGER      NOT NULL REFERENCES servizio(id_servizio) ON DELETE CASCADE,
    ruolo             ruolo_asset_servizio NOT NULL,
    single_point_of_failure BOOLEAN NOT NULL DEFAULT FALSE, -- assenza ridondanza
    note              VARCHAR(250),
    PRIMARY KEY (id_asset, id_servizio, ruolo)
);
COMMENT ON TABLE asset_servizio IS 'Mappa di dipendenza servizio -> asset (Business Impact Analysis)';

-- Servizio -> Fornitore: dipendenze dei servizi da terze parti
CREATE TABLE servizio_fornitore (
    id_servizio       INTEGER      NOT NULL REFERENCES servizio(id_servizio)   ON DELETE CASCADE,
    id_fornitore      INTEGER      NOT NULL REFERENCES fornitore(id_fornitore) ON DELETE RESTRICT,
    tipo_dipendenza   tipo_dipendenza NOT NULL,
    criticita_dipendenza livello_criticita NOT NULL,
    esiste_alternativa BOOLEAN     NOT NULL DEFAULT FALSE, -- fornitore sostituibile?
    note              VARCHAR(250),
    PRIMARY KEY (id_servizio, id_fornitore, tipo_dipendenza)
);
COMMENT ON TABLE servizio_fornitore IS 'Dipendenze di ogni servizio da fornitori esterni';

-- Asset -> Fornitore: contratti di manutenzione / supporto sugli apparati
CREATE TABLE asset_fornitore (
    id_asset          INTEGER      NOT NULL REFERENCES asset(id_asset)         ON DELETE CASCADE,
    id_fornitore      INTEGER      NOT NULL REFERENCES fornitore(id_fornitore) ON DELETE RESTRICT,
    tipo_dipendenza   tipo_dipendenza NOT NULL,
    livello_supporto  VARCHAR(50),                       -- es. 'NBD', '4h', '24x7'
    scadenza_supporto DATE,
    PRIMARY KEY (id_asset, id_fornitore, tipo_dipendenza)
);
COMMENT ON TABLE asset_fornitore IS 'Contratti di supporto/manutenzione per singolo asset';


-- =====================================================================
-- 5. VERSIONING E STORICO: TABELLA DI LOG + TRIGGER DI AUDIT
-- =====================================================================

-- --- 5.1 Tabella di storico (append-only) ------------------------------
CREATE TABLE asset_storico (
    id_storico        BIGSERIAL    PRIMARY KEY,
    id_asset          INTEGER      NOT NULL,             -- NON FK: deve sopravvivere al DELETE
    codice_inventario VARCHAR(30)  NOT NULL,
    operazione        operazione_audit NOT NULL,
    versione_precedente INTEGER,
    versione_nuova    INTEGER,
    dati_precedenti   JSONB,                             -- snapshot OLD (NULL su INSERT)
    dati_nuovi        JSONB,                             -- snapshot NEW (NULL su DELETE)
    campi_modificati  TEXT[],                            -- elenco colonne variate
    eseguito_da       VARCHAR(100) NOT NULL DEFAULT current_user,
    eseguito_il       TIMESTAMPTZ  NOT NULL DEFAULT clock_timestamp(),
    sessione_pid      INTEGER      NOT NULL DEFAULT pg_backend_pid(),
    indirizzo_client  INET         DEFAULT inet_client_addr(),
    applicazione      VARCHAR(100) DEFAULT current_setting('application_name', true)
);
COMMENT ON TABLE asset_storico IS 'Audit trail immutabile di tutte le modifiche alla tabella asset';

-- Protezione dello storico: nessuno (nemmeno per errore applicativo) può
-- aggiornare o cancellare righe di audit -> requisito di integrità dei log.
CREATE OR REPLACE FUNCTION fn_blocca_modifica_storico()
RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'La tabella asset_storico è append-only: operazione % non consentita', TG_OP
        USING ERRCODE = 'insufficient_privilege';
END;
$$;

CREATE TRIGGER trg_storico_immutabile
    BEFORE UPDATE OR DELETE ON asset_storico
    FOR EACH ROW EXECUTE FUNCTION fn_blocca_modifica_storico();

-- --- 5.2 Trigger BEFORE UPDATE: incremento versione + timestamp ---------
CREATE OR REPLACE FUNCTION fn_asset_versioning()
RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    -- UPDATE "a vuoto" (nessun dato di business variato): la riga non viene
    -- toccata, così la versione non avanza senza una modifica reale
    IF (to_jsonb(OLD) - 'versione' - 'modificato_il' - 'modificato_da')
       = (to_jsonb(NEW) - 'versione' - 'modificato_il' - 'modificato_da') THEN
        RETURN NULL;
    END IF;
    -- Preserva i metadati di creazione (non modificabili da applicativo)
    NEW.creato_il := OLD.creato_il;
    NEW.creato_da := OLD.creato_da;
    -- Aggiorna metadati di modifica e incrementa la versione
    NEW.versione      := OLD.versione + 1;
    NEW.modificato_il := now();
    NEW.modificato_da := current_user;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_asset_versioning
    BEFORE UPDATE ON asset
    FOR EACH ROW EXECUTE FUNCTION fn_asset_versioning();

-- --- 5.3 Trigger AFTER INSERT/UPDATE/DELETE: scrittura audit ------------
CREATE OR REPLACE FUNCTION fn_asset_audit()
RETURNS TRIGGER
LANGUAGE plpgsql AS $$
DECLARE
    v_old      JSONB;
    v_new      JSONB;
    v_campi    TEXT[];
    v_key      TEXT;
BEGIN
    IF TG_OP = 'INSERT' THEN
        v_new := to_jsonb(NEW);
        INSERT INTO asset_storico (id_asset, codice_inventario, operazione,
                                   versione_precedente, versione_nuova,
                                   dati_precedenti, dati_nuovi, campi_modificati)
        VALUES (NEW.id_asset, NEW.codice_inventario, 'INSERT',
                NULL, NEW.versione, NULL, v_new, NULL);
        RETURN NEW;

    ELSIF TG_OP = 'UPDATE' THEN
        v_old := to_jsonb(OLD);
        v_new := to_jsonb(NEW);
        -- Calcolo dinamico delle colonne effettivamente variate
        -- (esclusi i campi tecnici di versioning, sempre diversi)
        SELECT array_agg(k ORDER BY k)
          INTO v_campi
          FROM jsonb_object_keys(v_new) AS k
         WHERE v_old -> k IS DISTINCT FROM v_new -> k
           AND k NOT IN ('versione', 'modificato_il', 'modificato_da');

        -- Se nulla è cambiato (UPDATE "a vuoto") non si registra
        IF v_campi IS NULL THEN
            RETURN NEW;
        END IF;

        INSERT INTO asset_storico (id_asset, codice_inventario, operazione,
                                   versione_precedente, versione_nuova,
                                   dati_precedenti, dati_nuovi, campi_modificati)
        VALUES (NEW.id_asset, NEW.codice_inventario, 'UPDATE',
                OLD.versione, NEW.versione, v_old, v_new, v_campi);
        RETURN NEW;

    ELSIF TG_OP = 'DELETE' THEN
        v_old := to_jsonb(OLD);
        INSERT INTO asset_storico (id_asset, codice_inventario, operazione,
                                   versione_precedente, versione_nuova,
                                   dati_precedenti, dati_nuovi, campi_modificati)
        VALUES (OLD.id_asset, OLD.codice_inventario, 'DELETE',
                OLD.versione, NULL, v_old, NULL, NULL);
        RETURN OLD;
    END IF;
    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_asset_audit
    AFTER INSERT OR UPDATE OR DELETE ON asset
    FOR EACH ROW EXECUTE FUNCTION fn_asset_audit();

-- Funzione di utilità: ricostruisce lo stato di un asset a una data/ora
CREATE OR REPLACE FUNCTION fn_asset_as_of(p_id_asset INTEGER, p_istante TIMESTAMPTZ)
RETURNS JSONB
LANGUAGE sql STABLE AS $$
    SELECT dati_nuovi
      FROM asset_storico
     WHERE id_asset = p_id_asset
       AND eseguito_il <= p_istante
       AND operazione <> 'DELETE'
     ORDER BY eseguito_il DESC, id_storico DESC
     LIMIT 1;
$$;
COMMENT ON FUNCTION fn_asset_as_of IS 'Point-in-time recovery logico: stato JSON di un asset a un istante dato';


-- =====================================================================
-- 6. INDICI
-- =====================================================================
CREATE INDEX idx_asset_categoria    ON asset(id_categoria);
CREATE INDEX idx_asset_sede         ON asset(id_sede);
CREATE INDEX idx_asset_responsabile ON asset(id_responsabile);
CREATE INDEX idx_asset_criticita    ON asset(criticita) WHERE stato = 'IN_PRODUZIONE';
CREATE INDEX idx_asset_fine_supp    ON asset(data_fine_supporto);
CREATE INDEX idx_servizio_resp      ON servizio(id_responsabile);
CREATE INDEX idx_asset_servizio_srv ON asset_servizio(id_servizio);
CREATE INDEX idx_srv_forn_forn      ON servizio_fornitore(id_fornitore);
CREATE INDEX idx_storico_asset_ts   ON asset_storico(id_asset, eseguito_il DESC);
CREATE INDEX idx_storico_dati_gin   ON asset_storico USING GIN (dati_nuovi);


-- =====================================================================
-- 7. POPOLAMENTO DATI SIMULATI
-- =====================================================================
BEGIN;

-- --- 7.1 Unità organizzative -----------------------------------------
INSERT INTO unita_organizzativa (codice, denominazione, id_unita_padre) VALUES
    ('DG',    'Direzione Generale',                                      NULL);
INSERT INTO unita_organizzativa (codice, denominazione, id_unita_padre) VALUES
    ('SIC',   'Settore Sistemi Informativi e Transizione Digitale',      1),
    ('SERV',  'Settore Servizi al Cittadino',                            1),
    ('FIN',   'Settore Risorse Finanziarie e Tributi',                   1),
    ('PL',    'Corpo di Polizia Locale',                                 1),
    ('SUAP',  'Sportello Unico Attività Produttive',                     3),
    ('ANAG',  'Ufficio Anagrafe e Stato Civile',                         3),
    ('PROT',  'Ufficio Protocollo e Archivio',                           1),
    ('SEC',   'Ufficio Sicurezza Informatica (CISO Office)',             2),
    ('NET',   'Ufficio Reti e Data Center',                              2);

-- --- 7.2 Sedi ---------------------------------------------------------
INSERT INTO sede (codice, denominazione, indirizzo, citta, tipo_sede, controllo_accessi) VALUES
    ('DC1',    'Data Center primario - Palazzo Comunale',       'Piazza del Municipio 1',   'Valmontana', 'DATACENTER',         TRUE),
    ('DC2',    'Sala CED secondaria / DR - Polo Tecnologico',   'Via dell''Industria 42',   'Valmontana', 'DATACENTER',         TRUE),
    ('PAL',    'Palazzo Comunale - Uffici',                     'Piazza del Municipio 1',   'Valmontana', 'SEDE_ISTITUZIONALE', TRUE),
    ('PLOC',   'Comando Polizia Locale',                        'Via Garibaldi 88',         'Valmontana', 'SEDE_DECENTRATA',    TRUE),
    ('ANAG2',  'Anagrafe decentrata - Quartiere Nord',          'Via Piave 15',             'Valmontana', 'SEDE_DECENTRATA',    FALSE),
    ('CLOUD',  'Cloud qualificato ACN (Region IT-North)',       'n/a - servizio cloud',     'Milano',     'CLOUD_ESTERNO',      TRUE);

-- --- 7.3 Vendor -------------------------------------------------------
INSERT INTO vendor (nome, sito_psirt, paese_sede) VALUES
    ('Juniper Networks', 'https://supportportal.juniper.net/s/knowledge',              'US'),
    ('Fortinet',         'https://www.fortiguard.com/psirt',                             'US'),
    ('Check Point',      'https://www.checkpoint.com/advisories/',                       'IL'),
    ('Cisco Systems',    'https://sec.cloudapps.cisco.com/security/center/publicationListing.x', 'US'),
    ('Dell Technologies','https://www.dell.com/support/security',                        'US'),
    ('HPE',              'https://support.hpe.com/connect/s/securitybulletinlibrary',    'US'),
    ('NetApp',           'https://security.netapp.com/advisory/',                        'US'),
    ('VMware (Broadcom)','https://www.broadcom.com/support/vmware-security-advisories',  'US'),
    ('Microsoft',        'https://msrc.microsoft.com/update-guide',                      'US'),
    ('Veeam',            'https://www.veeam.com/knowledge-base.html',                    'US'),
    ('APC (Schneider)',  'https://www.se.com/ww/en/work/support/cybersecurity/',        'FR'),
    ('Palo Alto Networks','https://security.paloaltonetworks.com/',                     'US');

-- --- 7.4 Categorie asset ----------------------------------------------
INSERT INTO categoria_asset (codice, descrizione, livello_iso) VALUES
    ('SWITCH_CORE',   'Switch di core / spine data center',       'RETE'),
    ('SWITCH_ACCESS', 'Switch di accesso / distribuzione',        'RETE'),
    ('ROUTER',        'Router WAN / edge',                        'RETE'),
    ('FIREWALL',      'Firewall / NGFW / UTM',                    'SICUREZZA'),
    ('WAF',           'Web Application Firewall',                 'SICUREZZA'),
    ('SIEM',          'SIEM / log collector',                     'SICUREZZA'),
    ('SERVER_FISICO', 'Server fisico (hypervisor / bare metal)',  'ELABORAZIONE'),
    ('VM',            'Macchina virtuale',                        'VIRTUALE'),
    ('STORAGE',       'Storage SAN / NAS',                        'STORAGE'),
    ('BACKUP',        'Appliance / repository di backup',         'STORAGE'),
    ('UPS',           'Gruppo di continuità',                     'ELABORAZIONE'),
    ('WIFI_CTRL',     'Controller / access point wireless',       'RETE');

-- --- 7.5 Tipologie fornitore ------------------------------------------
INSERT INTO tipo_fornitore (codice, descrizione) VALUES
    ('ISP',        'Operatore di telecomunicazioni / connettività'),
    ('CLOUD',      'Cloud Service Provider'),
    ('SW_HOUSE',   'Software house / vendor applicativo PA'),
    ('SYS_INT',    'System integrator / manutenzione HW-SW'),
    ('PA_CENTRALE','Piattaforma abilitante di PA centrale'),
    ('MSSP',       'Managed Security Service Provider / SOC');

-- --- 7.6 Responsabili / punti di contatto -----------------------------
INSERT INTO responsabile (nome, cognome, ruolo, email, telefono, telefono_reperibilita, id_unita, punto_contatto_acn, attivo) VALUES
    ('Laura',     'Bianchi',   'Dirigente SIC - Responsabile Transizione Digitale (RTD)', 'laura.bianchi@comune.valmontana.it',     '0341 100201', '335 1000201', 2,  TRUE,  TRUE),
    ('Marco',     'Ferrari',   'CISO - Responsabile Sicurezza Informatica',               'marco.ferrari@comune.valmontana.it',     '0341 100210', '335 1000210', 9,  TRUE,  TRUE),
    ('Giulia',    'Rossi',     'Responsabile Reti e Data Center',                        'giulia.rossi@comune.valmontana.it',      '0341 100220', '335 1000220', 10, FALSE, TRUE),
    ('Andrea',    'Colombo',   'Network Engineer Senior',                                'andrea.colombo@comune.valmontana.it',    '0341 100221', '335 1000221', 10, FALSE, TRUE),
    ('Francesca', 'Galli',     'System Administrator - Virtualizzazione',                'francesca.galli@comune.valmontana.it',   '0341 100222', '335 1000222', 10, FALSE, TRUE),
    ('Roberto',   'Moretti',   'Database Administrator',                                 'roberto.moretti@comune.valmontana.it',   '0341 100223', '335 1000223', 10, FALSE, TRUE),
    ('Elena',     'Conti',     'Responsabile Ufficio Anagrafe - Owner servizio ANPR',    'elena.conti@comune.valmontana.it',       '0341 100301', NULL,          7,  FALSE, TRUE),
    ('Paolo',     'Ricci',     'Responsabile Protocollo e Archivio',                     'paolo.ricci@comune.valmontana.it',       '0341 100302', NULL,          8,  FALSE, TRUE),
    ('Silvia',    'Marino',    'Dirigente Settore Finanziario - Owner Tributi/PagoPA',   'silvia.marino@comune.valmontana.it',     '0341 100401', NULL,          4,  FALSE, TRUE),
    ('Davide',    'Greco',     'Comandante Polizia Locale',                              'davide.greco@comune.valmontana.it',      '0341 100501', '335 1000501', 5,  FALSE, TRUE),
    ('Chiara',    'Bruno',     'Responsabile SUAP',                                      'chiara.bruno@comune.valmontana.it',      '0341 100601', NULL,          6,  FALSE, TRUE),
    ('Luca',      'Romano',    'Data Protection Officer (DPO)',                          'dpo@comune.valmontana.it',               '0341 100105', NULL,          1,  FALSE, TRUE),
    ('Stefano',   'Costa',     'Ex Network Engineer (cessato)',                          'stefano.costa@comune.valmontana.it',     NULL,          NULL,          10, FALSE, FALSE);

-- --- 7.7 Fornitori ----------------------------------------------------
INSERT INTO fornitore (ragione_sociale, partita_iva, id_tipo_fornitore, paese, referente_nome, referente_email, telefono_noc,
                       numero_contratto, data_inizio_contratto, data_fine_contratto, sla_ripristino_ore, certificazione_iso27001, qualificato_acn) VALUES
-- NOTA: ragioni sociali, partite IVA, contratti e SLA sono interamente FITTIZI (dataset simulato).
    ('Operatore TLC Alfa S.p.A. (Convenzione SPC Connettivita)', '00000000101', 1, 'IT', 'Account PA Nord',      'account.pa@alfa-tlc.example',    '800 000101', 'SPC2-LOM-2023-0415', '2023-01-01', '2027-12-31', 4,   TRUE,  FALSE),
    ('Operatore TLC Beta S.p.A.',                               '00000000102', 1, 'IT', 'NOC Business',          'noc@beta-tlc.example',           '800 000102', 'BT-PA-2024-0972',    '2024-03-01', '2027-02-28', 8,   TRUE,  FALSE),
    ('Cloud Provider Gamma S.p.A. (IaaS/PaaS qualificato ACN)', '00000000103', 2, 'IT', 'Supporto Cloud PA',     'cloudpa@gamma-cloud.example',    '0575 000103','GAM-CPA-2024-1187',  '2024-06-01', '2027-05-31', 2,   TRUE,  TRUE),
    ('Cloud Provider Delta Ltd (suite collaborativa SaaS)',     'IE00000104',  2, 'IE', 'Premier Support',       'premier@delta-cloud.example',    '02 00000104','DEL-EA-PA-2025-331', '2025-01-01', '2027-12-31', 1,   TRUE,  TRUE),
    ('Software House Epsilon S.p.A. (demografici e documentale)','00000000105', 3, 'IT', 'Help Desk Applicativo', 'assistenza@epsilon-sw.example',  '0541 000105','EPS-SW-2022-2201',   '2022-07-01', '2026-06-30', 8,   TRUE,  FALSE),
    ('Software House Zeta S.r.l. (applicativi tributari)',      '00000000106', 3, 'IT', 'Assistenza Tributi',    'assistenza@zeta-sw.example',     '0733 000106','ZET-TRB-2023-118',   '2023-01-01', '2026-12-31', 8,   FALSE, FALSE),
    ('PagoPA S.p.A.',                                           '15376371009', 5, 'IT', 'Help Desk Enti',        'helpdesk@pagopa.it',             '06 4520 2323','ADESIONE-PAGOPA-2020','2020-09-01', NULL,        4,   TRUE,  FALSE),
    ('Ministero dell''Interno - Piattaforma ANPR',              '80014130928', 5, 'IT', 'Assistenza ANPR',       'assistenza.anpr@interno.it',     '06 4795 0000','ANPR-SUB-2019-VM',   '2019-11-01', NULL,        24,  TRUE,  FALSE),
    ('AgID - Identita digitale SPID / CIE',                     '97735020584', 5, 'IT', 'Supporto SPID Enti',    'spid.tech@agid.gov.it',          '06 8526 4000','SPID-CONV-2018',     '2018-05-01', NULL,        24,  TRUE,  FALSE),
    ('System Integrator Theta S.r.l. (rete e sicurezza)',       '00000000110', 4, 'IT', 'Service Desk',          'servicedesk@theta-si.example',   '02 00000110','THE-MNT-2024-077',   '2024-01-01', '2026-12-31', 4,   TRUE,  FALSE),
    ('System Integrator Iota S.p.A. (server e storage)',        '00000000111', 4, 'IT', 'NOC Iota',              'noc@iota-si.example',            '02 00000111','IOT-MNT-2023-512',   '2023-04-01', '2026-03-31', 4,   TRUE,  FALSE),
    ('MSSP Kappa S.p.A. - Security Operations Center',          '00000000112', 6, 'IT', 'SOC H24',               'soc.pa@kappa-mssp.example',      '06 00000112','KAP-SOC-2025-088',   '2025-02-01', '2028-01-31', 1,   TRUE,  TRUE);

-- --- 7.8 ASSET (l'INSERT attiva il trigger di audit) ------------------
-- Piano di indirizzamento management: 10.10.0.0/24 (OOB)
INSERT INTO asset (codice_inventario, hostname, ip_gestione, id_categoria, id_vendor, modello, numero_seriale, versione_firmware, sistema_operativo,
                   id_sede, rack_posizione, ambiente, criticita, stato, id_responsabile, id_responsabile_backup,
                   data_installazione, data_fine_supporto, ultimo_patch, cifratura_dati, mfa_amministrativo, note) VALUES
-- ---- Rete: core / spine (Juniper QFX)
('CVM-NET-0001', 'dc1-core-sw01', '10.10.0.11', 1, 1, 'Juniper QFX5120-48Y', 'WS3720450112', 'Junos 22.4R3-S4', 'Junos OS', 1, 'R01-U40', 'PRODUZIONE', 'CRITICA', 'IN_PRODUZIONE', 3, 4, '2022-11-15', '2029-11-30', '2026-07-20', FALSE, TRUE,  'Core DC1 - Virtual Chassis con dc1-core-sw02, EVPN-VXLAN'),
('CVM-NET-0002', 'dc1-core-sw02', '10.10.0.12', 1, 1, 'Juniper QFX5120-48Y', 'WS3720450118', 'Junos 22.4R3-S4', 'Junos OS', 1, 'R02-U40', 'PRODUZIONE', 'CRITICA', 'IN_PRODUZIONE', 3, 4, '2022-11-15', '2029-11-30', '2026-07-20', FALSE, TRUE,  'Core DC1 - membro VC secondario'),
('CVM-NET-0003', 'dc2-core-sw01', '10.10.0.21', 1, 1, 'Juniper QFX5110-48S', 'WY3618221090', 'Junos 21.4R3-S7', 'Junos OS', 2, 'R01-U40', 'DISASTER_RECOVERY', 'ALTA', 'IN_PRODUZIONE', 3, 4, '2021-03-10', '2027-06-30', '2026-05-05', FALSE, TRUE, 'Core DC2 (DR) - EoS ravvicinato, pianificare refresh'),
-- ---- Rete: accesso (Juniper EX / Cisco Catalyst)
('CVM-NET-0010', 'pal-acc-sw01', '10.10.0.31', 2, 1, 'Juniper EX4300-48P',  'PE3719330551', 'Junos 21.4R3-S6', 'Junos OS', 3, 'ARM-P1-U10', 'PRODUZIONE', 'MEDIA', 'IN_PRODUZIONE', 4, 3, '2020-06-01', '2026-12-31', '2026-03-18', FALSE, TRUE, 'Accesso piano 1 Palazzo Comunale, PoE per telefonia VoIP'),
('CVM-NET-0011', 'pal-acc-sw02', '10.10.0.32', 2, 1, 'Juniper EX4300-48P',  'PE3719330562', 'Junos 21.4R3-S6', 'Junos OS', 3, 'ARM-P2-U10', 'PRODUZIONE', 'MEDIA', 'IN_PRODUZIONE', 4, 3, '2020-06-01', '2026-12-31', '2026-03-18', FALSE, TRUE, 'Accesso piano 2 - Uffici Anagrafe'),
('CVM-NET-0012', 'ploc-acc-sw01','10.10.0.41', 2, 4, 'Cisco Catalyst 9300-48P', 'FOC2542L1B7', 'IOS-XE 17.9.5', 'IOS-XE', 4, 'ARM-PL-U05', 'PRODUZIONE', 'ALTA', 'IN_PRODUZIONE', 4, 3, '2021-09-20', '2030-10-31', '2026-06-11', FALSE, TRUE, 'Comando Polizia Locale - VLAN videosorveglianza segregata'),
('CVM-NET-0013', 'anag2-acc-sw01','10.10.0.51', 2, 4, 'Cisco Catalyst 2960X-24PS', 'FCW2015A0KR', 'IOS 15.2(7)E9', 'IOS', 5, 'ARM-U01', 'PRODUZIONE', 'BASSA', 'IN_PRODUZIONE', 4, NULL, '2016-04-12', '2024-10-31', '2023-11-02', FALSE, FALSE, 'ATTENZIONE: apparato END-OF-SUPPORT, in attesa di sostituzione'),
-- ---- Rete: router WAN (Cisco)
('CVM-NET-0020', 'dc1-wan-rt01', '10.10.0.61', 3, 4, 'Cisco ISR 4331',      'FDO2318A0X2', 'IOS-XE 17.6.6a', 'IOS-XE', 1, 'R01-U38', 'PRODUZIONE', 'CRITICA', 'IN_PRODUZIONE', 4, 3, '2019-12-05', '2028-12-31', '2026-04-22', FALSE, TRUE, 'Router SPC verso operatore primario (link 1 Gbps MPLS)'),
('CVM-NET-0021', 'dc1-wan-rt02', '10.10.0.62', 3, 4, 'Cisco ISR 4331',      'FDO2318A0X9', 'IOS-XE 17.6.6a', 'IOS-XE', 1, 'R02-U38', 'PRODUZIONE', 'ALTA',    'IN_PRODUZIONE', 4, 3, '2019-12-05', '2028-12-31', '2026-04-22', FALSE, TRUE, 'Router backup verso operatore secondario (FTTH 1 Gbps) - HSRP'),
-- ---- Sicurezza perimetrale (Fortinet) e interna (Check Point)
('CVM-SEC-0001', 'dc1-fw-edge01', '10.10.0.71', 4, 2, 'FortiGate 200F',     'FG200FTK21000118', 'FortiOS 7.4.5', 'FortiOS', 1, 'R01-U36', 'PRODUZIONE', 'CRITICA', 'IN_PRODUZIONE', 2, 4, '2021-07-14', '2028-07-31', '2026-08-02', FALSE, TRUE, 'NGFW perimetrale cluster HA A/P (primario) - IPS, SSL-VPN dipendenti, DMZ portali'),
('CVM-SEC-0002', 'dc1-fw-edge02', '10.10.0.72', 4, 2, 'FortiGate 200F',     'FG200FTK21000124', 'FortiOS 7.4.5', 'FortiOS', 1, 'R02-U36', 'PRODUZIONE', 'CRITICA', 'IN_PRODUZIONE', 2, 4, '2021-07-14', '2028-07-31', '2026-08-02', FALSE, TRUE, 'NGFW perimetrale cluster HA A/P (secondario)'),
('CVM-SEC-0003', 'dc1-fw-int01',  '10.10.0.75', 4, 3, 'Check Point 6200 Plus', 'CP6200-2310-00871', 'Gaia R81.20 JHF T76', 'Gaia', 1, 'R03-U30', 'PRODUZIONE', 'CRITICA', 'IN_PRODUZIONE', 2, 3, '2023-02-01', '2029-12-31', '2026-07-30', FALSE, TRUE, 'Firewall interno di segmentazione (zona server / zona client / zona PL)'),
('CVM-SEC-0004', 'dc2-fw-edge01', '10.10.0.81', 4, 2, 'FortiGate 100F',     'FG100FTK20000452', 'FortiOS 7.4.5', 'FortiOS', 2, 'R01-U36', 'DISASTER_RECOVERY', 'ALTA', 'IN_PRODUZIONE', 2, 4, '2021-07-14', '2028-07-31', '2026-08-02', FALSE, TRUE, 'Perimetro sito DR'),
('CVM-SEC-0005', 'dc1-waf01',     '10.10.0.76', 5, 2, 'FortiWeb 400E',      'FV400ETK21000033', 'FortiWeb 7.4.3', 'FortiWeb', 1, 'R03-U28', 'PRODUZIONE', 'ALTA', 'IN_PRODUZIONE', 2, 4, '2022-05-10', '2028-05-31', '2026-06-25', FALSE, TRUE, 'WAF davanti a portale istituzionale e servizi online'),
('CVM-SEC-0006', 'dc1-siem01',    '10.10.0.77', 6, 2, 'FortiAnalyzer 300G', 'FAZ300GTK22000009', 'FortiAnalyzer 7.4.4', 'FortiAnalyzer', 1, 'R03-U26', 'PRODUZIONE', 'ALTA', 'IN_PRODUZIONE', 2, 3, '2022-05-10', '2028-05-31', '2026-06-25', TRUE, TRUE, 'Log collector - inoltro al SOC esterno (MSSP) via syslog-TLS'),
-- ---- Elaborazione: hypervisor (Dell) + storage (NetApp) + backup
('CVM-SRV-0001', 'dc1-esx01', '10.10.0.101', 7, 5, 'Dell PowerEdge R750', 'CN0H7X3', 'iDRAC 7.10.30.00', 'VMware ESXi 8.0 U3', 1, 'R04-U20', 'PRODUZIONE', 'CRITICA', 'IN_PRODUZIONE', 5, 3, '2022-09-01', '2027-09-30', '2026-07-15', TRUE, TRUE, 'Cluster vSphere PROD nodo 1/3'),
('CVM-SRV-0002', 'dc1-esx02', '10.10.0.102', 7, 5, 'Dell PowerEdge R750', 'CN0H7X4', 'iDRAC 7.10.30.00', 'VMware ESXi 8.0 U3', 1, 'R04-U18', 'PRODUZIONE', 'CRITICA', 'IN_PRODUZIONE', 5, 3, '2022-09-01', '2027-09-30', '2026-07-15', TRUE, TRUE, 'Cluster vSphere PROD nodo 2/3'),
('CVM-SRV-0003', 'dc1-esx03', '10.10.0.103', 7, 5, 'Dell PowerEdge R750', 'CN0H7X5', 'iDRAC 7.10.30.00', 'VMware ESXi 8.0 U3', 1, 'R04-U16', 'PRODUZIONE', 'CRITICA', 'IN_PRODUZIONE', 5, 3, '2022-09-01', '2027-09-30', '2026-07-15', TRUE, TRUE, 'Cluster vSphere PROD nodo 3/3'),
('CVM-SRV-0004', 'dc2-esx01', '10.10.0.111', 7, 6, 'HPE ProLiant DL380 Gen10', 'CZ29450KLM', 'iLO 5 3.06', 'VMware ESXi 8.0 U3', 2, 'R02-U20', 'DISASTER_RECOVERY', 'ALTA', 'IN_PRODUZIONE', 5, 3, '2020-02-20', '2026-12-31', '2026-07-15', TRUE, TRUE, 'Cluster DR nodo 1/2 - replica vSphere Replication'),
('CVM-STO-0001', 'dc1-san01',  '10.10.0.121', 9, 7, 'NetApp AFF A250',    '721947000123', 'ONTAP 9.14.1P6', 'ONTAP', 1, 'R05-U10', 'PRODUZIONE', 'CRITICA', 'IN_PRODUZIONE', 5, 6, '2022-09-01', '2028-09-30', '2026-06-30', TRUE, TRUE, 'Storage primario iSCSI/NFS - SnapMirror verso DC2'),
('CVM-STO-0002', 'dc2-san01',  '10.10.0.131', 9, 7, 'NetApp FAS2720',     '721834000456', 'ONTAP 9.13.1P10','ONTAP', 2, 'R02-U10', 'DISASTER_RECOVERY', 'ALTA', 'IN_PRODUZIONE', 5, 6, '2020-02-20', '2027-02-28', '2026-06-30', TRUE, TRUE, 'Storage DR - destinazione SnapMirror'),
('CVM-BKP-0001', 'dc1-bkp01',  '10.10.0.141', 10, 5, 'Dell PowerEdge R740xd', 'CN0B4K9', 'iDRAC 7.00.00.00', 'Windows Server 2022 / Veeam B&R 12.2', 1, 'R05-U04', 'PRODUZIONE', 'CRITICA', 'IN_PRODUZIONE', 5, 6, '2021-11-30', '2026-11-30', '2026-08-10', TRUE, TRUE, 'Repository backup immutabile (hardened Linux repo separato) - regola 3-2-1'),
('CVM-UPS-0001', 'dc1-ups01',  '10.10.0.151', 11, 11, 'APC Smart-UPS SRT 10kVA', 'AS2145130876', 'NMC3 2.5.0.2', 'Network Management Card', 1, 'R00-U01', 'PRODUZIONE', 'ALTA', 'IN_PRODUZIONE', 3, 4, '2021-05-05', '2029-05-31', '2025-12-01', FALSE, FALSE, 'Autonomia 25 min a pieno carico + gruppo elettrogeno'),
-- ---- Macchine virtuali applicative
('CVM-VM-0001', 'vm-dc01',        '10.20.1.10', 8, 9, 'VM vSphere (4 vCPU / 16 GB)', NULL, NULL, 'Windows Server 2022', 1, NULL, 'PRODUZIONE', 'CRITICA', 'IN_PRODUZIONE', 5, 2, '2022-10-01', NULL, '2026-08-13', TRUE, TRUE, 'Active Directory DC primario - dominio comune.valmontana.local'),
('CVM-VM-0002', 'vm-dc02',        '10.20.1.11', 8, 9, 'VM vSphere (4 vCPU / 16 GB)', NULL, NULL, 'Windows Server 2022', 2, NULL, 'DISASTER_RECOVERY', 'CRITICA', 'IN_PRODUZIONE', 5, 2, '2022-10-01', NULL, '2026-08-13', TRUE, TRUE, 'Active Directory DC secondario (DC2)'),
('CVM-VM-0010', 'vm-anagrafe-app', '10.20.2.10', 8, 9, 'VM vSphere (8 vCPU / 32 GB)', NULL, NULL, 'Windows Server 2022 / IIS', 1, NULL, 'PRODUZIONE', 'CRITICA', 'IN_PRODUZIONE', 5, 6, '2023-01-15', NULL, '2026-08-13', TRUE, TRUE, 'Application server Anagrafe (applicativo di terze parti) - integrazione ANPR/SPID'),
('CVM-VM-0011', 'vm-anagrafe-db',  '10.20.3.10', 8, 9, 'VM vSphere (8 vCPU / 64 GB)', NULL, NULL, 'Windows Server 2022 / SQL Server 2022', 1, NULL, 'PRODUZIONE', 'CRITICA', 'IN_PRODUZIONE', 6, 5, '2023-01-15', NULL, '2026-08-13', TRUE, TRUE, 'DB Anagrafe / Stato Civile - TDE attivo'),
('CVM-VM-0020', 'vm-protocollo-app','10.20.2.20', 8, 8, 'VM vSphere (4 vCPU / 16 GB)', NULL, NULL, 'Ubuntu Server 22.04 LTS / Tomcat', 1, NULL, 'PRODUZIONE', 'ALTA', 'IN_PRODUZIONE', 5, 6, '2022-07-01', NULL, '2026-08-20', TRUE, TRUE, 'Protocollo informatico e gestione documentale'),
('CVM-VM-0021', 'vm-protocollo-db', '10.20.3.20', 8, 8, 'VM vSphere (4 vCPU / 32 GB)', NULL, NULL, 'Ubuntu Server 22.04 LTS / PostgreSQL 15', 1, NULL, 'PRODUZIONE', 'ALTA', 'IN_PRODUZIONE', 6, 5, '2022-07-01', NULL, '2026-08-20', TRUE, TRUE, 'DB Protocollo - conservazione a norma presso cloud provider qualificato'),
('CVM-VM-0030', 'vm-tributi-app',   '10.20.2.30', 8, 9, 'VM vSphere (4 vCPU / 16 GB)', NULL, NULL, 'Windows Server 2019', 1, NULL, 'PRODUZIONE', 'ALTA', 'IN_PRODUZIONE', 5, 6, '2021-04-01', NULL, '2026-08-13', TRUE, TRUE, 'Tributi (IMU/TARI) - applicativo di terze parti - connettore pagoPA'),
('CVM-VM-0040', 'vm-suap-app',      '10.20.2.40', 8, 8, 'VM vSphere (2 vCPU / 8 GB)',  NULL, NULL, 'Ubuntu Server 22.04 LTS', 1, NULL, 'PRODUZIONE', 'MEDIA', 'IN_PRODUZIONE', 5, 6, '2022-03-01', NULL, '2026-08-20', TRUE, TRUE, 'Portale SUAP - pratiche imprese'),
('CVM-VM-0050', 'vm-web-portale',   '10.20.4.10', 8, 8, 'VM vSphere (4 vCPU / 8 GB)',  NULL, NULL, 'Ubuntu Server 22.04 LTS / Nginx', 1, NULL, 'PRODUZIONE', 'ALTA', 'IN_PRODUZIONE', 5, 4, '2022-03-01', NULL, '2026-08-20', TRUE, TRUE, 'Portale istituzionale www.comune.valmontana.it (DMZ)'),
('CVM-VM-0060', 'vm-videosorv-vms', '10.20.5.10', 8, 9, 'VM vSphere (8 vCPU / 32 GB)', NULL, NULL, 'Windows Server 2022 / Video Management System', 1, NULL, 'PRODUZIONE', 'ALTA', 'IN_PRODUZIONE', 5, 10, '2021-10-01', NULL, '2026-07-01', TRUE, FALSE, 'Video Management System Polizia Locale - 120 telecamere'),
('CVM-VM-0070', 'vm-test-anagrafe', '10.30.2.10', 8, 9, 'VM vSphere (4 vCPU / 16 GB)', NULL, NULL, 'Windows Server 2022', 1, NULL, 'TEST', 'BASSA', 'IN_TEST', 5, NULL, '2024-01-10', NULL, '2026-02-01', FALSE, TRUE, 'Ambiente di collaudo aggiornamenti Anagrafe - dati anonimizzati'),
('CVM-NET-0099', 'old-core-sw01',   NULL,         1, 4, 'Cisco Catalyst 6509-E', 'SMC1234ABCD', 'IOS 12.2(33)SXJ', 'IOS', 1, 'MAGAZZINO', 'PRODUZIONE', 'BASSA', 'DISMESSO', 3, NULL, '2012-06-01', '2020-06-30', '2019-01-15', FALSE, FALSE, 'Dismesso nel 2022, in attesa di smaltimento RAEE con wiping configurazioni');

-- --- 7.9 Servizi erogati ----------------------------------------------
INSERT INTO servizio (codice, nome, descrizione, esposizione, url_pubblico, criticita, servizio_essenziale, tratta_dati_personali, rto_ore, rpo_ore, id_responsabile, id_unita_erogante, attivo) VALUES
    ('SRV-ANAGRAFE', 'Portale Anagrafe e Stato Civile (ANPR)',   'Certificati, cambi residenza, carte d''identità; allineato ad ANPR nazionale', 'INTERNET', 'https://servizi.comune.valmontana.it/anagrafe', 'CRITICA', TRUE,  TRUE,  4,   1,   7,  7, TRUE),
    ('SRV-PROTOCOLLO','Protocollo informatico e gestione documentale', 'Protocollazione PEC/istanze, fascicolazione, conservazione a norma',  'INTRANET', NULL,                                              'ALTA',    TRUE,  TRUE,  8,   4,   8,  8, TRUE),
    ('SRV-TRIBUTI',  'Tributi locali e pagamenti PagoPA',        'IMU, TARI, canone unico; avvisi e pagamenti tramite piattaforma pagoPA',   'INTERNET', 'https://servizi.comune.valmontana.it/tributi',  'ALTA',    TRUE,  TRUE,  8,   4,   9,  4, TRUE),
    ('SRV-SUAP',     'Sportello Unico Attività Produttive',      'Pratiche SCIA e autorizzazioni imprese (impresainungiorno)',              'INTERNET', 'https://suap.comune.valmontana.it',             'MEDIA',   FALSE, TRUE,  24,  24,  11, 6, TRUE),
    ('SRV-PORTALE',  'Portale istituzionale e Albo Pretorio',    'Sito web, trasparenza amministrativa, albo pretorio on-line',              'INTERNET', 'https://www.comune.valmontana.it',              'ALTA',    FALSE, FALSE, 8,   24,  1,  2, TRUE),
    ('SRV-VIDEOSORV','Videosorveglianza urbana',                 'Rete telecamere, lettura targhe (ZTL), centrale operativa PL',              'INTRANET', NULL,                                              'ALTA',    TRUE,  TRUE,  4,   4,   10, 5, TRUE),
    ('SRV-IDENTITY', 'Identità e accesso (AD / SPID / CIE)',     'Directory dipendenti, SSO applicativo, federazione SPID/CIE per cittadini', 'EXTRANET_PA', NULL,                                           'CRITICA', TRUE,  TRUE,  2,   1,   2,  9, TRUE),
    ('SRV-POSTA',    'Posta elettronica e collaborazione cloud','E-mail, chat, condivisione documenti per 450 dipendenti; PEC istituzionale',          'INTERNET', 'https://webmail.comune.valmontana.it',                 'MEDIA',   FALSE, TRUE,  8,   1,   1,  2, TRUE),
    ('SRV-BACKUP',   'Backup e Disaster Recovery',               'Salvataggio giornaliero di tutti i sistemi, replica su DC2, test restore trimestrale', 'INTRANET', NULL,                                'CRITICA', TRUE,  TRUE,  12,  24,  5,  10, TRUE);

-- --- 7.10 Relazione asset -> servizio ---------------------------------
-- (id_asset segue l'ordine di inserimento sopra: 1..34)
INSERT INTO asset_servizio (id_asset, id_servizio, ruolo, single_point_of_failure, note) VALUES
    -- SRV-ANAGRAFE (1)
    (26, 1, 'HOSTING',        FALSE, 'Application server'),
    (27, 1, 'HOSTING',        TRUE,  'DB SQL Server - istanza singola, HA solo via vSphere HA'),
    (24, 1, 'AUTENTICAZIONE', FALSE, 'AD per operatori di sportello'),
    (10, 1, 'PROTEZIONE',     FALSE, 'Perimetro DMZ'),
    (14, 1, 'PROTEZIONE',     TRUE,  'WAF singolo'),
    (1,  1, 'CONNETTIVITA',   FALSE, NULL),
    (8,  1, 'CONNETTIVITA',   FALSE, 'Link SPC verso ANPR'),
    (20, 1, 'STORAGE',        FALSE, NULL),
    -- SRV-PROTOCOLLO (2)
    (28, 2, 'HOSTING',        FALSE, NULL),
    (29, 2, 'HOSTING',        TRUE,  'PostgreSQL singolo nodo'),
    (24, 2, 'AUTENTICAZIONE', FALSE, NULL),
    (12, 2, 'PROTEZIONE',     FALSE, 'Segmentazione interna'),
    (1,  2, 'CONNETTIVITA',   FALSE, NULL),
    (20, 2, 'STORAGE',        FALSE, NULL),
    -- SRV-TRIBUTI (3)
    (30, 3, 'HOSTING',        TRUE,  'App+DB sullo stesso server - da separare'),
    (10, 3, 'PROTEZIONE',     FALSE, NULL),
    (14, 3, 'PROTEZIONE',     TRUE,  NULL),
    (8,  3, 'CONNETTIVITA',   FALSE, 'Verso nodo pagoPA'),
    (20, 3, 'STORAGE',        FALSE, NULL),
    -- SRV-SUAP (4)
    (31, 4, 'HOSTING',        TRUE,  NULL),
    (10, 4, 'PROTEZIONE',     FALSE, NULL),
    (14, 4, 'PROTEZIONE',     TRUE,  NULL),
    -- SRV-PORTALE (5)
    (32, 5, 'HOSTING',        TRUE,  NULL),
    (10, 5, 'PROTEZIONE',     FALSE, NULL),
    (14, 5, 'PROTEZIONE',     TRUE,  NULL),
    (8,  5, 'CONNETTIVITA',   FALSE, NULL),
    (9,  5, 'CONNETTIVITA',   FALSE, 'Link backup'),
    -- SRV-VIDEOSORV (6)
    (33, 6, 'HOSTING',        TRUE,  'VMS singolo'),
    (6,  6, 'CONNETTIVITA',   TRUE,  'Switch Comando PL - unico uplink'),
    (12, 6, 'PROTEZIONE',     FALSE, 'Zona PL segregata'),
    (20, 6, 'STORAGE',        FALSE, 'Retention 7 giorni'),
    -- SRV-IDENTITY (7)
    (24, 7, 'HOSTING',        FALSE, 'DC primario'),
    (25, 7, 'HOSTING',        FALSE, 'DC secondario in DR'),
    (10, 7, 'PROTEZIONE',     FALSE, NULL),
    (1,  7, 'CONNETTIVITA',   FALSE, NULL),
    (2,  7, 'CONNETTIVITA',   FALSE, NULL),
    -- SRV-POSTA (8)
    (10, 8, 'PROTEZIONE',     FALSE, 'Solo uscita verso cloud'),
    (24, 8, 'AUTENTICAZIONE', FALSE, 'Sincronizzazione directory verso cloud'),
    -- SRV-BACKUP (9)
    (22, 9, 'HOSTING',        TRUE,  'Server Veeam'),
    (20, 9, 'STORAGE',        FALSE, NULL),
    (21, 9, 'STORAGE',        FALSE, 'Copia DR'),
    (3,  9, 'CONNETTIVITA',   FALSE, NULL),
    -- Infrastruttura trasversale: ESXi / UPS / SIEM su tutti i servizi hostati
    (16, 1, 'HOSTING', FALSE, 'Cluster vSphere'), (17, 1, 'HOSTING', FALSE, NULL), (18, 1, 'HOSTING', FALSE, NULL),
    (16, 2, 'HOSTING', FALSE, NULL), (17, 2, 'HOSTING', FALSE, NULL), (18, 2, 'HOSTING', FALSE, NULL),
    (16, 3, 'HOSTING', FALSE, NULL), (17, 3, 'HOSTING', FALSE, NULL), (18, 3, 'HOSTING', FALSE, NULL),
    (16, 7, 'HOSTING', FALSE, NULL), (17, 7, 'HOSTING', FALSE, NULL), (19, 7, 'HOSTING', FALSE, 'Nodo DR'),
    (23, 1, 'HOSTING', FALSE, 'Alimentazione protetta'), (23, 7, 'HOSTING', FALSE, NULL),
    (15, 1, 'MONITORAGGIO', FALSE, NULL), (15, 3, 'MONITORAGGIO', FALSE, NULL), (15, 7, 'MONITORAGGIO', FALSE, NULL);

-- --- 7.11 Dipendenze servizio -> fornitore -----------------------------
INSERT INTO servizio_fornitore (id_servizio, id_fornitore, tipo_dipendenza, criticita_dipendenza, esiste_alternativa, note) VALUES
    (1, 1,  'CONNETTIVITA',        'CRITICA', TRUE,  'Link SPC primario'),
    (1, 2,  'CONNETTIVITA',        'ALTA',    TRUE,  'Link backup'),
    (1, 8,  'INTEROPERABILITA_PA', 'CRITICA', FALSE, 'Anagrafe nazionale ANPR - nessuna alternativa'),
    (1, 9,  'INTEROPERABILITA_PA', 'CRITICA', FALSE, 'Autenticazione cittadini SPID/CIE'),
    (1, 5,  'MANUTENZIONE_SW',     'ALTA',    FALSE, 'Applicativo proprietario'),
    (2, 5,  'MANUTENZIONE_SW',     'ALTA',    FALSE, NULL),
    (2, 3,  'CLOUD_HOSTING',       'ALTA',    TRUE,  'Conservazione sostitutiva a norma + PEC'),
    (3, 6,  'MANUTENZIONE_SW',     'ALTA',    FALSE, NULL),
    (3, 7,  'INTEROPERABILITA_PA', 'CRITICA', FALSE, 'Nodo dei pagamenti pagoPA'),
    (3, 1,  'CONNETTIVITA',        'ALTA',    TRUE,  NULL),
    (4, 1,  'CONNETTIVITA',        'MEDIA',   TRUE,  NULL),
    (4, 9,  'INTEROPERABILITA_PA', 'ALTA',    FALSE, 'Accesso imprese via SPID/CNS'),
    (5, 1,  'CONNETTIVITA',        'ALTA',    TRUE,  NULL),
    (5, 2,  'CONNETTIVITA',        'MEDIA',   TRUE,  NULL),
    (6, 11, 'MANUTENZIONE_HW',     'ALTA',    TRUE,  'Manutenzione telecamere e switch PL'),
    (7, 9,  'INTEROPERABILITA_PA', 'CRITICA', FALSE, 'Federazione SPID'),
    (7, 4,  'SAAS',                'ALTA',    FALSE, 'Identity provider della suite cloud'),
    (8, 4,  'SAAS',                'ALTA',    FALSE, 'Suite di collaborazione cloud'),
    (8, 3,  'SAAS',                'MEDIA',   TRUE,  'PEC istituzionale'),
    (9, 3,  'CLOUD_HOSTING',       'ALTA',    TRUE,  'Copia backup off-site su object storage cloud qualificato'),
    (9, 11, 'MANUTENZIONE_HW',     'MEDIA',   TRUE,  NULL),
    (1, 12, 'SUPPORTO_SPECIALISTICO','ALTA',  TRUE,  'Monitoraggio SOC H24'),
    (7, 12, 'SUPPORTO_SPECIALISTICO','ALTA',  TRUE,  'Monitoraggio SOC H24');

-- --- 7.12 Contratti di supporto asset -> fornitore ---------------------
INSERT INTO asset_fornitore (id_asset, id_fornitore, tipo_dipendenza, livello_supporto, scadenza_supporto) VALUES
    (1,  10, 'MANUTENZIONE_HW', 'Manutenzione HW Next-Day + 24x7 TAC', '2026-12-31'),
    (2,  10, 'MANUTENZIONE_HW', 'Manutenzione HW Next-Day + 24x7 TAC', '2026-12-31'),
    (3,  10, 'MANUTENZIONE_HW', 'Manutenzione HW Next-Day',            '2026-12-31'),
    (4,  10, 'MANUTENZIONE_HW', 'NBD',                              '2026-12-31'),
    (5,  10, 'MANUTENZIONE_HW', 'NBD',                              '2026-12-31'),
    (6,  11, 'MANUTENZIONE_HW', 'Manutenzione HW 8x5xNBD',           '2026-03-31'),
    (8,  11, 'MANUTENZIONE_HW', 'Manutenzione HW 24x7x4',            '2026-03-31'),
    (9,  11, 'MANUTENZIONE_HW', 'Manutenzione HW 24x7x4',            '2026-03-31'),
    (10, 10, 'MANUTENZIONE_HW', 'Supporto Premium 24x7 + bundle sicurezza', '2026-12-31'),
    (11, 10, 'MANUTENZIONE_HW', 'Supporto Premium 24x7 + bundle sicurezza', '2026-12-31'),
    (12, 11, 'MANUTENZIONE_HW', 'Supporto Premium apparati sicurezza',      '2026-03-31'),
    (13, 10, 'MANUTENZIONE_HW', 'Supporto Premium 24x7',           '2026-12-31'),
    (14, 10, 'MANUTENZIONE_HW', 'Supporto Premium 24x7',           '2026-12-31'),
    (15, 10, 'MANUTENZIONE_HW', 'Supporto Premium 24x7',           '2026-12-31'),
    (16, 11, 'MANUTENZIONE_HW', 'Supporto HW Plus 4h',          '2027-09-30'),
    (17, 11, 'MANUTENZIONE_HW', 'Supporto HW Plus 4h',          '2027-09-30'),
    (18, 11, 'MANUTENZIONE_HW', 'Supporto HW Plus 4h',          '2027-09-30'),
    (20, 11, 'MANUTENZIONE_HW', 'Supporto storage Premium',       '2028-09-30'),
    (22, 11, 'MANUTENZIONE_HW', 'Supporto HW NBD',              '2026-11-30'),
    (26, 5,  'MANUTENZIONE_SW', 'Assistenza applicativa 8x5',       '2026-06-30'),
    (30, 6,  'MANUTENZIONE_SW', 'Assistenza applicativa 8x5',       '2026-12-31'),
    (15, 12, 'SUPPORTO_SPECIALISTICO', 'SOC H24 - gestione log',    '2028-01-31');

COMMIT;


-- =====================================================================
-- 8. VIEW FINALE PER EXPORT CSV (profilo ACN)
-- =====================================================================
-- Formato "piatto" (una riga per asset critico/alto in produzione), con
-- aggregazioni testuali separate da ';' per servizi, fornitori e contatti,
-- così da essere esportabile con un singolo COPY ... CSV.
-- Nessuna colonna contiene virgole non gestite: le liste usano '; '.

CREATE OR REPLACE VIEW v_export_acn_asset_critici AS
WITH servizi_per_asset AS (
    SELECT asv.id_asset,
           string_agg(DISTINCT s.codice || ' - ' || s.nome, '; ' ORDER BY s.codice || ' - ' || s.nome) AS servizi_supportati,
           bool_or(s.servizio_essenziale)                                       AS supporta_servizio_essenziale,
           bool_or(asv.single_point_of_failure)                                 AS e_single_point_of_failure,
           MIN(s.rto_ore)                                                       AS rto_minimo_ore
      FROM asset_servizio asv
      JOIN servizio s ON s.id_servizio = asv.id_servizio
     WHERE s.attivo
     GROUP BY asv.id_asset
),
fornitori_servizi AS (
    -- fornitori da cui dipendono i servizi sostenuti dall'asset
    SELECT asv.id_asset,
           string_agg(DISTINCT f.ragione_sociale || ' [' || sf.tipo_dipendenza::text || ']', '; ') AS fornitori_servizi
      FROM asset_servizio asv
      JOIN servizio_fornitore sf ON sf.id_servizio = asv.id_servizio
      JOIN fornitore f           ON f.id_fornitore = sf.id_fornitore
     GROUP BY asv.id_asset
),
fornitori_asset AS (
    -- fornitori di manutenzione diretta sull'apparato
    SELECT af.id_asset,
           string_agg(f.ragione_sociale || ' (' || COALESCE(af.livello_supporto, 'n/d') || ', scad. '
                      || COALESCE(to_char(af.scadenza_supporto, 'YYYY-MM-DD'), 'n/d') || ')', '; ' ORDER BY f.ragione_sociale) AS fornitori_manutenzione,
           MIN(af.scadenza_supporto) AS prima_scadenza_supporto
      FROM asset_fornitore af
      JOIN fornitore f ON f.id_fornitore = af.id_fornitore
     GROUP BY af.id_asset
)
SELECT
    a.codice_inventario                                   AS "ID_Asset",
    a.hostname                                            AS "Hostname",
    host(a.ip_gestione)                                   AS "IP_Gestione",
    ca.codice                                             AS "Categoria",
    ca.livello_iso                                        AS "Famiglia",
    v.nome                                                AS "Vendor",
    a.modello                                             AS "Modello",
    a.numero_seriale                                      AS "Seriale",
    COALESCE(a.versione_firmware, a.sistema_operativo)    AS "Firmware_SO",
    se.codice || ' - ' || se.denominazione                AS "Ubicazione",
    a.ambiente::text                                      AS "Ambiente",
    a.criticita::text                                     AS "Criticita_Asset",
    a.stato::text                                         AS "Stato",
    to_char(a.data_fine_supporto, 'YYYY-MM-DD')           AS "Fine_Supporto_Vendor",
    CASE WHEN a.data_fine_supporto < CURRENT_DATE THEN 'SI' ELSE 'NO' END AS "Obsoleto_EoS",
    to_char(a.ultimo_patch, 'YYYY-MM-DD')                 AS "Ultimo_Patch",
    CASE WHEN a.mfa_amministrativo THEN 'SI' ELSE 'NO' END AS "MFA_Admin",
    CASE WHEN a.cifratura_dati THEN 'SI' ELSE 'NO' END    AS "Cifratura",
    COALESCE(spa.servizi_supportati, '')                  AS "Servizi_Supportati",
    CASE WHEN COALESCE(spa.supporta_servizio_essenziale, FALSE) THEN 'SI' ELSE 'NO' END AS "Servizio_Essenziale",
    CASE WHEN COALESCE(spa.e_single_point_of_failure, FALSE) THEN 'SI' ELSE 'NO' END    AS "Single_Point_of_Failure",
    spa.rto_minimo_ore                                    AS "RTO_Minimo_Ore",
    COALESCE(fa.fornitori_manutenzione, '')               AS "Fornitori_Manutenzione",
    to_char(fa.prima_scadenza_supporto, 'YYYY-MM-DD')     AS "Prima_Scadenza_Supporto",
    COALESCE(fs.fornitori_servizi, '')                    AS "Dipendenze_Terze_Parti",
    r.cognome || ' ' || r.nome                            AS "Responsabile",
    r.ruolo                                               AS "Ruolo_Responsabile",
    r.email                                               AS "Email_Responsabile",
    COALESCE(r.telefono_reperibilita, r.telefono, '')     AS "Telefono_Responsabile",
    uo.denominazione                                      AS "Unita_Organizzativa",
    COALESCE(rb.cognome || ' ' || rb.nome || ' <' || rb.email || '>', '') AS "Contatto_Backup",
    (SELECT string_agg(x.cognome || ' ' || x.nome || ' <' || x.email || '>', '; ' ORDER BY x.cognome)
       FROM responsabile x WHERE x.punto_contatto_acn AND x.attivo) AS "Punto_Contatto_ACN",
    a.versione                                            AS "Versione_Record",
    to_char(a.modificato_il AT TIME ZONE 'Europe/Rome', 'YYYY-MM-DD HH24:MI:SS') AS "Ultima_Modifica"
FROM asset a
JOIN categoria_asset ca ON ca.id_categoria    = a.id_categoria
JOIN vendor v           ON v.id_vendor        = a.id_vendor
JOIN sede se            ON se.id_sede         = a.id_sede
JOIN responsabile r     ON r.id_responsabile  = a.id_responsabile
JOIN unita_organizzativa uo ON uo.id_unita    = r.id_unita
LEFT JOIN responsabile rb   ON rb.id_responsabile = a.id_responsabile_backup
LEFT JOIN servizi_per_asset spa ON spa.id_asset = a.id_asset
LEFT JOIN fornitori_servizi fs  ON fs.id_asset  = a.id_asset
LEFT JOIN fornitori_asset fa    ON fa.id_asset  = a.id_asset
WHERE a.criticita IN ('ALTA', 'CRITICA')          -- perimetro "asset critici"
  AND a.stato <> 'DISMESSO'
ORDER BY a.criticita DESC, ca.livello_iso, a.hostname;

COMMENT ON VIEW v_export_acn_asset_critici IS
    'Elenco asset critici con servizi, dipendenze e contatti - formato piatto per export CSV (schema ACN)';

-- View di supporto: dipendenze per servizio (vista "dal lato servizio")
CREATE OR REPLACE VIEW v_export_acn_servizi AS
SELECT
    s.codice                                              AS "ID_Servizio",
    s.nome                                                AS "Servizio",
    s.esposizione::text                                   AS "Esposizione",
    COALESCE(s.url_pubblico, '')                          AS "URL",
    s.criticita::text                                     AS "Criticita",
    CASE WHEN s.servizio_essenziale THEN 'SI' ELSE 'NO' END AS "Essenziale_NIS2",
    s.rto_ore                                             AS "RTO_Ore",
    s.rpo_ore                                             AS "RPO_Ore",
    uo.denominazione                                      AS "Unita_Erogante",
    r.cognome || ' ' || r.nome || ' <' || r.email || '>'  AS "Owner",
    (SELECT COUNT(DISTINCT id_asset) FROM asset_servizio WHERE id_servizio = s.id_servizio) AS "Num_Asset",
    (SELECT string_agg(a.hostname, '; ' ORDER BY a.hostname)
       FROM asset_servizio asv JOIN asset a ON a.id_asset = asv.id_asset
      WHERE asv.id_servizio = s.id_servizio AND asv.single_point_of_failure) AS "Asset_SPOF",
    (SELECT string_agg(f.ragione_sociale || ' [' || sf.tipo_dipendenza::text || '/' || sf.criticita_dipendenza::text
                       || CASE WHEN sf.esiste_alternativa THEN '' ELSE ' - NESSUNA ALTERNATIVA' END || ']', '; ' ORDER BY f.ragione_sociale)
       FROM servizio_fornitore sf JOIN fornitore f ON f.id_fornitore = sf.id_fornitore
      WHERE sf.id_servizio = s.id_servizio) AS "Fornitori"
FROM servizio s
JOIN responsabile r          ON r.id_responsabile = s.id_responsabile
JOIN unita_organizzativa uo  ON uo.id_unita = s.id_unita_erogante
WHERE s.attivo
ORDER BY s.criticita DESC, s.codice;

-- ---------------------------------------------------------------------
-- Esempi di export CSV (da eseguire lato client psql, non dal server):
--   \copy (SELECT * FROM nis2.v_export_acn_asset_critici) TO 'acn_asset_critici.csv' WITH (FORMAT csv, HEADER, DELIMITER ',', ENCODING 'UTF8')
--   \copy (SELECT * FROM nis2.v_export_acn_servizi)       TO 'acn_servizi.csv'       WITH (FORMAT csv, HEADER, DELIMITER ',', ENCODING 'UTF8')
-- Lato server (richiede privilegi pg_write_server_files):
--   COPY (SELECT * FROM nis2.v_export_acn_asset_critici) TO '/tmp/acn_asset_critici.csv' WITH (FORMAT csv, HEADER);
-- ---------------------------------------------------------------------


-- =====================================================================
-- 9. TEST FUNZIONALE DEL VERSIONING E DEL TRIGGER DI AUDIT
-- =====================================================================

-- 9.1 Aggiornamento firmware del firewall perimetrale (UPDATE -> versione 2)
UPDATE asset
   SET versione_firmware = 'FortiOS 7.4.6',
       ultimo_patch      = CURRENT_DATE,
       note              = note || ' - Patch PSIRT FG-IR-2026-xxx applicata'
 WHERE hostname = 'dc1-fw-edge01';

-- 9.2 Cambio responsabile per lo switch obsoleto e messa in manutenzione
UPDATE asset
   SET stato = 'IN_MANUTENZIONE',
       id_responsabile = 3
 WHERE hostname = 'anag2-acc-sw01';

-- 9.3 UPDATE "a vuoto": non deve produrre righe di storico né incrementare la versione
UPDATE asset SET modello = modello WHERE hostname = 'dc1-core-sw01';

-- 9.4 Cancellazione dell'asset dismesso (DELETE -> snapshot conservato)
DELETE FROM asset WHERE hostname = 'old-core-sw01';

-- 9.5 Verifica dello storico prodotto
SELECT id_storico, codice_inventario, operazione, versione_precedente, versione_nuova,
       campi_modificati, eseguito_da, eseguito_il
  FROM asset_storico
 WHERE operazione <> 'INSERT'
 ORDER BY id_storico;

-- 9.6 Diff puntuale sull'ultima modifica del firewall
SELECT codice_inventario,
       campo,
       dati_precedenti ->> campo AS valore_prima,
       dati_nuovi      ->> campo AS valore_dopo
  FROM asset_storico, unnest(campi_modificati) AS campo
 WHERE codice_inventario = 'CVM-SEC-0001' AND operazione = 'UPDATE'
 ORDER BY id_storico DESC, campo;

-- 9.7 Stato del record com'era alla versione 1 (popolamento iniziale)
--     e ricostruzione point-in-time tramite funzione dedicata
SELECT dati_nuovi ->> 'versione_firmware' AS firmware_originale
  FROM asset_storico WHERE codice_inventario = 'CVM-SEC-0001' AND versione_nuova = 1;
SELECT fn_asset_as_of(10, now()) ->> 'versione_firmware' AS firmware_attuale;

-- 9.8 Verifica immutabilità dello storico (deve fallire con eccezione)
DO $$
BEGIN
    DELETE FROM asset_storico WHERE id_storico = 1;
EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'OK - tentativo di manomissione dello storico bloccato: %', SQLERRM;
END;
$$;

-- 9.9 Estrazione finale per il profilo ACN
SELECT * FROM v_export_acn_asset_critici;
SELECT * FROM v_export_acn_servizi;

-- ===================== FINE SCRIPT =====================
