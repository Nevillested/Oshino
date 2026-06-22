-- ============================================================================
-- Oshino — полная схема базы данных (messenger schema)
-- ============================================================================
-- Это единственный источник правды по структуре БД. Файл полностью
-- идемпотентен (CREATE ... IF NOT EXISTS повсюду) — его можно безопасно
-- прогонять целиком в любой момент, в том числе на уже существующей БД
-- с данными: ничего не пересоздастся и не потеряется, добавится только то,
-- чего ещё не было.
--
-- Порядок применения изменений в будущем:
--   1. Дописать новый блок в конец файла (CREATE TABLE IF NOT EXISTS,
--      ALTER TABLE ... ADD COLUMN IF NOT EXISTS, CREATE INDEX IF NOT EXISTS
--      и т.д. — никогда голый CREATE/ALTER без IF NOT EXISTS/IF EXISTS).
--   2. Прогнать весь файл целиком:
--        psql -U <DB_USER> -d <DB_NAME> -h localhost -f bd.sql
--
-- Порядок таблиц ниже важен: таблицы с внешними ключами должны идти
-- после тех, на кого они ссылаются (users -> conversations -> messages).
--
-- ALTER TABLE ... OWNER to ... намеренно не используется: требует роль
-- postgres (SET ROLE), которой обычно нет у рабочего пользователя БД,
-- и не нужен при каждом прогоне — владелец назначается один раз вручную,
-- если вообще требуется.
-- ============================================================================

CREATE SCHEMA IF NOT EXISTS messenger;

-- ── Последовательности ──────────────────────────────────────────────────────

CREATE SEQUENCE IF NOT EXISTS messenger.users_id_seq;
CREATE SEQUENCE IF NOT EXISTS messenger.conversations_id_seq;
CREATE SEQUENCE IF NOT EXISTS messenger.messages_id_seq;
CREATE SEQUENCE IF NOT EXISTS messenger.push_subscriptions_id_seq;

-- ── Table: messenger.users ──────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS messenger.users
(
    id integer NOT NULL DEFAULT nextval('messenger.users_id_seq'::regclass),
    login character varying COLLATE pg_catalog."default" NOT NULL,
    password character varying COLLATE pg_catalog."default" NOT NULL,
    CONSTRAINT users_pkey1 PRIMARY KEY (id),
    CONSTRAINT users_login_key UNIQUE (login)
)
TABLESPACE pg_default;

-- ── Table: messenger.conversations ──────────────────────────────────────────

CREATE TABLE IF NOT EXISTS messenger.conversations
(
    id integer NOT NULL DEFAULT nextval('messenger.conversations_id_seq'::regclass),
    user1_id integer,
    user2_id integer,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT conversations_pkey PRIMARY KEY (id),
    CONSTRAINT conversations_user1_id_user2_id_key UNIQUE (user1_id, user2_id),
    CONSTRAINT conversations_user1_id_fkey FOREIGN KEY (user1_id)
        REFERENCES messenger.users (id) MATCH SIMPLE
        ON UPDATE NO ACTION
        ON DELETE NO ACTION,
    CONSTRAINT conversations_user2_id_fkey FOREIGN KEY (user2_id)
        REFERENCES messenger.users (id) MATCH SIMPLE
        ON UPDATE NO ACTION
        ON DELETE NO ACTION
)
TABLESPACE pg_default;

CREATE INDEX IF NOT EXISTS idx_conversations_user1
    ON messenger.conversations USING btree
    (user1_id ASC NULLS LAST)
    TABLESPACE pg_default;

CREATE INDEX IF NOT EXISTS idx_conversations_user2
    ON messenger.conversations USING btree
    (user2_id ASC NULLS LAST)
    TABLESPACE pg_default;

-- ── Table: messenger.messages ───────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS messenger.messages
(
    id integer NOT NULL DEFAULT nextval('messenger.messages_id_seq'::regclass),
    conversation_id integer,
    sender_id integer,
    content text COLLATE pg_catalog."default",
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    is_read boolean DEFAULT false,
    image_data bytea,
    image_mime character varying(50) COLLATE pg_catalog."default",
    image_filename character varying(255) COLLATE pg_catalog."default",
    audio_data bytea,
    audio_mime character varying(50) COLLATE pg_catalog."default",
    audio_duration integer,
    CONSTRAINT messages_pkey PRIMARY KEY (id),
    CONSTRAINT messages_conversation_id_fkey FOREIGN KEY (conversation_id)
        REFERENCES messenger.conversations (id) MATCH SIMPLE
        ON UPDATE NO ACTION
        ON DELETE NO ACTION,
    CONSTRAINT messages_sender_id_fkey FOREIGN KEY (sender_id)
        REFERENCES messenger.users (id) MATCH SIMPLE
        ON UPDATE NO ACTION
        ON DELETE NO ACTION
)
TABLESPACE pg_default;

