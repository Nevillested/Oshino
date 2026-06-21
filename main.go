package main

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha1"
	"database/sql"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	webpush "github.com/SherClockHolmes/webpush-go"
	"github.com/gorilla/websocket"
	"github.com/joho/godotenv"
	_ "github.com/lib/pq"
	"golang.org/x/crypto/bcrypt"
)

type App struct {
	db       *sql.DB
	sessions map[string]Session
	mu       sync.Mutex
	clients  map[string]map[*Client]bool // login -> множество активных соединений (мультидевайс)

	// defaultContact — логин пользователя с id=1, добавляется всем как контакт по умолчанию.
	// Читается один раз при старте, чтобы не дёргать БД на каждую отправку списка диалогов.
	defaultContact string

	// turnSecret — общий секрет для генерации time-limited TURN credentials
	// (TURN REST API, см. coturn use-auth-secret/static-auth-secret).
	// Никогда не покидает сервер: фронтенду отдаём только готовые username/password.
	turnSecret string

	// VAPID-ключи для Web Push (см. https://datatracker.ietf.org/doc/html/rfc8292).
	// Публичный ключ отдаётся фронтенду для PushManager.subscribe(),
	// приватный используется только сервером для подписи push-сообщений.
	vapidPublicKey  string
	vapidPrivateKey string
	vapidContact    string // mailto: или https:-адрес для VAPID claim (sub)

	// pendingCalls — звонки, чей call-offer не удалось доставить сразу (получатель
	// был полностью оффлайн). Буферизуется на время ожидания ответа (callRingTimeout),
	// чтобы при открытии приложения по push-уведомлению можно было показать входящий
	// звонок, как будто он только что пришёл. Ключ — логин ПОЛУЧАТЕЛЯ (того, кому звонят).
	// Отдельный мьютекс — не a.mu, чтобы не пересекаться с блокировками карты клиентов.
	pendingCalls map[string]*PendingCall
	callMu       sync.Mutex

	// activeCalls отслеживает исход КАЖДОГО звонка (онлайн или нет) от call-offer
	// до его разрешения (answer/reject/end/таймаут), чтобы по завершении сохранить
	// в БД и доставить системную запись о звонке — отвечен/отклонён/пропущен,
	// и если отвечен, то сколько длился. Тот же callMu, что и у pendingCalls —
	// оба про жизненный цикл звонка, а не про карту клиентских соединений.
	activeCalls map[string]*activeCallInfo
}

// activeCallInfo — состояние звонка для последующего логирования. from/to —
// исходные участники из call-offer (направление не меняется, кто бы потом ни
// положил трубку). answeredAt проставляется при call-answer; если к моменту
// разрешения звонка она так и осталась nil — звонок был отклонён или пропущен.
type activeCallInfo struct {
	from       string
	to         string
	video      bool
	answeredAt *time.Time
}

// PendingCall хранит исходный call-offer и таймер автоматического "не отвечает".
type PendingCall struct {
	Sig   CallSignal
	Timer *time.Timer
}

type Session struct {
	login   string
	expires time.Time
}

type Client struct {
	login string
	conn  *websocket.Conn
	send  chan []byte
	done  chan struct{} // закрывается один раз в readPump при отключении
}

type Message struct {
	From          string `json:"from"`
	To            string `json:"to"`
	Text          string `json:"text"`
	CreatedAt     string `json:"created_at,omitempty"`
	ImageID       int    `json:"image_id,omitempty"`
	ImageName     string `json:"image_name,omitempty"`
	ImageMime     string `json:"image_mime,omitempty"`
	AudioID       int    `json:"audio_id,omitempty"`
	AudioDuration int    `json:"audio_duration,omitempty"`
	// Поля системной записи о звонке (см. saveCallMessage) — звонок логируется как
	// сообщение без текста, с этими полями, и отображается в чате отдельной
	// "системной" отметкой, как в Telegram, а не обычным пузырём.
	CallMsgID    int    `json:"call_msg_id,omitempty"`
	CallType     string `json:"call_type,omitempty"`   // "audio" | "video"
	CallStatus   string `json:"call_status,omitempty"` // "answered" | "missed" | "declined"
	CallDuration *int   `json:"call_duration,omitempty"` // секунды; nil — звонок не был отвечен
}

type HistoryMessage struct {
	From string `json:"from"`
	To   string `json:"to"`
	Text string `json:"text"`
	Own  bool   `json:"own"`
}

// CallSignal — конверт сигналинга звонков (offer/answer/ice/end/reject).
// Сервер не интерпретирует SDP/ICE содержимое, только маршрутизирует между
// устройствами from/to — ровно так же, как Message, но без сохранения в БД.
type CallSignal struct {
	Type      string `json:"type"`                // call-offer | call-answer | call-ice | call-end | call-reject | call-video-on | call-video-on-answer
	From      string `json:"from"`
	To        string `json:"to"`
	CallID    string `json:"call_id"`             // генерируется звонящим, привязывает все сообщения одного звонка
	SDP       string `json:"sdp,omitempty"`       // для offer/answer
	SDPType   string `json:"sdp_type,omitempty"`  // "offer" | "answer"
	Candidate string `json:"candidate,omitempty"` // ICE-кандидат (как JSON-строка от RTCIceCandidate)
	Reason    string `json:"reason,omitempty"`    // причина для end/reject (busy, hangup, timeout, answered-elsewhere)
	Video     bool   `json:"video,omitempty"`     // true — звонок инициирован/идёт с видео (для call-offer: запрошено видео с самого начала)
}

var upgrader = websocket.Upgrader{
	CheckOrigin: func(r *http.Request) bool { return true },
}

const maxImageSize = 10 << 20 // 10 МБ
const maxAudioSize = 20 << 20 // 20 МБ

var allowedImageMimes = map[string]bool{
	"image/jpeg": true,
	"image/png":  true,
	"image/webp": true,
	"image/gif":  true,
}

// allowedAudioMimes больше не используется для проверки: любой входящий формат
// (webm/ogg/mp4 и т.д.) пропускается через ffmpeg и приводится к единому audio/mp4 (AAC),
// который гарантированно воспроизводится во всех браузерах, включая iOS Safari/WebKit.

func generateToken() string {
	bytes := make([]byte, 16)
	rand.Read(bytes)
	return hex.EncodeToString(bytes)
}

