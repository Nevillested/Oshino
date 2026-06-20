-- Table: messenger.conversations

-- DROP TABLE IF EXISTS messenger.conversations;

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

ALTER TABLE IF EXISTS messenger.conversations
    OWNER to postgres;
-- Index: idx_conversations_user1

-- DROP INDEX IF EXISTS messenger.idx_conversations_user1;

CREATE INDEX IF NOT EXISTS idx_conversations_user1
    ON messenger.conversations USING btree
    (user1_id ASC NULLS LAST)
    TABLESPACE pg_default;
-- Index: idx_conversations_user2

-- DROP INDEX IF EXISTS messenger.idx_conversations_user2;

CREATE INDEX IF NOT EXISTS idx_conversations_user2
    ON messenger.conversations USING btree
    (user2_id ASC NULLS LAST)
    TABLESPACE pg_default;



-- Table: messenger.messages

-- DROP TABLE IF EXISTS messenger.messages;

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

ALTER TABLE IF EXISTS messenger.messages
    OWNER to postgres;
-- Index: idx_messages_conversation

-- DROP INDEX IF EXISTS messenger.idx_messages_conversation;

CREATE INDEX IF NOT EXISTS idx_messages_conversation
    ON messenger.messages USING btree
    (conversation_id ASC NULLS LAST)
    TABLESPACE pg_default;
-- Index: idx_messages_created

-- DROP INDEX IF EXISTS messenger.idx_messages_created;

CREATE INDEX IF NOT EXISTS idx_messages_created
    ON messenger.messages USING btree
    (conversation_id ASC NULLS LAST, created_at DESC NULLS FIRST)
    TABLESPACE pg_default;


-- Table: messenger.users

-- DROP TABLE IF EXISTS messenger.users;

CREATE TABLE IF NOT EXISTS messenger.users
(
    id integer NOT NULL DEFAULT nextval('messenger.users_id_seq'::regclass),
    login character varying COLLATE pg_catalog."default" NOT NULL,
    password character varying COLLATE pg_catalog."default" NOT NULL,
    CONSTRAINT users_pkey1 PRIMARY KEY (id),
    CONSTRAINT users_login_key UNIQUE (login)
)

TABLESPACE pg_default;

ALTER TABLE IF EXISTS messenger.users
    OWNER to postgres;
