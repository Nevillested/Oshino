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

-- last_seen — время последнего отключения пользователя (NULL = никогда не был
-- в сети, либо данных ещё нет). Обновляется сервером при закрытии последнего
-- WebSocket-соединения логина. Используется для отображения "последний раз в сети"
-- вместо "(не в сети)" в списке диалогов, на главном экране и в шапке чата.
ALTER TABLE messenger.users ADD COLUMN IF NOT EXISTS last_seen timestamp without time zone;

-- ── Table: messenger.sessions ───────────────────────────────────────────────
-- Сессии хранятся в БД, а не в памяти процесса — чтобы перезапуск сервера
-- не разлогинивал пользователей. Каждое устройство/браузер имеет свою строку:
-- один логин может иметь несколько активных сессий одновременно.
-- При logout удаляем только строку с конкретным токеном — остальные устройства
-- остаются залогиненными.

CREATE SEQUENCE IF NOT EXISTS messenger.sessions_id_seq;

CREATE TABLE IF NOT EXISTS messenger.sessions
(
    id         integer NOT NULL DEFAULT nextval('messenger.sessions_id_seq'::regclass),
    token      character varying(64) NOT NULL,
    login      character varying NOT NULL,
    expires_at timestamp without time zone NOT NULL,
    CONSTRAINT sessions_pkey PRIMARY KEY (id),
    CONSTRAINT sessions_token_key UNIQUE (token)
)
TABLESPACE pg_default;

CREATE INDEX IF NOT EXISTS idx_sessions_token
    ON messenger.sessions USING btree (token)
    TABLESPACE pg_default;

CREATE INDEX IF NOT EXISTS idx_sessions_login
    ON messenger.sessions USING btree (login)
    TABLESPACE pg_default;

-- ============================================================================
-- Конец файла. Новые изменения схемы дописывать ниже этой черты.
-- ============================================================================

ALTER TABLE messenger.users ADD COLUMN IF NOT EXISTS display_name varchar;

-- active — флаг активности пользователя. 1 — может войти, 0 — заблокирован.
-- DEFAULT 1: все существующие пользователи остаются активными после миграции.
ALTER TABLE messenger.users ADD COLUMN IF NOT EXISTS active smallint NOT NULL DEFAULT 1;

-- ── Table: messenger.fcm_tokens ─────────────────────────────────────────────
-- Регистрационные токены Firebase Cloud Messaging для нативного Android-
-- приложения (web/PWA используют push_subscriptions выше). Один пользователь
-- может иметь несколько токенов (разные устройства). Сервер также создаёт эту
-- таблицу идемпотентно при старте (ensureFcmTable), так что применять блок
-- вручную не обязательно — он здесь для полноты схемы.

CREATE TABLE IF NOT EXISTS messenger.fcm_tokens
(
    id serial NOT NULL,
    user_id integer NOT NULL,
    token text COLLATE pg_catalog."default" NOT NULL,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fcm_tokens_pkey PRIMARY KEY (id),
    CONSTRAINT fcm_tokens_token_key UNIQUE (token),
    CONSTRAINT fcm_tokens_user_id_fkey FOREIGN KEY (user_id)
        REFERENCES messenger.users (id) MATCH SIMPLE
        ON UPDATE NO ACTION
        ON DELETE CASCADE
)
TABLESPACE pg_default;

CREATE INDEX IF NOT EXISTS idx_fcm_tokens_user
    ON messenger.fcm_tokens USING btree
    (user_id ASC NULLS LAST)
    TABLESPACE pg_default;

-- ── Редактирование сообщений ────────────────────────────────────────────────
-- edited_at: время последней правки текста. NULL = сообщение не редактировалось.
-- Нужна, чтобы пометка «изменено» сохранялась и после перезагрузки страницы.
-- Удаление сообщений отдельной колонки не требует: строка удаляется физически,
-- а связи это выдерживают (реакции — ON DELETE CASCADE, reply_to_id и
-- pinned_message_id — ON DELETE SET NULL).
ALTER TABLE messenger.messages ADD COLUMN IF NOT EXISTS edited_at timestamp without time zone;

-- ── Удаление сообщений «только у себя» ──────────────────────────────────────
-- «Удалить у всех» — это физическое удаление строки из messages (см. выше).
-- «Удалить только у меня» строку не трогает: собеседник должен продолжать
-- видеть сообщение. Поэтому факт скрытия хранится отдельно, по пользователю,
-- и история просто не отдаёт такие сообщения тому, кто их скрыл.
CREATE TABLE IF NOT EXISTS messenger.message_deletions
(
    message_id integer NOT NULL,
    user_id    integer NOT NULL,
    deleted_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT message_deletions_pkey PRIMARY KEY (message_id, user_id),
    CONSTRAINT message_deletions_message_id_fkey FOREIGN KEY (message_id)
        REFERENCES messenger.messages (id) ON DELETE CASCADE,
    CONSTRAINT message_deletions_user_id_fkey FOREIGN KEY (user_id)
        REFERENCES messenger.users (id) ON DELETE CASCADE
)
TABLESPACE pg_default;

CREATE INDEX IF NOT EXISTS idx_message_deletions_user
    ON messenger.message_deletions USING btree (user_id ASC NULLS LAST)
    TABLESPACE pg_default;