func main() {
	fmt.Println("Oshino запускается...")

	// Однократная утилита: `./oshino -gen-vapid` печатает новую пару VAPID-ключей
	// и сразу выходит, не трогая БД/сеть. Ключи нужно вручную один раз вписать
	// в my_cfg (VAPID_PUBLIC_KEY / VAPID_PRIVATE_KEY) — после этого флаг больше не нужен.
	genVapid := flag.Bool("gen-vapid", false, "сгенерировать новую пару VAPID-ключей и выйти")
	flag.Parse()

	if *genVapid {
		priv, pub, err := webpush.GenerateVAPIDKeys()
		if err != nil {
			log.Fatalf("Не удалось сгенерировать VAPID-ключи: %v", err)
		}
		fmt.Println("Сгенерированы новые VAPID-ключи. Добавьте в my_cfg:")
		fmt.Println("VAPID_PUBLIC_KEY=" + pub)
		fmt.Println("VAPID_PRIVATE_KEY=" + priv)
		return
	}

	err := godotenv.Load("my_cfg")
	if err != nil {
		log.Fatalf("Ошибка чтения my_cfg: %v", err)
	}

	connStr := fmt.Sprintf(
		"host=%s port=%s dbname=%s user=%s password=%s sslmode=disable timezone=UTC",
		os.Getenv("DB_HOST"),
		os.Getenv("DB_PORT"),
		os.Getenv("DB_NAME"),
		os.Getenv("DB_USER"),
		os.Getenv("DB_PASSWORD"),
	)

	db, err := sql.Open("postgres", connStr)
	if err != nil {
		log.Fatalf("Ошибка открытия БД: %v", err)
	}
	defer db.Close()

	err = db.Ping()
	if err != nil {
		log.Fatalf("Не удалось подключиться к БД: %v", err)
	}

	fmt.Println("Подключение к PostgreSQL успешно!")

	app := &App{
		db:              db,
		sessions:        make(map[string]Session),
		clients:         make(map[string]map[*Client]bool),
		turnSecret:      os.Getenv("TURN_SECRET"),
		vapidPublicKey:  os.Getenv("VAPID_PUBLIC_KEY"),
		vapidPrivateKey: os.Getenv("VAPID_PRIVATE_KEY"),
		vapidContact:    os.Getenv("VAPID_CONTACT"), // например, mailto:admin@oshino.space
		pendingCalls:    make(map[string]*PendingCall),
		activeCalls:     make(map[string]*activeCallInfo),
	}

	if app.turnSecret == "" {
		log.Println("ВНИМАНИЕ: TURN_SECRET не задан в my_cfg — звонки работать не будут (TURN credentials не сгенерировать)")
	}

	if app.vapidPublicKey == "" || app.vapidPrivateKey == "" {
		log.Println("ВНИМАНИЕ: VAPID_PUBLIC_KEY/VAPID_PRIVATE_KEY не заданы в my_cfg — push-уведомления работать не будут. Сгенерировать: ./oshino -gen-vapid")
	}
	if app.vapidContact == "" {
		app.vapidContact = "mailto:admin@oshino.space"
	}

	if err := app.db.QueryRow("SELECT login FROM messenger.users WHERE id = 1").Scan(&app.defaultContact); err != nil {
		log.Printf("Не удалось получить дефолтный контакт (id=1): %v", err)
	}

	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		http.ServeFile(w, r, "static/index.html")
	})
	http.HandleFunc("/sw.js", func(w http.ResponseWriter, r *http.Request) {
		// Service Worker обязательно должен отдаваться с корневого пути (не из /static/),
		// иначе его scope ограничится только /static/* и push не будет работать для /chat.
		w.Header().Set("Content-Type", "application/javascript")
		// Service-Worker-Allowed на всякий случай — явное расширение scope, хотя при
		// раздаче с корня браузер и так выберет scope "/" по умолчанию.
		w.Header().Set("Service-Worker-Allowed", "/")
		http.ServeFile(w, r, "static/sw.js")
	})
	// icons/ — лежит на верхнем уровне проекта (не внутри static/), раздаём отдельной
	// директорией: иконка вкладки, главного экрана iOS/Android и push-уведомлений — один
	// и тот же файл, используемый сразу в нескольких местах разметки и в sw.js.
	http.Handle("/icons/", http.StripPrefix("/icons/", http.FileServer(http.Dir("icons"))))
	http.HandleFunc("/manifest.json", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/manifest+json")
		http.ServeFile(w, r, "static/manifest.json")
	})
	http.HandleFunc("/login", app.handleLogin)
	http.HandleFunc("/chat", app.handleChat)
	http.HandleFunc("/ws", app.handleWS)
	http.HandleFunc("/search", app.handleSearch)
	http.HandleFunc("/logout", app.handleLogout)
	http.HandleFunc("/history", app.handleHistory)
	http.HandleFunc("/mark-read", app.handleMarkRead)
	http.HandleFunc("/unread-counts", app.handleUnreadCounts)
	http.HandleFunc("/upload-image", app.handleUploadImage)
	http.HandleFunc("/image/", app.handleGetImage)
	http.HandleFunc("/upload-audio", app.handleUploadAudio)
	http.HandleFunc("/audio/", app.handleGetAudio)
	http.HandleFunc("/turn-credentials", app.handleTurnCredentials)
	http.HandleFunc("/push-public-key", app.handlePushPublicKey)
	http.HandleFunc("/push-subscribe", app.handlePushSubscribe)
	http.HandleFunc("/push-unsubscribe", app.handlePushUnsubscribe)

	fmt.Println("Сервер слушает порт 8080...")
	http.ListenAndServe(":8080", nil)
}

// getSessionLogin возвращает логин по куке сессии, либо пустую строку если сессия не валидна
func (a *App) getSessionLogin(r *http.Request) string {
	cookie, err := r.Cookie("session")
	if err != nil {
		return ""
	}
	a.mu.Lock()
	sess, ok := a.sessions[cookie.Value]
	a.mu.Unlock()
	if !ok || time.Now().After(sess.expires) {
		return ""
	}
	return sess.login
}

func (a *App) handleLogin(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "Метод не поддерживается", http.StatusMethodNotAllowed)
		return
	}

	login := strings.ToLower(r.FormValue("login"))
	password := r.FormValue("password")

	var dbPassword string
	err := a.db.QueryRow(
		"SELECT password FROM messenger.users WHERE LOWER(login) = $1",
		login,
	).Scan(&dbPassword)

	if err != nil {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]string{"error": "Неправильный логин или пароль"})
		return
	}

	err = bcrypt.CompareHashAndPassword([]byte(dbPassword), []byte(password))
	if err != nil {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]string{"error": "Неправильный логин или пароль"})
		return
	}

	token := generateToken()
	expires := time.Now().Add(30 * 24 * time.Hour)

	a.mu.Lock()
	a.sessions[token] = Session{login: login, expires: expires}
	a.mu.Unlock()

	http.SetCookie(w, &http.Cookie{
		Name:     "session",
		Value:    token,
		HttpOnly: true,
		MaxAge:   30 * 24 * 60 * 60, // 30 дней
		Path:     "/",
	})

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]string{"success": "ok"})
}

func (a *App) handleChat(w http.ResponseWriter, r *http.Request) {
	login := a.getSessionLogin(r)
	if login == "" {
		http.Redirect(w, r, "/", http.StatusSeeOther)
		return
	}
	http.ServeFile(w, r, "static/chat.html")
}

func (a *App) handleWS(w http.ResponseWriter, r *http.Request) {
	login := a.getSessionLogin(r)
	if login == "" {
		http.Error(w, "Unauthorized", http.StatusUnauthorized)
		return
	}

	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		log.Println("Ошибка upgrade:", err)
		return
	}

	client := &Client{
		login: login,
		conn:  conn,
		send:  make(chan []byte, 256),
		done:  make(chan struct{}),
	}

	a.mu.Lock()
	if a.clients[login] == nil {
		a.clients[login] = make(map[*Client]bool)
	}
	a.clients[login][client] = true
	deviceCount := len(a.clients[login])
	a.mu.Unlock()

	fmt.Printf("%s подключился (устройств онлайн: %d)\n", login, deviceCount)

	client.send <- []byte("user:" + login)
	a.broadcastOnlineUsers()
	a.deliverPendingCallIfAny(client)

	go client.readPump(a)
	go client.writePump()
}

func (a *App) loadDialogsFromDB(login string) ([]string, error) {
	rows, err := a.db.Query(`
		SELECT DISTINCT
			CASE WHEN u1.login = $1 THEN u2.login ELSE u1.login END AS other_login
		FROM messenger.conversations c
		JOIN messenger.users u1 ON u1.id = c.user1_id
		JOIN messenger.users u2 ON u2.id = c.user2_id
		WHERE LOWER(u1.login) = LOWER($1) OR LOWER(u2.login) = LOWER($1)
	`, login)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var dialogs []string
	for rows.Next() {
		var other string
		rows.Scan(&other)
		dialogs = append(dialogs, other)
	}
	return dialogs, nil
}

// getOrCreateConversation возвращает conversation_id для двух пользователей, создавая если нет
func (a *App) getOrCreateConversation(login1, login2 string) (int, error) {
	var id1, id2 int
	err := a.db.QueryRow("SELECT id FROM messenger.users WHERE LOWER(login) = LOWER($1)", login1).Scan(&id1)
	if err != nil {
		return 0, fmt.Errorf("пользователь %s не найден: %v", login1, err)
	}
	err = a.db.QueryRow("SELECT id FROM messenger.users WHERE LOWER(login) = LOWER($1)", login2).Scan(&id2)
	if err != nil {
		return 0, fmt.Errorf("пользователь %s не найден: %v", login2, err)
	}

	// Пара хранится упорядоченно: user1_id < user2_id
	if id1 > id2 {
		id1, id2 = id2, id1
	}

	var convID int
	err = a.db.QueryRow(
		"SELECT id FROM messenger.conversations WHERE user1_id = $1 AND user2_id = $2",
		id1, id2,
	).Scan(&convID)

	if err == sql.ErrNoRows {
		err = a.db.QueryRow(
			"INSERT INTO messenger.conversations (user1_id, user2_id) VALUES ($1, $2) RETURNING id",
			id1, id2,
		).Scan(&convID)
		if err != nil {
			return 0, err
		}
	} else if err != nil {
		return 0, err
	}

	return convID, nil
}

func (a *App) saveMessage(from, to, text string) (string, error) {
	convID, err := a.getOrCreateConversation(from, to)
	if err != nil {
		return "", err
	}

	var senderID int
	err = a.db.QueryRow("SELECT id FROM messenger.users WHERE LOWER(login) = LOWER($1)", from).Scan(&senderID)
	if err != nil {
		return "", err
	}

	var createdAt time.Time
	err = a.db.QueryRow(
		"INSERT INTO messenger.messages (conversation_id, sender_id, content) VALUES ($1, $2, $3) RETURNING created_at AT TIME ZONE 'UTC'",
		convID, senderID, text,
	).Scan(&createdAt)
	if err != nil {
		return "", err
	}

	return createdAt.UTC().Format(time.RFC3339), nil
}