CREATE INDEX IF NOT EXISTS idx_messages_conversation
    ON messenger.messages USING btree
    (conversation_id ASC NULLS LAST)
    TABLESPACE pg_default;

CREATE INDEX IF NOT EXISTS idx_messages_created
    ON messenger.messages USING btree
    (conversation_id ASC NULLS LAST, created_at DESC NULLS FIRST)
    TABLESPACE pg_default;

-- ── Table: messenger.push_subscriptions ─────────────────────────────────────
-- Подписки на Web Push (звонки + сообщения, доставляемые при оффлайн-получателе).
-- Один пользователь может иметь несколько подписок (разные устройства/браузеры).

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

CREATE INDEX IF NOT EXISTS idx_push_subscriptions_user
    ON messenger.push_subscriptions USING btree
    (user_id ASC NULLS LAST)
    TABLESPACE pg_default;

-- ── Звонки как записи в чате (как в Telegram) ───────────────────────────────
-- Звонок логируется как обычное сообщение (content = '', без текста), но с
-- этими тремя полями — отображается в чате отдельной системной отметкой,
-- а не обычным пузырём с текстом.
ALTER TABLE messenger.messages ADD COLUMN IF NOT EXISTS call_type character varying(10);
ALTER TABLE messenger.messages ADD COLUMN IF NOT EXISTS call_status character varying(20);
ALTER TABLE messenger.messages ADD COLUMN IF NOT EXISTS call_duration integer;

-- ── Reply / Pin / Forward / Reactions (как в Telegram) ──────────────────────

-- Reply: ссылка на исходное сообщение, на которое отвечают. ON DELETE SET NULL —
-- если оригинал когда-нибудь будет удалён (удаление сообщений пока не реализовано,
-- но колонка не должна стать недействительной, если это появится позже), реплай
-- останется как обычное сообщение, просто без цитаты.
ALTER TABLE messenger.messages ADD COLUMN IF NOT EXISTS reply_to_id integer
    REFERENCES messenger.messages (id) ON DELETE SET NULL;

-- Forward: логин ИСХОДНОГO автора сообщения (не того, кто переслал) — чтобы
-- цепочка пересылок всегда показывала первоисточник, как в Telegram.
ALTER TABLE messenger.messages ADD COLUMN IF NOT EXISTS forwarded_from character varying;

-- Pin: один закреплённый месседж на диалог (не несколько, как в группах) —
-- хранится на самом диалоге, а не на сообщении, чтобы открепление было
-- тривиальной операцией (просто обнулить поле, не трогая сообщения).
ALTER TABLE messenger.conversations ADD COLUMN IF NOT EXISTS pinned_message_id integer
    REFERENCES messenger.messages (id) ON DELETE SET NULL;

-- Reactions: максимум одна реакция на сообщение от одного пользователя —
-- обеспечивается UNIQUE(message_id, user_id), повторная реакция апсертится
-- (UPSERT) поверх предыдущей, а не накапливается.
CREATE SEQUENCE IF NOT EXISTS messenger.message_reactions_id_seq;

CREATE TABLE IF NOT EXISTS messenger.message_reactions
(
    id integer NOT NULL DEFAULT nextval('messenger.message_reactions_id_seq'::regclass),
    message_id integer NOT NULL,
    user_id integer NOT NULL,
    emoji character varying(16) NOT NULL,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT message_reactions_pkey PRIMARY KEY (id),
    CONSTRAINT message_reactions_message_user_key UNIQUE (message_id, user_id),
    CONSTRAINT message_reactions_message_id_fkey FOREIGN KEY (message_id)
        REFERENCES messenger.messages (id) ON DELETE CASCADE,
    CONSTRAINT message_reactions_user_id_fkey FOREIGN KEY (user_id)
        REFERENCES messenger.users (id) ON DELETE CASCADE
)
TABLESPACE pg_default;

CREATE INDEX IF NOT EXISTS idx_message_reactions_message
    ON messenger.message_reactions USING btree (message_id ASC NULLS LAST)
    TABLESPACE pg_default;

-- Реакция по умолчанию для двойного тапа — настраивается пользователем,
-- 👍 как разумное значение из коробки.
ALTER TABLE messenger.users ADD COLUMN IF NOT EXISTS default_reaction character varying(16)
    NOT NULL DEFAULT '👍';

-- ============================================================================
-- Конец файла. Новые изменения схемы дописывать ниже этой черты.
-- ============================================================================
