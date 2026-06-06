package main

import (
	"crypto/rand"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"strings"
	"sync"

	"github.com/gorilla/websocket"
	"github.com/joho/godotenv"
	_ "github.com/lib/pq"
	"golang.org/x/crypto/bcrypt"
)

type App struct {
	db       *sql.DB
	sessions map[string]string
	mu       sync.Mutex
	clients  map[string]*Client
}

type Client struct {
	login   string
	conn    *websocket.Conn
	send    chan []byte
	dialogs map[string]bool
}

type Message struct {
	From string `json:"from"`
	To   string `json:"to"`
	Text string `json:"text"`
}

var upgrader = websocket.Upgrader{
	CheckOrigin: func(r *http.Request) bool { return true },
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
		"host=%s port=%s dbname=%s user=%s password=%s sslmode=disable",
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
		sessions: make(map[string]string),
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

	fmt.Println("Сервер слушает порт 8080...")
	http.ListenAndServe(":8080", nil)
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

	a.mu.Lock()
	a.sessions[token] = login
	a.mu.Unlock()

	http.SetCookie(w, &http.Cookie{
		Name:     "session",
		Value:    token,
		HttpOnly: true,
	})

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]string{"success": "ok"})
}

func (a *App) handleChat(w http.ResponseWriter, r *http.Request) {
	cookie, err := r.Cookie("session")
	if err != nil {
		http.Redirect(w, r, "/", http.StatusSeeOther)
		return
	}

	a.mu.Lock()
	_, ok := a.sessions[cookie.Value]
	a.mu.Unlock()

	if !ok {
		http.Redirect(w, r, "/", http.StatusSeeOther)
		return
	}

	http.ServeFile(w, r, "static/chat.html")
}

func (a *App) handleWS(w http.ResponseWriter, r *http.Request) {
	cookie, err := r.Cookie("session")
	if err != nil {
		http.Error(w, "Unauthorized", http.StatusUnauthorized)
		return
	}

	a.mu.Lock()
	login, ok := a.sessions[cookie.Value]
	a.mu.Unlock()

	if !ok {
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

	// Получаем логин пользователя с id=1
	var defaultContactLogin string
	a.db.QueryRow("SELECT login FROM messenger.users WHERE id = 1").Scan(&defaultContactLogin)

	// Если текущий пользователь не id=1, добавляем контакт по умолчанию
	var currentUserID int
	a.db.QueryRow("SELECT id FROM messenger.users WHERE LOWER(login) = LOWER($1)", login).Scan(&currentUserID)

	if currentUserID != 1 && defaultContactLogin != "" {
		client.dialogs[defaultContactLogin] = true
	}

	a.mu.Lock()
	a.clients[login] = client
	a.mu.Unlock()

	fmt.Printf("%s подключился\n", login)

	client.send <- []byte("user:" + login)
	a.broadcastOnlineUsers()

	go client.readPump(a)
	go client.writePump()
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
	cookie, err := r.Cookie("session")
	if err != nil {
		http.Error(w, "Unauthorized", http.StatusUnauthorized)
		return
	}

	a.mu.Lock()
	_, ok := a.sessions[cookie.Value]
	a.mu.Unlock()

	if !ok {
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
		var login string
		rows.Scan(&login)
		results = append(results, login)
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(results)
}

func (c *Client) readPump(a *App) {
	defer func() {
		a.mu.Lock()
		delete(a.clients, c.login)
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
			a.routeMessage(msg)
		}
	}
}

func (c *Client) writePump() {
	for msg := range c.send {
		c.conn.WriteMessage(websocket.TextMessage, msg)
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

func (c *Client) addDialog(user string) {
	c.dialogs[user] = true
	c.sendDialogs()
}

func (a *App) routeMessage(msg Message) {
	a.mu.Lock()
	recipient, ok := a.clients[msg.To]
	a.mu.Unlock()

	if !ok {
		return
	}

	data, _ := json.Marshal(msg)
	recipient.send <- append([]byte("msg:"), data...)
}

func (a *App) handleLogout(w http.ResponseWriter, r *http.Request) {
	cookie, err := r.Cookie("session")
	if err != nil {
		http.Redirect(w, r, "/", http.StatusSeeOther)
		return
	}

	a.mu.Lock()
	delete(a.sessions, cookie.Value)
	a.mu.Unlock()

	http.SetCookie(w, &http.Cookie{
		Name:   "session",
		Value:  "",
		MaxAge: -1,
	})

	http.Redirect(w, r, "/", http.StatusSeeOther)
}