// saveImageMessage сохраняет сообщение-картинку в БД и возвращает id сообщения и время отправки
func (a *App) saveImageMessage(from, to string, imageData []byte, mime, filename string) (int, string, error) {
	convID, err := a.getOrCreateConversation(from, to)
	if err != nil {
		return 0, "", err
	}

	var senderID int
	err = a.db.QueryRow("SELECT id FROM messenger.users WHERE LOWER(login) = LOWER($1)", from).Scan(&senderID)
	if err != nil {
		return 0, "", err
	}

	var msgID int
	var createdAt time.Time
	err = a.db.QueryRow(`
		INSERT INTO messenger.messages (conversation_id, sender_id, content, image_data, image_mime, image_filename)
		VALUES ($1, $2, '', $3, $4, $5)
		RETURNING id, created_at AT TIME ZONE 'UTC'
	`, convID, senderID, imageData, mime, filename).Scan(&msgID, &createdAt)
	if err != nil {
		return 0, "", err
	}

	return msgID, createdAt.UTC().Format(time.RFC3339), nil
}

// handleHistory отдаёт историю сообщений с пагинацией
// GET /history?with=<login>&before_id=<id>&limit=<n>
// before_id=0 — последние limit сообщений
func (a *App) handleHistory(w http.ResponseWriter, r *http.Request) {
	login := a.getSessionLogin(r)
	if login == "" {
		http.Error(w, "Unauthorized", http.StatusUnauthorized)
		return
	}

	withUser := r.URL.Query().Get("with")
	if withUser == "" {
		http.Error(w, "missing with", http.StatusBadRequest)
		return
	}

	limitStr := r.URL.Query().Get("limit")
	limit := 20
	if limitStr != "" {
		if l, err := strconv.Atoi(limitStr); err == nil && l > 0 {
			limit = l
		}
	}

	beforeIDStr := r.URL.Query().Get("before_id")
	beforeID := 0
	if beforeIDStr != "" {
		beforeID, _ = strconv.Atoi(beforeIDStr)
	}

	convID, err := a.getOrCreateConversation(login, withUser)
	if err != nil {
		http.Error(w, "Error", http.StatusInternalServerError)
		return
	}

	var rows *sql.Rows
	if beforeID == 0 {
		rows, err = a.db.Query(`
			SELECT m.id, u.login, m.content, m.created_at AT TIME ZONE 'UTC',
			       m.image_mime, m.image_filename, (m.image_data IS NOT NULL) AS has_image,
			       (m.audio_data IS NOT NULL) AS has_audio, m.audio_duration,
			       m.call_type, m.call_status, m.call_duration
			FROM (
				SELECT id, sender_id, content, created_at, image_mime, image_filename, image_data,
				       audio_data, audio_duration, call_type, call_status, call_duration
				FROM messenger.messages
				WHERE conversation_id = $1
				ORDER BY id DESC
				LIMIT $2
			) m
			JOIN messenger.users u ON u.id = m.sender_id
			ORDER BY m.id ASC
		`, convID, limit)
	} else {
		rows, err = a.db.Query(`
			SELECT m.id, u.login, m.content, m.created_at AT TIME ZONE 'UTC',
			       m.image_mime, m.image_filename, (m.image_data IS NOT NULL) AS has_image,
			       (m.audio_data IS NOT NULL) AS has_audio, m.audio_duration,
			       m.call_type, m.call_status, m.call_duration
			FROM (
				SELECT id, sender_id, content, created_at, image_mime, image_filename, image_data,
				       audio_data, audio_duration, call_type, call_status, call_duration
				FROM messenger.messages
				WHERE conversation_id = $1 AND id < $2
				ORDER BY id DESC
				LIMIT $3
			) m
			JOIN messenger.users u ON u.id = m.sender_id
			ORDER BY m.id ASC
		`, convID, beforeID, limit)
	}

	if err != nil {
		http.Error(w, "Error", http.StatusInternalServerError)
		return
	}
	defer rows.Close()

	type HistMsg struct {
		ID            int    `json:"id"`
		From          string `json:"from"`
		Text          string `json:"text"`
		Own           bool   `json:"own"`
		CreatedAt     string `json:"created_at"`
		ImageID       int    `json:"image_id,omitempty"`
		ImageName     string `json:"image_name,omitempty"`
		ImageMime     string `json:"image_mime,omitempty"`
		AudioID       int    `json:"audio_id,omitempty"`
		AudioDuration int    `json:"audio_duration,omitempty"`
		CallType      string `json:"call_type,omitempty"`
		CallStatus    string `json:"call_status,omitempty"`
		CallDuration  *int   `json:"call_duration,omitempty"`
	}

	var messages []HistMsg
	for rows.Next() {
		var m HistMsg
		var createdAt time.Time
		var imageMime, imageFilename sql.NullString
		var hasImage, hasAudio bool
		var audioDuration sql.NullInt64
		var callType, callStatus sql.NullString
		var callDuration sql.NullInt64
		rows.Scan(&m.ID, &m.From, &m.Text, &createdAt,
			&imageMime, &imageFilename, &hasImage,
			&hasAudio, &audioDuration,
			&callType, &callStatus, &callDuration)
		m.Own = strings.EqualFold(m.From, login)
		m.CreatedAt = createdAt.UTC().Format(time.RFC3339)
		if hasImage {
			m.ImageID = m.ID
			m.ImageMime = imageMime.String
			m.ImageName = imageFilename.String
		}
		if hasAudio {
			m.AudioID = m.ID
			m.AudioDuration = int(audioDuration.Int64)
		}
		if callType.Valid {
			m.CallType = callType.String
			m.CallStatus = callStatus.String
			if callDuration.Valid {
				d := int(callDuration.Int64)
				m.CallDuration = &d
			}
		}
		messages = append(messages, m)
	}
	if messages == nil {
		messages = []HistMsg{}
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(messages)
}

func (a *App) broadcastOnlineUsers() {
	a.mu.Lock()
	logins := make([]string, 0, len(a.clients))
	var allClients []*Client
	for login, conns := range a.clients {
		logins = append(logins, login)
		for c := range conns {
			allClients = append(allClients, c)
		}
	}
	a.mu.Unlock()

	onlineList := "["
	first := true
	for _, login := range logins {
		if !first {
			onlineList += ","
		}
		onlineList += "\"" + login + "\""
		first = false
	}
	onlineList += "]"

	payload := []byte("online:" + onlineList)
	for _, c := range allClients {
		c.trySend(payload)
	}
}

func (a *App) handleSearch(w http.ResponseWriter, r *http.Request) {
	login := a.getSessionLogin(r)
	if login == "" {
		http.Error(w, "Unauthorized", http.StatusUnauthorized)
		return
	}

	query := r.URL.Query().Get("q")
	if query == "" {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode([]string{})
		return
	}

	rows, err := a.db.Query(
		"SELECT login FROM messenger.users WHERE LOWER(login) = LOWER($1)",
		query,
	)
	if err != nil {
		http.Error(w, "Error", http.StatusInternalServerError)
		return
	}
	defer rows.Close()

	var results []string
	for rows.Next() {
		var l string
		rows.Scan(&l)
		results = append(results, l)
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(results)
}

// handleUploadImage принимает multipart-форму с картинкой, проверяет тип/размер,
// сохраняет в БД как новое сообщение и рассылает его через WS как обычное сообщение.
// POST /upload-image (multipart/form-data: file, to)
func (a *App) handleUploadImage(w http.ResponseWriter, r *http.Request) {
	login := a.getSessionLogin(r)
	if login == "" {
		http.Error(w, "Unauthorized", http.StatusUnauthorized)
		return
	}

	if r.Method != http.MethodPost {
		http.Error(w, "Метод не поддерживается", http.StatusMethodNotAllowed)
		return
	}

	r.Body = http.MaxBytesReader(w, r.Body, maxImageSize+(1<<20)) // небольшой запас на метаданные формы

	if err := r.ParseMultipartForm(maxImageSize + (1 << 20)); err != nil {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusBadRequest)
		json.NewEncoder(w).Encode(map[string]string{"error": "Файл слишком большой или форма повреждена"})
		return
	}

	to := r.FormValue("to")
	if to == "" {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusBadRequest)
		json.NewEncoder(w).Encode(map[string]string{"error": "Не указан получатель"})
		return
	}

	file, header, err := r.FormFile("file")
	if err != nil {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusBadRequest)
		json.NewEncoder(w).Encode(map[string]string{"error": "Файл не найден"})
		return
	}
	defer file.Close()

	if header.Size > maxImageSize {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusBadRequest)
		json.NewEncoder(w).Encode(map[string]string{"error": "Файл слишком большой (максимум 10 МБ)"})
		return
	}

	// Читаем первые байты для определения реального MIME-типа (не доверяем заголовку от клиента)
	buf := make([]byte, 512)
	n, _ := file.Read(buf)
	detectedMime := http.DetectContentType(buf[:n])

	if !allowedImageMimes[detectedMime] {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusBadRequest)
		json.NewEncoder(w).Encode(map[string]string{"error": "Недопустимый тип файла. Разрешены: JPG, PNG, WEBP, GIF"})
		return
	}

	// Возвращаемся в начало файла и читаем целиком
	if _, err := file.Seek(0, io.SeekStart); err != nil {
		http.Error(w, "Error", http.StatusInternalServerError)
		return
	}

	imageData, err := io.ReadAll(io.LimitReader(file, maxImageSize+1))
	if err != nil {
		http.Error(w, "Error", http.StatusInternalServerError)
		return
	}
	if len(imageData) > maxImageSize {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusBadRequest)
		json.NewEncoder(w).Encode(map[string]string{"error": "Файл слишком большой (максимум 10 МБ)"})
		return
	}

	filename := header.Filename
	if filename == "" {
		filename = "image"
	}

	msgID, createdAt, err := a.saveImageMessage(login, to, imageData, detectedMime, filename)
	if err != nil {
		log.Println("Ошибка сохранения картинки:", err)
		http.Error(w, "Error", http.StatusInternalServerError)
		return
	}

	msg := Message{
		From:      login,
		To:        to,
		CreatedAt: createdAt,
		ImageID:   msgID,
		ImageName: filename,
		ImageMime: detectedMime,
	}

	a.routeMessage(msg)

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]interface{}{
		"success":    true,
		"image_id":   msgID,
		"created_at": createdAt,
	})
}

