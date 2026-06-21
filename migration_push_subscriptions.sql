-- Миграция: push-уведомления (Web Push API)
-- Применять командой:
--   psql -U <DB_USER> -d <DB_NAME> -f migration_push_subscriptions.sql

-- Table: messenger.push_subscriptions
--
-- Одна строка = одна подписка одного браузера/устройства на push-уведомления.
-- У пользователя может быть несколько подписок одновременно (ПК + телефон) —
-- поэтому ключ не user_id, а сама связка user_id + endpoint.

CREATE SEQUENCE IF NOT EXISTS messenger.push_subscriptions_id_seq;

CREATE TABLE IF NOT EXISTS messenger.push_subscriptions
(
    id integer NOT NULL DEFAULT nextval('messenger.push_subscriptions_id_seq'::regclass),
    user_id integer NOT NULL,
    endpoint text COLLATE pg_catalog."default" NOT NULL,
    p256dh character varying(255) COLLATE pg_catalog."default" NOT NULL,
    auth character varying(255) COLLATE pg_catalog."default" NOT NULL,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT push_subscriptions_pkey PRIMARY KEY (id),
    CONSTRAINT push_subscriptions_endpoint_key UNIQUE (endpoint),
    CONSTRAINT push_subscriptions_user_id_fkey FOREIGN KEY (user_id)
        REFERENCES messenger.users (id) MATCH SIMPLE
        ON UPDATE NO ACTION
        ON DELETE CASCADE
)

TABLESPACE pg_default;

ALTER TABLE IF EXISTS messenger.push_subscriptions
    OWNER to postgres;

-- Index: idx_push_subscriptions_user

CREATE INDEX IF NOT EXISTS idx_push_subscriptions_user
    ON messenger.push_subscriptions USING btree
    (user_id ASC NULLS LAST)
    TABLESPACE pg_default;
