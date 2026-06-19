package main

import (
	"crypto/rand"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/gorilla/websocket"
	"github.com/joho/godotenv"
	_ "github.com/lib/pq"
	"golang.org/x/crypto/bcrypt"
)

type App struct {
	db       *sql.DB
	sessions map[string]Session
	mu       sync.Mutex
	clients  map[string]*Client
}

type Session struct {
	login   string
	expires time.Time
}

type Client struct {
	login   string
	conn    *websocket.Conn
	send    chan []byte
	dialogs map[string]bool
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
}

type HistoryMessage struct {
	From string `json:"from"`
	To   string `json:"to"`
	Text string `json:"text"`
	Own  bool   `json:"own"`
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

var allowedAudioMimes = map[string]bool{
	"audio/webm":  true,
	"audio/ogg":   true,
	"audio/mpeg":  true,
	"audio/mp4":   true,
	"audio/wav":   true,
	"audio/x-wav": true,
}

func generateToken() string {
	bytes := make([]byte, 16)
	rand.Read(bytes)
	return hex.EncodeToString(bytes)
}

func main() {
	fmt.Println("Oshino запускается...")

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
		db:       db,
		sessions: make(map[string]Session),
		clients:  make(map[string]*Client),
	}

	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		http.ServeFile(w, r, "static/index.html")
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
		login:   login,
		conn:    conn,
		send:    make(chan []byte, 256),
		dialogs: make(map[string]bool),
	}

	// Загружаем диалоги из БД
	dialogs, err := a.loadDialogsFromDB(login)
	if err != nil {
		log.Println("Ошибка загрузки диалогов:", err)
	}
	for _, d := range dialogs {
		client.dialogs[d] = true
	}

	// Контакт по умолчанию (пользователь с id=1)
	var defaultContactLogin string
	a.db.QueryRow("SELECT login FROM messenger.users WHERE id = 1").Scan(&defaultContactLogin)

	var currentUserID int
	a.db.QueryRow("SELECT id FROM messenger.users WHERE LOWER(login) = LOWER($1)", login).Scan(&currentUserID)

	if currentUserID != 1 && defaultContactLogin != "" {
		client.dialogs[defaultContactLogin] = true
	}

	a.mu.Lock()
	// Если уже есть старое соединение — закрываем его
	if old, ok := a.clients[login]; ok {
		close(old.send)
	}
	a.clients[login] = client
	a.mu.Unlock()

	fmt.Printf("%s подключился\n", login)

	client.send <- []byte("user:" + login)
	a.broadcastOnlineUsers()

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
			       (m.audio_data IS NOT NULL) AS has_audio, m.audio_duration
			FROM (
				SELECT id, sender_id, content, created_at, image_mime, image_filename, image_data,
				       audio_data, audio_duration
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
			       (m.audio_data IS NOT NULL) AS has_audio, m.audio_duration
			FROM (
				SELECT id, sender_id, content, created_at, image_mime, image_filename, image_data,
				       audio_data, audio_duration
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
	}

	var messages []HistMsg
	for rows.Next() {
		var m HistMsg
		var createdAt time.Time
		var imageMime, imageFilename sql.NullString
		var hasImage, hasAudio bool
		var audioDuration sql.NullInt64
		rows.Scan(&m.ID, &m.From, &m.Text, &createdAt,
			&imageMime, &imageFilename, &hasImage,
			&hasAudio, &audioDuration)
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
	defer a.mu.Unlock()

	onlineList := "["
	first := true
	for login := range a.clients {
		if !first {
			onlineList += ","
		}
		onlineList += "\"" + login + "\""
		first = false
	}
	onlineList += "]"

	for _, client := range a.clients {
		client.send <- []byte("online:" + onlineList)
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

	a.mu.Lock()
	if client, ok := a.clients[login]; ok {
		client.dialogs[to] = true
	}
	a.mu.Unlock()

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

// handleUploadAudio — POST /upload-audio (multipart: file, to, duration)
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

	// Определяем MIME по заголовку Content-Type файла (у аудио http.DetectContentType ненадёжен)
	mimeType := header.Header.Get("Content-Type")
	if mimeType == "" {
		mimeType = "audio/webm"
	}
	// Нормализуем — убираем параметры вроде codecs=...
	if idx := strings.Index(mimeType, ";"); idx != -1 {
		mimeType = strings.TrimSpace(mimeType[:idx])
	}
	if !allowedAudioMimes[mimeType] {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusBadRequest)
		json.NewEncoder(w).Encode(map[string]string{"error": "Недопустимый формат аудио"})
		return
	}

	msgID, createdAt, err := a.saveAudioMessage(login, to, audioData, mimeType, durationSec)
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

	a.mu.Lock()
	if client, ok := a.clients[login]; ok {
		client.dialogs[to] = true
	}
	a.mu.Unlock()

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
	w.Header().Set("Accept-Ranges", "bytes")
	w.Write(audioData)
}

func (c *Client) readPump(a *App) {
	defer func() {
		a.mu.Lock()
		// Удаляем только если это именно наш клиент
		if a.clients[c.login] == c {
			delete(a.clients, c.login)
		}
		a.mu.Unlock()
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
			c.sendDialogs()
		} else if len(msgStr) > 4 && msgStr[:4] == "msg:" {
			var msg Message
			json.Unmarshal([]byte(msgStr[4:]), &msg)
			// Сохраняем в БД и получаем точное время отправки
			createdAt, err := a.saveMessage(msg.From, msg.To, msg.Text)
			if err != nil {
				log.Println("Ошибка сохранения сообщения:", err)
			}
			msg.CreatedAt = createdAt
			// Добавляем диалог отправителю
			c.dialogs[msg.To] = true
			a.routeMessage(msg)
		}
	}
}

func (c *Client) writePump() {
	defer func() {
		// канал может быть уже закрыт при переподключении
		recover()
	}()
	for msg := range c.send {
		if err := c.conn.WriteMessage(websocket.TextMessage, msg); err != nil {
			break
		}
	}
}

func (c *Client) sendDialogs() {
	userList := "["
	first := true
	for user := range c.dialogs {
		if first {
			userList += "\""
		} else {
			userList += ",\""
		}
		userList += user + "\""
		first = false
	}
	userList += "]"

	c.send <- []byte("dialogs:" + userList)
}

func (a *App) routeMessage(msg Message) {
	// Отправляем получателю (если онлайн)
	a.mu.Lock()
	recipient, recipientOnline := a.clients[msg.To]
	sender, senderOnline := a.clients[msg.From]
	a.mu.Unlock()

	data, _ := json.Marshal(msg)
	payload := append([]byte("msg:"), data...)
	ackPayload := append([]byte("msgack:"), data...)

	if recipientOnline {
		// Добавляем диалог получателю в памяти
		recipient.dialogs[msg.From] = true
		recipient.send <- payload
		recipient.sendDialogs()
	}
	// Подтверждение отправителю с реальным временем из БД
	if senderOnline {
		sender.send <- ackPayload
		sender.sendDialogs()
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