// handleGetImage отдаёт бинарные данные картинки по id сообщения
// GET /image/<id>
func (a *App) handleGetImage(w http.ResponseWriter, r *http.Request) {
	login := a.getSessionLogin(r)
	if login == "" {
		http.Error(w, "Unauthorized", http.StatusUnauthorized)
		return
	}

	idStr := strings.TrimPrefix(r.URL.Path, "/image/")
	msgID, err := strconv.Atoi(idStr)
	if err != nil {
		http.Error(w, "Bad request", http.StatusBadRequest)
		return
	}

	var myID int
	err = a.db.QueryRow("SELECT id FROM messenger.users WHERE LOWER(login)=LOWER($1)", login).Scan(&myID)
	if err != nil {
		http.Error(w, "Error", http.StatusInternalServerError)
		return
	}

	var imageData []byte
	var mime string
	err = a.db.QueryRow(`
		SELECT m.image_data, m.image_mime
		FROM messenger.messages m
		JOIN messenger.conversations c ON c.id = m.conversation_id
		WHERE m.id = $1
		  AND m.image_data IS NOT NULL
		  AND (c.user1_id = $2 OR c.user2_id = $2)
	`, msgID, myID).Scan(&imageData, &mime)

	if err != nil {
		http.Error(w, "Not found", http.StatusNotFound)
		return
	}

	w.Header().Set("Content-Type", mime)
	w.Header().Set("Cache-Control", "private, max-age=86400")
	w.Write(imageData)
}

// saveAudioMessage сохраняет голосовое сообщение в БД
func (a *App) saveAudioMessage(from, to string, audioData []byte, mime string, duration int) (int, string, error) {
	convID, err := a.getOrCreateConversation(from, to)
	if err != nil {
		return 0, "", err
	}

	var senderID int
	err = a.db.QueryRow("SELECT id FROM messenger.users WHERE LOWER(login) = LOWER($1)", from).Scan(&senderID)
	if err != nil {
		return 0, "", err
	}

	var msgID int
	var createdAt time.Time
	err = a.db.QueryRow(`
		INSERT INTO messenger.messages (conversation_id, sender_id, content, audio_data, audio_mime, audio_duration)
		VALUES ($1, $2, '', $3, $4, $5)
		RETURNING id, created_at AT TIME ZONE 'UTC'
	`, convID, senderID, audioData, mime, duration).Scan(&msgID, &createdAt)
	if err != nil {
		return 0, "", err
	}

	return msgID, createdAt.UTC().Format(time.RFC3339), nil
}

// saveCallMessage сохраняет в БД системную запись о завершённом звонке — как
// сообщение без текста, с call_type/call_status/call_duration. from — тот, кто
// ЗВОНИЛ (инициатор оригинального call-offer), не тот, кто сейчас кладёт трубку.
// duration — nil, если звонок не был отвечен (declined/missed).
func (a *App) saveCallMessage(from, to, callType, callStatus string, duration *int) (int, string, error) {
	convID, err := a.getOrCreateConversation(from, to)
	if err != nil {
		return 0, "", err
	}

	var senderID int
	err = a.db.QueryRow("SELECT id FROM messenger.users WHERE LOWER(login) = LOWER($1)", from).Scan(&senderID)
	if err != nil {
		return 0, "", err
	}

	// Отвеченный звонок не должен накручивать счётчик непрочитанных — обе
	// стороны и так только что были на связи. Непрочитанной остаётся только
	// запись о пропущенном/отклонённом звонке — ровно так это и выглядит в
	// привычных мессенджерах.
	isRead := callStatus == "answered"

	var msgID int
	var createdAt time.Time
	err = a.db.QueryRow(`
		INSERT INTO messenger.messages (conversation_id, sender_id, content, call_type, call_status, call_duration, is_read)
		VALUES ($1, $2, '', $3, $4, $5, $6)
		RETURNING id, created_at AT TIME ZONE 'UTC'
	`, convID, senderID, callType, callStatus, duration, isRead).Scan(&msgID, &createdAt)
	if err != nil {
		return 0, "", err
	}

	return msgID, createdAt.UTC().Format(time.RFC3339), nil
}

// handleUploadAudio — POST /upload-audio (multipart: file, to, duration)
// outputAudioMime — единый формат, в который приводятся все голосовые сообщения.
// AAC в MP4-контейнере воспроизводится нативно во всех браузерах и ОС, включая iOS Safari/WebKit,
// который вообще не умеет декодировать WebM (а именно его пишут по умолчанию Chrome/Firefox/Android).
const outputAudioMime = "audio/mp4"

// transcodeAudioTimeout — на случай битого/огромного входного файла, чтобы ffmpeg не повис навечно.
const transcodeAudioTimeout = 30 * time.Second

// transcodeToAAC прогоняет входящие аудиоданные (любой формат, который сумел записать браузер —
// webm/opus, ogg/opus, mp4/aac и т.д.) через ffmpeg и возвращает AAC в MP4-контейнере.
// Пишем во временный файл, а не в stdout-pipe: MP4 требует seek для записи moov-атома,
// а pipe не seekable — через файл получаем нормальный (нефрагментированный, +faststart) MP4,
// который без сюрпризов проигрывается и сразу отдаёт корректную длительность в метаданных.
func transcodeToAAC(input []byte) ([]byte, error) {
	tmpDir, err := os.MkdirTemp("", "oshino-audio-*")
	if err != nil {
		return nil, fmt.Errorf("создание временной директории: %w", err)
	}
	defer os.RemoveAll(tmpDir)

	inPath := filepath.Join(tmpDir, "in")
	outPath := filepath.Join(tmpDir, "out.m4a")

	if err := os.WriteFile(inPath, input, 0o600); err != nil {
		return nil, fmt.Errorf("запись входного файла: %w", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), transcodeAudioTimeout)
	defer cancel()

	cmd := exec.CommandContext(ctx, "ffmpeg",
		"-y",
		"-hide_banner", "-loglevel", "error",
		"-i", inPath,
		"-vn", // на случай если в контейнере вдруг есть видеодорожка/обложка — нам нужен только звук
		"-c:a", "aac",
		"-b:a", "64k",
		"-ac", "1", // голосовые — моно, экономит место без потери разборчивости речи
		"-movflags", "+faststart",
		outPath,
	)

	var stderr bytes.Buffer
	cmd.Stderr = &stderr

	if err := cmd.Run(); err != nil {
		return nil, fmt.Errorf("ffmpeg: %w: %s", err, strings.TrimSpace(stderr.String()))
	}

	out, err := os.ReadFile(outPath)
	if err != nil {
		return nil, fmt.Errorf("чтение результата транскодирования: %w", err)
	}
	return out, nil
}