-- ── Состояние диалога у конкретного пользователя ────────────────────────────
-- Закрепление и «удаление у себя» — вещи персональные: закрепил чат я, а не оба
-- участника; удалил чат у себя — собеседник его по-прежнему видит. Поэтому
-- состояние хранится парой (пользователь, диалог), а не на самом диалоге.
--
-- hidden_at: момент «удаления у себя». Диалог не показывается в списке, пока в
-- нём нет сообщений новее этой отметки — то есть при новом сообщении чат
-- возвращается в список сам, как в Telegram.
CREATE TABLE IF NOT EXISTS messenger.dialog_states
(
    user_id         integer NOT NULL,
    conversation_id integer NOT NULL,
    pinned          boolean NOT NULL DEFAULT false,
    hidden_at       timestamp without time zone,
    CONSTRAINT dialog_states_pkey PRIMARY KEY (user_id, conversation_id),
    CONSTRAINT dialog_states_user_id_fkey FOREIGN KEY (user_id)
        REFERENCES messenger.users (id) ON DELETE CASCADE,
    CONSTRAINT dialog_states_conversation_id_fkey FOREIGN KEY (conversation_id)
        REFERENCES messenger.conversations (id) ON DELETE CASCADE
)
TABLESPACE pg_default;

CREATE INDEX IF NOT EXISTS idx_dialog_states_user
    ON messenger.dialog_states USING btree (user_id ASC NULLS LAST)
    TABLESPACE pg_default;

-- ── Видеосообщения ──────────────────────────────────────────────────────────
-- Один набор колонок на два случая:
--   video_is_circle = true  — видеокружок, записанный прямо в мессенджере
--                             (сервер обрезает кадр в квадрат, клиент рисует круг);
--   video_is_circle = false — обычное видео, приложенное из галереи.
-- Само видео, как картинки и голосовые, лежит в bytea: отдельного файлового
-- хранилища у проекта нет, а бэкап базы заодно бэкапит и вложения.
-- Формат всегда один — H.264 + AAC в MP4 (приводится через ffmpeg при загрузке),
-- потому что браузеры пишут кто во что горазд, а Safari/iOS не умеет WebM.
ALTER TABLE messenger.messages ADD COLUMN IF NOT EXISTS video_data bytea;
ALTER TABLE messenger.messages ADD COLUMN IF NOT EXISTS video_mime character varying(50);
ALTER TABLE messenger.messages ADD COLUMN IF NOT EXISTS video_duration integer;
ALTER TABLE messenger.messages ADD COLUMN IF NOT EXISTS video_is_circle boolean NOT NULL DEFAULT false;

-- ── Переход к исходнику пересланного сообщения ──────────────────────────────
-- forwarded_from хранит только ЛОГИН первоисточника — этого хватало, пока
-- плашка «Переслано от…» просто открывала чат. Теперь вся плашка — ссылка,
-- ведущая к конкретному сообщению, поэтому нужен и его id.
--
-- Как и forwarded_from, id указывает на ПЕРВОИСТОЧНИК, а не на промежуточное
-- звено: если пересылают уже пересланное, значение копируется как есть.
--
-- Внешнего ключа здесь намеренно нет: оригинал может быть удалён (в том числе
-- «только у себя» у одной из сторон), а плашка при этом должна остаться —
-- просто перестанет никуда вести. Проверку доступности делает сервер
-- (см. handleMessageLocation): показать сообщение можно только тому, кто
-- состоит в диалоге, где оно лежит.
ALTER TABLE messenger.messages ADD COLUMN IF NOT EXISTS forwarded_from_id integer;

-- ── Произвольные файлы во вложениях ─────────────────────────────────────────
-- Отдельный набор колонок, а не переиспользование image_*/video_*: у файла нет
-- ни превью, ни длительности, зато нужен размер (показывается в пузыре) и
-- исходное имя (под ним файл скачивается). Тип не ограничен ничем, кроме
-- размера — 100 МБ, как у видео.
--
-- Данные, как и остальные вложения, лежат в bytea: отдельного файлового
-- хранилища у проекта нет, а бэкап базы заодно бэкапит и вложения.
-- file_size хранится отдельно от octet_length(file_data), чтобы список чатов
-- и превью не приходилось считать по самому блобу.
ALTER TABLE messenger.messages ADD COLUMN IF NOT EXISTS file_data bytea;
ALTER TABLE messenger.messages ADD COLUMN IF NOT EXISTS file_name character varying(255);
ALTER TABLE messenger.messages ADD COLUMN IF NOT EXISTS file_mime character varying(255);
ALTER TABLE messenger.messages ADD COLUMN IF NOT EXISTS file_size bigint;

-- ── Беззвучный чат (mute) ───────────────────────────────────────────────────
-- Настройка персональная, как закрепление: замьютил чат я — у собеседника
-- ничего не изменилось. Поэтому колонка живёт в dialog_states, а не в
-- conversations.
--
-- Замьюченный чат по-прежнему считает непрочитанные и показывает бейдж —
-- глушится только звук в открытой вкладке и push на устройства.
ALTER TABLE messenger.dialog_states ADD COLUMN IF NOT EXISTS muted boolean NOT NULL DEFAULT false;