func (a *App) handleUploadAudio(w http.ResponseWriter, r *http.Request) {
	login := a.getSessionLogin(r)
	if login == "" {
		http.Error(w, "Unauthorized", http.StatusUnauthorized)
		return
	}

	if r.Method != http.MethodPost {
		http.Error(w, "Метод не поддерживается", http.StatusMethodNotAllowed)
		return
	}

	r.Body = http.MaxBytesReader(w, r.Body, maxAudioSize+(1<<20))
	if err := r.ParseMultipartForm(maxAudioSize + (1 << 20)); err != nil {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusBadRequest)
		json.NewEncoder(w).Encode(map[string]string{"error": "Файл слишком большой или форма повреждена"})
		return
	}

	to := r.FormValue("to")
	if to == "" {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusBadRequest)
		json.NewEncoder(w).Encode(map[string]string{"error": "Не указан получатель"})
		return
	}

	durationSec := 0
	if d, err := strconv.Atoi(r.FormValue("duration")); err == nil && d > 0 {
		durationSec = d
	}

	file, header, err := r.FormFile("file")
	if err != nil {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusBadRequest)
		json.NewEncoder(w).Encode(map[string]string{"error": "Файл не найден"})
		return
	}
	defer file.Close()

	if header.Size > maxAudioSize {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusBadRequest)
		json.NewEncoder(w).Encode(map[string]string{"error": "Файл слишком большой (максимум 20 МБ)"})
		return
	}

	audioData, err := io.ReadAll(io.LimitReader(file, maxAudioSize+1))
	if err != nil {
		http.Error(w, "Error", http.StatusInternalServerError)
		return
	}
	if len(audioData) > maxAudioSize {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusBadRequest)
		json.NewEncoder(w).Encode(map[string]string{"error": "Файл слишком большой (максимум 20 МБ)"})
		return
	}

	// Приводим к единому формату независимо от того, что записал браузер отправителя —
	// это снимает проблему совместимости при воспроизведении на стороне получателя.
	transcoded, err := transcodeToAAC(audioData)
	if err != nil {
		log.Println("Ошибка транскодирования аудио:", err)
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusBadRequest)
		json.NewEncoder(w).Encode(map[string]string{"error": "Не удалось обработать аудиофайл"})
		return
	}

	msgID, createdAt, err := a.saveAudioMessage(login, to, transcoded, outputAudioMime, durationSec)
	if err != nil {
		log.Println("Ошибка сохранения голосового:", err)
		http.Error(w, "Error", http.StatusInternalServerError)
		return
	}

	msg := Message{
		From:          login,
		To:            to,
		CreatedAt:     createdAt,
		AudioID:       msgID,
		AudioDuration: durationSec,
	}

	a.routeMessage(msg)

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]interface{}{
		"success":        true,
		"audio_id":       msgID,
		"audio_duration": durationSec,
		"created_at":     createdAt,
	})
}

// handleGetAudio — GET /audio/<id>
func (a *App) handleGetAudio(w http.ResponseWriter, r *http.Request) {
	login := a.getSessionLogin(r)
	if login == "" {
		http.Error(w, "Unauthorized", http.StatusUnauthorized)
		return
	}

	idStr := strings.TrimPrefix(r.URL.Path, "/audio/")
	msgID, err := strconv.Atoi(idStr)
	if err != nil {
		http.Error(w, "Bad request", http.StatusBadRequest)
		return
	}

	var myID int
	err = a.db.QueryRow("SELECT id FROM messenger.users WHERE LOWER(login)=LOWER($1)", login).Scan(&myID)
	if err != nil {
		http.Error(w, "Error", http.StatusInternalServerError)
		return
	}

	var audioData []byte
	var mime string
	err = a.db.QueryRow(`
		SELECT m.audio_data, m.audio_mime
		FROM messenger.messages m
		JOIN messenger.conversations c ON c.id = m.conversation_id
		WHERE m.id = $1
		  AND m.audio_data IS NOT NULL
		  AND (c.user1_id = $2 OR c.user2_id = $2)
	`, msgID, myID).Scan(&audioData, &mime)

	if err != nil {
		http.Error(w, "Not found", http.StatusNotFound)
		return
	}

	w.Header().Set("Content-Type", mime)
	w.Header().Set("Cache-Control", "private, max-age=86400")
	// http.ServeContent сам выставит Accept-Ranges и корректно ответит 206 Partial Content
	// на Range-запросы — Safari/iOS их шлёт всегда и без этого может не воспроизводить аудио вовсе.
	http.ServeContent(w, r, "audio", time.Now(), bytes.NewReader(audioData))
}

// ── Push-уведомления (Web Push API) ─────────────────────────────────────────

// PushSubscriptionPayload — то, что присылает PushManager.subscribe() на фронте
// (стандартная форма PushSubscription.toJSON()).
type PushSubscriptionPayload struct {
	Endpoint string `json:"endpoint"`
	Keys     struct {
		P256dh string `json:"p256dh"`
		Auth   string `json:"auth"`
	} `json:"keys"`
}

// handlePushPublicKey — GET /push-public-key
// Отдаёт публичный VAPID-ключ, нужен фронтенду для PushManager.subscribe()
// (applicationServerKey). Не требует авторизации — это публичный ключ по определению.
func (a *App) handlePushPublicKey(w http.ResponseWriter, r *http.Request) {
	if a.vapidPublicKey == "" {
		http.Error(w, "Push не настроен на сервере", http.StatusServiceUnavailable)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]string{"publicKey": a.vapidPublicKey})
}

// handlePushSubscribe — POST /push-subscribe
// Сохраняет (или обновляет, если endpoint уже существует) push-подписку текущего
// пользователя. Один логин может иметь несколько подписок одновременно (разные
// устройства/браузеры) — ограничения на endpoint нет, кроме UNIQUE в БД.
func (a *App) handlePushSubscribe(w http.ResponseWriter, r *http.Request) {
	login := a.getSessionLogin(r)
	if login == "" {
		http.Error(w, "Unauthorized", http.StatusUnauthorized)
		return
	}
	if r.Method != http.MethodPost {
		http.Error(w, "Метод не поддерживается", http.StatusMethodNotAllowed)
		return
	}

	var sub PushSubscriptionPayload
	if err := json.NewDecoder(r.Body).Decode(&sub); err != nil {
		http.Error(w, "Некорректное тело запроса", http.StatusBadRequest)
		return
	}
	if sub.Endpoint == "" || sub.Keys.P256dh == "" || sub.Keys.Auth == "" {
		http.Error(w, "Неполная подписка", http.StatusBadRequest)
		return
	}

	var userID int
	if err := a.db.QueryRow("SELECT id FROM messenger.users WHERE LOWER(login)=LOWER($1)", login).Scan(&userID); err != nil {
		http.Error(w, "Error", http.StatusInternalServerError)
		return
	}

	_, err := a.db.Exec(`
		INSERT INTO messenger.push_subscriptions (user_id, endpoint, p256dh, auth)
		VALUES ($1, $2, $3, $4)
		ON CONFLICT (endpoint) DO UPDATE
		SET user_id = EXCLUDED.user_id, p256dh = EXCLUDED.p256dh, auth = EXCLUDED.auth
	`, userID, sub.Endpoint, sub.Keys.P256dh, sub.Keys.Auth)
	if err != nil {
		log.Println("Ошибка сохранения push-подписки:", err)
		http.Error(w, "Error", http.StatusInternalServerError)
		return
	}

	w.WriteHeader(http.StatusOK)
}

// handlePushUnsubscribe — POST /push-unsubscribe
// Удаляет подписку по endpoint (вызывается при PushManager.unsubscribe() на фронте,
// например когда пользователь явно выключает уведомления в браузере).
func (a *App) handlePushUnsubscribe(w http.ResponseWriter, r *http.Request) {
	login := a.getSessionLogin(r)
	if login == "" {
		http.Error(w, "Unauthorized", http.StatusUnauthorized)
		return
	}
	if r.Method != http.MethodPost {
		http.Error(w, "Метод не поддерживается", http.StatusMethodNotAllowed)
		return
	}

	var body struct {
		Endpoint string `json:"endpoint"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil || body.Endpoint == "" {
		http.Error(w, "Некорректное тело запроса", http.StatusBadRequest)
		return
	}

	_, err := a.db.Exec("DELETE FROM messenger.push_subscriptions WHERE endpoint = $1", body.Endpoint)
	if err != nil {
		http.Error(w, "Error", http.StatusInternalServerError)
		return
	}

	w.WriteHeader(http.StatusOK)
}

// pushNotificationPayload — JSON, который попадёт в event.data внутри Service Worker
// (sw.js его парсит и решает, какой заголовок/текст/действие показать).
type pushNotificationPayload struct {
	Type  string `json:"type"`            // "call" | "message"
	From  string `json:"from"`
	Title string `json:"title"`
	Body  string `json:"body"`
	CallID string `json:"call_id,omitempty"`
}

// sendPushToLogin отправляет push-уведомление на ВСЕ сохранённые подписки логина.
// Используется только когда получатель полностью оффлайн (ни одного активного WS) —
// если есть хоть одно живое соединение, доставка идёт через routeMessage/routeCallSignal,
// и дублирующий push был бы просто шумом поверх уже работающего realtime-уведомления.
//
// Мёртвые подписки (410 Gone / 404 Not Found от push-службы — браузер отписался или
// подписка истекла) удаляются из БД сразу же, чтобы не пытаться слать в пустоту вечно.
func (a *App) sendPushToLogin(login string, payload pushNotificationPayload) {
	if a.vapidPublicKey == "" || a.vapidPrivateKey == "" {
		return
	}

	var userID int
	if err := a.db.QueryRow("SELECT id FROM messenger.users WHERE LOWER(login)=LOWER($1)", login).Scan(&userID); err != nil {
		return
	}

	rows, err := a.db.Query("SELECT id, endpoint, p256dh, auth FROM messenger.push_subscriptions WHERE user_id = $1", userID)
	if err != nil {
		log.Println("Ошибка чтения push-подписок:", err)
		return
	}
	defer rows.Close()

	type subRow struct {
		id                 int
		endpoint, p256, au string
	}
	var subs []subRow
	for rows.Next() {
		var s subRow
		if err := rows.Scan(&s.id, &s.endpoint, &s.p256, &s.au); err == nil {
			subs = append(subs, s)
		}
	}

	data, _ := json.Marshal(payload)

	// webpush-go сам добавляет префикс "mailto:" к Subscriber, если значение не
	// похоже на URL (https://...) — то есть передавать его нужно БЕЗ префикса.
	// a.vapidContact хранится в формате "mailto:admin@oshino.space" (так удобнее
	// в конфиге/логах), поэтому здесь его убираем. Раньше из-за этого в JWT
	// получался двойной префикс "mailto:mailto:admin@oshino.space" — именно это
	// и было причиной 403 BadJwtToken от Apple (FCM на такой невалидный sub-claim
	// просто не обращал внимания, а строгий валидатор Apple — отклонял).
	subscriber := strings.TrimPrefix(a.vapidContact, "mailto:")

	for _, s := range subs {
		opts := &webpush.Options{
			Subscriber:      subscriber,
			VAPIDPublicKey:  a.vapidPublicKey,
			VAPIDPrivateKey: a.vapidPrivateKey,
			TTL:             60,
		}
		// Apple Web Push (web.push.apple.com) принимает только VAPID auth scheme
		// "WebPush" — дефолтная "vapid" у этой библиотеки Apple не устраивает.
		if strings.Contains(s.endpoint, "web.push.apple.com") {
			opts.AuthScheme = webpush.WebPush
		}

		resp, err := webpush.SendNotification(data, &webpush.Subscription{
			Endpoint: s.endpoint,
			Keys:     webpush.Keys{P256dh: s.p256, Auth: s.au},
		}, opts)
		if err != nil {
			log.Println("Ошибка отправки push:", err)
			continue
		}

		// Любой статус вне диапазона 2xx логируем с телом ответа — раньше мы тихо
		// игнорировали, например, 400/403 (некорректный VAPID, отозванная подписка
		// и т.п.), и причина отказа просто терялась без следа в логах.
		if resp.StatusCode < 200 || resp.StatusCode >= 300 {
			body, _ := io.ReadAll(resp.Body)
			log.Printf("Push не доставлен (subscription id=%d, endpoint=%s): статус %d, ответ: %s",
				s.id, s.endpoint, resp.StatusCode, strings.TrimSpace(string(body)))
		}
		resp.Body.Close()

		if resp.StatusCode == http.StatusGone || resp.StatusCode == http.StatusNotFound {
			a.db.Exec("DELETE FROM messenger.push_subscriptions WHERE id = $1", s.id)
		}
	}
}

// isLoginOnline — true, если у логина сейчас есть хотя бы одно активное WS-соединение.
func (a *App) isLoginOnline(login string) bool {
	a.mu.Lock()
	defer a.mu.Unlock()
	conns, ok := a.clients[strings.ToLower(login)]
	return ok && len(conns) > 0
}

// turnCredentialsTTL — срок жизни сгенерированных TURN credentials.
// Час с запасом перекрывает любой разумный голосовой звонок; даже если он
// затянется, ICE-сессия, однажды установленная, не обрывается по истечении
// TTL — credentials проверяются только в момент TURN allocate.
const turnCredentialsTTL = 1 * time.Hour

// generateTurnCredentials генерирует time-limited username/password по схеме
// TURN REST API (см. coturn use-auth-secret): username = "<unix_ts>:<login>",
// password = base64(HMAC-SHA1(secret, username)). Алгоритм должен совпадать
// побитово с тем, что использует coturn (static-auth-secret в turnserver.conf).
func generateTurnCredentials(secret, login string) (username, password string, ttl int64) {
	expiry := time.Now().Add(turnCredentialsTTL).Unix()
	username = fmt.Sprintf("%d:%s", expiry, login)

	mac := hmac.New(sha1.New, []byte(secret))
	mac.Write([]byte(username))
	password = base64.StdEncoding.EncodeToString(mac.Sum(nil))

	return username, password, expiry
}

// handleTurnCredentials — GET /turn-credentials
// Отдаёт залогиненному пользователю свежие TURN-credentials и адреса STUN/TURN.
// Секрет (turnSecret) на клиент не уходит никогда — только производный HMAC.
func (a *App) handleTurnCredentials(w http.ResponseWriter, r *http.Request) {
	login := a.getSessionLogin(r)
	if login == "" {
		http.Error(w, "Unauthorized", http.StatusUnauthorized)
		return
	}

	if a.turnSecret == "" {
		http.Error(w, "TURN не настроен на сервере", http.StatusServiceUnavailable)
		return
	}

	username, password, expiry := generateTurnCredentials(a.turnSecret, login)

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]interface{}{
		"username": username,
		"password": password,
		"ttl":      expiry,
		"urls": []string{
			"stun:oshino.space:3478",
			"turn:oshino.space:3478?transport=udp",
			"turn:oshino.space:3478?transport=tcp",
		},
	})
}

func (c *Client) readPump(a *App) {
	defer func() {
		a.mu.Lock()
		if conns, ok := a.clients[c.login]; ok {
			delete(conns, c)
			if len(conns) == 0 {
				delete(a.clients, c.login)
			}
		}
		a.mu.Unlock()
		close(c.done)
		c.conn.Close()
		fmt.Printf("%s отключился\n", c.login)
		a.broadcastOnlineUsers()
	}()

	for {
		_, message, err := c.conn.ReadMessage()
		if err != nil {
			break
		}

		msgStr := string(message)

		if msgStr == "getdialogs" {
			a.sendDialogsTo(c)
		} else if len(msgStr) > 4 && msgStr[:4] == "msg:" {
			var msg Message
			json.Unmarshal([]byte(msgStr[4:]), &msg)
			// Сохраняем в БД и получаем точное время отправки
			createdAt, err := a.saveMessage(msg.From, msg.To, msg.Text)
			if err != nil {
				log.Println("Ошибка сохранения сообщения:", err)
			}
			msg.CreatedAt = createdAt
			a.routeMessage(msg)
		} else if prefix, rest, ok := cutCallPrefix(msgStr); ok {
			var sig CallSignal
			if err := json.Unmarshal([]byte(rest), &sig); err != nil {
				log.Println("Ошибка разбора call-сигнала:", err)
				continue
			}
			sig.Type = prefix
			sig.From = c.login // не доверяем from от клиента, берём из сессии
			a.routeCallSignal(sig, c)
		}
	}
}

func (c *Client) writePump() {
	for {
		select {
		case msg, ok := <-c.send:
			if !ok {
				return
			}
			if err := c.conn.WriteMessage(websocket.TextMessage, msg); err != nil {
				return
			}
		case <-c.done:
			return
		}
	}
}

// trySend — неблокирующая отправка. Если канал устройства переполнен (клиент завис/отвалился),
// сообщение не доставляется именно этому устройству, но не блокирует рассылку остальным.
func (c *Client) trySend(payload []byte) {
	select {
	case c.send <- payload:
	default:
		log.Printf("очередь отправки переполнена для %s, сообщение пропущено", c.login)
	}
}

// sendDialogsTo отправляет клиенту актуальный список диалогов, прочитанный из БД
// (источник истины один на все устройства логина, рассинхрон между девайсами исключён).
func (a *App) sendDialogsTo(c *Client) {
	dialogs, err := a.loadDialogsFromDB(c.login)
	if err != nil {
		log.Println("Ошибка загрузки диалогов:", err)
	}

	set := make(map[string]bool, len(dialogs)+1)
	for _, d := range dialogs {
		set[d] = true
	}

	if a.defaultContact != "" && !strings.EqualFold(a.defaultContact, c.login) {
		set[a.defaultContact] = true
	}

	userList := "["
	first := true
	for user := range set {
		if !first {
			userList += ","
		}
		userList += "\"" + user + "\""
		first = false
	}
	userList += "]"

	c.trySend([]byte("dialogs:" + userList))
}

// deliverRealtime — общая часть доставки: рассылает payload на все активные
// устройства логина-получателя и логина-отправителя (мультидевайс), обновляет
// список диалогов на затронутых устройствах. Возвращает true, если у
// получателя не было ни одного активного устройства — вызывающий код сам
// решает, нужен ли в этом случае push (для звонков он, как правило, уже был
// отправлен раньше через сигналинг, и слать его второй раз тут не нужно).
func (a *App) deliverRealtime(msg Message) (recipientOffline bool) {
	toLogin := strings.ToLower(msg.To)
	fromLogin := strings.ToLower(msg.From)

	data, _ := json.Marshal(msg)
	payload := append([]byte("msg:"), data...)
	ackPayload := append([]byte("msgack:"), data...)

	a.mu.Lock()
	recipients := make([]*Client, 0, len(a.clients[toLogin]))
	for c := range a.clients[toLogin] {
		recipients = append(recipients, c)
	}
	senders := make([]*Client, 0, len(a.clients[fromLogin]))
	for c := range a.clients[fromLogin] {
		senders = append(senders, c)
	}
	a.mu.Unlock()

	// Получателю — само сообщение на все его устройства
	for _, c := range recipients {
		c.trySend(payload)
		a.sendDialogsTo(c)
	}
	// Отправителю — подтверждение с реальным временем из БД на все его устройства
	for _, c := range senders {
		c.trySend(ackPayload)
		a.sendDialogsTo(c)
	}

	return len(recipients) == 0
}

// routeMessage рассылает обычное сообщение (текст/картинка/голосовое) и, если
// получатель полностью оффлайн, отправляет push вместо realtime-доставки.
func (a *App) routeMessage(msg Message) {
	if a.deliverRealtime(msg) {
		body := msg.Text
		switch {
		case msg.ImageID != 0:
			body = "📷 Фото"
		case msg.AudioID != 0:
			body = "🎤 Голосовое сообщение"
		case body == "":
			body = "Новое сообщение"
		}
		go a.sendPushToLogin(msg.To, pushNotificationPayload{
			Type:  "message",
			From:  msg.From,
			Title: msg.From,
			Body:  body,
		})
	}
}

// deliverCallLogMessage доставляет системную запись о звонке в реальном
// времени — без push: звонок уже либо состоялся при том, что обе стороны были
// на связи, либо push по нему уже отправлен через сигналинг звонка
// (storePendingCall на call-offer / expirePendingCall по таймауту) — повторный
// push здесь был бы просто дублирующим шумом поверх уже доставленного.
func (a *App) deliverCallLogMessage(msg Message) {
	a.deliverRealtime(msg)
}

// callPrefixes — допустимые префиксы WS-сообщений сигналинга звонков.
// Порядок не важен, но "call-" префикс у всех общий — сверяем целиком, чтобы
// не путать с "call-answer:" внутри "call-answer-foo:" и т.п.
var callPrefixes = []string{"call-offer:", "call-answer:", "call-ice:", "call-end:", "call-reject:", "call-video-on:", "call-video-on-answer:", "call-video-disabled:", "call-video-enabled:"}

// cutCallPrefix проверяет, начинается ли сообщение с одного из call-префиксов,
// и если да — возвращает префикс без двоеточия и остаток (JSON-тело).
func cutCallPrefix(msgStr string) (prefix string, rest string, ok bool) {
	for _, p := range callPrefixes {
		if strings.HasPrefix(msgStr, p) {
			return strings.TrimSuffix(p, ":"), msgStr[len(p):], true
		}
	}
	return "", "", false
}

// callRingTimeout — сколько ждать ответа от изначально оффлайн-получателя,
// прежде чем считать звонок пропущенным и сообщить об этом звонящему.
// Покрывает время на доставку push + открытие вкладки человеком.
const callRingTimeout = 45 * time.Second

// storePendingCall буферизует call-offer для оффлайн-получателя и запускает
// таймер автоматического "не отвечает". Если для этого логина уже была
// отложенная попытка (едва ли возможно на практике, но на всякий случай —
// например, повторный звонок до истечения предыдущего таймаута), старый
// таймер останавливается, чтобы не было утечки и дублирующего авто-отбоя.
func (a *App) storePendingCall(recipientLogin string, sig CallSignal) {
	a.callMu.Lock()
	defer a.callMu.Unlock()

	if old, ok := a.pendingCalls[recipientLogin]; ok && old.Timer != nil {
		old.Timer.Stop()
	}

	pc := &PendingCall{Sig: sig}
	pc.Timer = time.AfterFunc(callRingTimeout, func() {
		a.expirePendingCall(recipientLogin, sig.CallID)
	})
	a.pendingCalls[recipientLogin] = pc
}

// clearPendingCall убирает отложенный звонок (и останавливает его таймер),
// если он всё ещё там и относится к тому же call_id — звонок разрешился
// (ответили/отклонили/положили трубку) раньше, чем сработал таймаут.
func (a *App) clearPendingCall(recipientLogin, callID string) {
	a.callMu.Lock()
	defer a.callMu.Unlock()

	pc, ok := a.pendingCalls[recipientLogin]
	if !ok || pc.Sig.CallID != callID {
		return
	}
	if pc.Timer != nil {
		pc.Timer.Stop()
	}
	delete(a.pendingCalls, recipientLogin)
}

// expirePendingCall срабатывает по истечении callRingTimeout: удаляет буфер
// и сообщает звонящему, что вызов не был принят (reason "no-answer").
func (a *App) expirePendingCall(recipientLogin, callID string) {
	a.callMu.Lock()
	pc, ok := a.pendingCalls[recipientLogin]
	if !ok || pc.Sig.CallID != callID {
		a.callMu.Unlock()
		return
	}
	delete(a.pendingCalls, recipientLogin)
	a.callMu.Unlock()

	noAnswer := CallSignal{
		Type:   "call-end",
		From:   recipientLogin,
		To:     pc.Sig.From,
		CallID: callID,
		Reason: "no-answer",
	}
	data, _ := json.Marshal(noAnswer)
	payload := append([]byte("call-end:"), data...)

	callerLogin := strings.ToLower(pc.Sig.From)
	a.mu.Lock()
	conns := a.clients[callerLogin]
	callerClients := make([]*Client, 0, len(conns))
	for c := range conns {
		callerClients = append(callerClients, c)
	}
	a.mu.Unlock()

	for _, c := range callerClients {
		c.trySend(payload)
	}

	a.finishCallLog(callID, "timeout")
}

// finishCallLog читает и удаляет состояние звонка из activeCalls и, если оно
// найдено, сохраняет и доставляет системную запись о его исходе (отвечен —
// с длительностью, отклонён или пропущен). Безопасно вызывать с одним и тем же
// callID повторно — вторая попытка просто не найдёт запись и ничего не сделает,
// благодаря этому не нужно отдельно следить, кто из путей завершения звонка
// сработал первым.
func (a *App) finishCallLog(callID, outcomeReason string) {
	a.callMu.Lock()
	ac, ok := a.activeCalls[callID]
	if ok {
		delete(a.activeCalls, callID)
	}
	a.callMu.Unlock()
	if !ok {
		return
	}

	callType := "audio"
	if ac.video {
		callType = "video"
	}

	var status string
	var duration *int
	if ac.answeredAt != nil {
		status = "answered"
		d := int(time.Since(*ac.answeredAt).Seconds())
		if d < 0 {
			d = 0
		}
		duration = &d
	} else if outcomeReason == "reject" {
		status = "declined"
	} else {
		status = "missed"
	}

	msgID, createdAt, err := a.saveCallMessage(ac.from, ac.to, callType, status, duration)
	if err != nil {
		log.Println("Ошибка сохранения записи о звонке:", err)
		return
	}

	a.deliverCallLogMessage(Message{
		From:         ac.from,
		To:           ac.to,
		CreatedAt:    createdAt,
		CallMsgID:    msgID,
		CallType:     callType,
		CallStatus:   status,
		CallDuration: duration,
	})
}

// deliverPendingCallIfAny проверяет, нет ли для только что подключившегося
// клиента отложенного входящего звонка (т.е. ему звонили, пока он был
// полностью оффлайн), и если есть — доставляет его, как будто offer
// только что пришёл. Буфер НЕ удаляется здесь: если у логина несколько
// устройств, каждое должно увидеть входящий звонок при подключении;
// удаление произойдёт по answer/reject/end или по таймауту.
func (a *App) deliverPendingCallIfAny(c *Client) {
	a.callMu.Lock()
	pc, ok := a.pendingCalls[c.login]
	a.callMu.Unlock()
	if !ok {
		return
	}

	data, _ := json.Marshal(pc.Sig)
	payload := append([]byte("call-offer:"), data...)
	c.trySend(payload)
}

// routeCallSignal пересылает сигнал звонка на все устройства получателя.
// Дополнительно: call-answer/call-reject рассылаются и на ОСТАЛЬНЫЕ устройства
// отправителя (кроме того, с которого пришёл сигнал) с пометкой "answered-elsewhere",
// чтобы при мультидевайсе входящий звонок погас на всех экранах, кроме ответившего.
func (a *App) routeCallSignal(sig CallSignal, from *Client) {
	toLogin := strings.ToLower(sig.To)

	data, _ := json.Marshal(sig)
	payload := append([]byte(sig.Type+":"), data...)

	a.mu.Lock()
	recipients := make([]*Client, 0, len(a.clients[toLogin]))
	for c := range a.clients[toLogin] {
		recipients = append(recipients, c)
	}
	var siblings []*Client
	if conns, ok := a.clients[from.login]; ok {
		siblings = make([]*Client, 0, len(conns))
		for c := range conns {
			if c != from {
				siblings = append(siblings, c)
			}
		}
	}
	a.mu.Unlock()

	for _, c := range recipients {
		c.trySend(payload)
	}

	// Заводим/обновляем состояние звонка для последующего логирования (см.
	// activeCallInfo и finishCallLog) — независимо от того, онлайн получатель
	// или нет, в отличие от pendingCalls/push ниже, которые касаются только
	// доставки самого сигнала оффлайн-получателю.
	switch sig.Type {
	case "call-offer":
		a.callMu.Lock()
		a.activeCalls[sig.CallID] = &activeCallInfo{
			from:  strings.ToLower(sig.From),
			to:    toLogin,
			video: sig.Video,
		}
		a.callMu.Unlock()
	case "call-answer":
		a.callMu.Lock()
		if ac, ok := a.activeCalls[sig.CallID]; ok {
			now := time.Now()
			ac.answeredAt = &now
		}
		a.callMu.Unlock()
	}

	// Получатель оффлайн — на входящий звонок шлём push и буферизуем сам сигнал
	// (pendingCalls), чтобы доставить его, как только получатель откроет приложение
	// по уведомлению — иначе offer будет потерян безвозвратно, а push без содержимого
	// звонка бесполезен. Для остальных типов сигналов (answer/ice/end/reject) push
	// не нужен: они имеют смысл только в рамках уже идущего разговора.
	if sig.Type == "call-offer" && len(recipients) == 0 {
		a.storePendingCall(toLogin, sig)
		callBody := "Входящий звонок"
		if sig.Video {
			callBody = "Видеозвонок"
		}
		go a.sendPushToLogin(sig.To, pushNotificationPayload{
			Type:   "call",
			From:   sig.From,
			Title:  sig.From,
			Body:   callBody,
			CallID: sig.CallID,
		})
	}

	// Звонок разрешился тем или иным образом — буфер больше не нужен.
	// call-answer/call-reject шлёт ОТВЕЧАЮЩИЙ (sig.From — это получатель звонка,
	// тот, под чьим логином мог быть сохранён pendingCall). call-end может прийти
	// от любой из сторон, поэтому чистим по обоим возможным ключам на всякий случай.
	switch sig.Type {
	case "call-answer", "call-reject":
		a.clearPendingCall(strings.ToLower(sig.From), sig.CallID)
	case "call-end":
		a.clearPendingCall(toLogin, sig.CallID)
		a.clearPendingCall(strings.ToLower(sig.From), sig.CallID)
	}

	// Звонок разрешился окончательно (отклонён или завершён) — пишем системную
	// запись в чат. call-answer сюда не попадает: ответ ещё не конец звонка,
	// запись делается по его фактическому завершению (call-end), чтобы знать
	// длительность.
	switch sig.Type {
	case "call-reject":
		a.finishCallLog(sig.CallID, "reject")
	case "call-end":
		a.finishCallLog(sig.CallID, "end")
	}

	if sig.Type == "call-answer" || sig.Type == "call-reject" || sig.Type == "call-end" {
		elsewhere := sig
		elsewhere.Reason = "answered-elsewhere"
		elsewhereData, _ := json.Marshal(elsewhere)
		elsewherePayload := append([]byte("call-end:"), elsewhereData...)
		for _, c := range siblings {
			c.trySend(elsewherePayload)
		}
	}
}

func (a *App) handleLogout(w http.ResponseWriter, r *http.Request) {
	cookie, err := r.Cookie("session")
	if err == nil {
		a.mu.Lock()
		delete(a.sessions, cookie.Value)
		a.mu.Unlock()
	}

	http.SetCookie(w, &http.Cookie{
		Name:   "session",
		Value:  "",
		MaxAge: -1,
		Path:   "/",
	})

	http.Redirect(w, r, "/", http.StatusSeeOther)
}

func (a *App) handleMarkRead(w http.ResponseWriter, r *http.Request) {
	login := a.getSessionLogin(r)
	if login == "" {
		http.Error(w, "Unauthorized", http.StatusUnauthorized)
		return
	}

	withUser := r.URL.Query().Get("with")
	if withUser == "" {
		http.Error(w, "missing with", http.StatusBadRequest)
		return
	}

	convID, err := a.getOrCreateConversation(login, withUser)
	if err != nil {
		http.Error(w, "Error", http.StatusInternalServerError)
		return
	}

	var myID int
	err = a.db.QueryRow(
		"SELECT id FROM messenger.users WHERE LOWER(login)=LOWER($1)",
		login,
	).Scan(&myID)

	if err != nil {
		http.Error(w, "Error", http.StatusInternalServerError)
		return
	}

	_, err = a.db.Exec(`
		UPDATE messenger.messages
		SET is_read = TRUE
		WHERE conversation_id = $1
		  AND sender_id <> $2
		  AND is_read = FALSE
	`, convID, myID)

	if err != nil {
		http.Error(w, "Error", http.StatusInternalServerError)
		return
	}

	w.WriteHeader(http.StatusOK)
}

func (a *App) handleUnreadCounts(w http.ResponseWriter, r *http.Request) {
	login := a.getSessionLogin(r)
	if login == "" {
		http.Error(w, "Unauthorized", http.StatusUnauthorized)
		return
	}

	var myID int
	err := a.db.QueryRow(
		"SELECT id FROM messenger.users WHERE LOWER(login)=LOWER($1)",
		login,
	).Scan(&myID)

	if err != nil {
		http.Error(w, "Error", http.StatusInternalServerError)
		return
	}

	rows, err := a.db.Query(`
		SELECT u.login, COUNT(*)
		FROM messenger.messages m
		JOIN messenger.conversations c ON c.id = m.conversation_id
		JOIN messenger.users u ON u.id = m.sender_id
		WHERE m.is_read = FALSE
		  AND m.sender_id <> $1
		  AND (c.user1_id = $1 OR c.user2_id = $1)
		GROUP BY u.login
	`, myID)

	if err != nil {
		http.Error(w, "Error", http.StatusInternalServerError)
		return
	}
	defer rows.Close()

	result := map[string]int{}

	for rows.Next() {
		var login string
		var count int
		rows.Scan(&login, &count)
		result[login] = count
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(result)
}
