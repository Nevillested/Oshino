package main

import (
	"database/sql"
	"encoding/json"
	"net/http"
	"strconv"
	"strings"
	"time"
)

// ─────────────────────────────────────────────────────────────────────────────
// Редактирование и удаление сообщений (как в Telegram).
//
// Правила:
//   • редактировать/удалять можно ТОЛЬКО свои сообщения;
//   • редактируется только текст (у картинок/голосовых/звонков текста нет);
//   • удаление — настоящее удаление строки из БД («удалить у всех»). Связи в
//     схеме это выдерживают: реакции уходят каскадом, ответы на удалённое
//     сообщение остаются без цитаты (reply_to_id → NULL), закреп снимается.
//   • об изменении узнают все устройства обеих сторон диалога — через WebSocket.
// ─────────────────────────────────────────────────────────────────────────────

// msgAccess проверяет, что сообщение существует, принадлежит текущему
// пользователю и относится к диалогу с его участием. Возвращает id диалога и
// логин собеседника (кому рассылать обновление).
func (a *App) msgAccess(login string, messageID int) (convID int, otherLogin string, ok bool) {
	var myID int
	if err := a.db.QueryRow(
		"SELECT id FROM messenger.users WHERE LOWER(login) = LOWER($1)", login,
	).Scan(&myID); err != nil {
		return 0, "", false
	}

	var senderID int
	if err := a.db.QueryRow(
		"SELECT conversation_id, sender_id FROM messenger.messages WHERE id = $1", messageID,
	).Scan(&convID, &senderID); err != nil {
		return 0, "", false
	}

	// Только автор может править/удалять своё сообщение
	if senderID != myID {
		return 0, "", false
	}

	var u1, u2 sql.NullInt64
	a.db.QueryRow(
		"SELECT user1_id, user2_id FROM messenger.conversations WHERE id = $1", convID,
	).Scan(&u1, &u2)
	if int64(myID) != u1.Int64 && int64(myID) != u2.Int64 {
		return 0, "", false
	}

	otherID := u1.Int64
	if otherID == int64(myID) {
		otherID = u2.Int64
	}
	a.db.QueryRow("SELECT login FROM messenger.users WHERE id = $1", otherID).Scan(&otherLogin)

	return convID, otherLogin, true
}

// handleEditMessage — POST /edit-message (form: message_id, text).
// Меняет текст своего сообщения и проставляет отметку времени правки,
// чтобы в интерфейсе показывалось «изменено» и после перезагрузки.
func (a *App) handleEditMessage(w http.ResponseWriter, r *http.Request) {
	login := a.getSessionLogin(r)
	if login == "" {
		http.Error(w, "Unauthorized", http.StatusUnauthorized)
		return
	}
	if r.Method != http.MethodPost {
		http.Error(w, "Метод не поддерживается", http.StatusMethodNotAllowed)
		return
	}

	messageID, _ := strconv.Atoi(r.FormValue("message_id"))
	text := strings.TrimSpace(r.FormValue("text"))
	if messageID <= 0 || text == "" {
		http.Error(w, "Bad request", http.StatusBadRequest)
		return
	}

	_, otherLogin, ok := a.msgAccess(login, messageID)
	if !ok {
		http.Error(w, "Нет доступа к этому сообщению", http.StatusForbidden)
		return
	}

	// Редактируем только текстовые сообщения: у медиа и записей о звонках
	// текста нет, править там нечего.
	var hasImage, hasAudio bool
	var callType sql.NullString
	a.db.QueryRow(`
		SELECT (image_data IS NOT NULL), (audio_data IS NOT NULL), call_type
		FROM messenger.messages WHERE id = $1
	`, messageID).Scan(&hasImage, &hasAudio, &callType)
	if hasImage || hasAudio || callType.Valid {
		http.Error(w, "Это сообщение нельзя редактировать", http.StatusBadRequest)
		return
	}

	editedAt := time.Now().UTC()
	if _, err := a.db.Exec(
		"UPDATE messenger.messages SET content = $1, edited_at = $2 WHERE id = $3",
		text, editedAt, messageID,
	); err != nil {
		http.Error(w, "Error", http.StatusInternalServerError)
		return
	}

	a.broadcastMessageEdit(login, otherLogin, messageID, text, editedAt.Format("2006-01-02T15:04:05Z"))

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]interface{}{"success": true})
}

// handleDeleteMessage — POST /delete-message (form: message_id).
// Удаляет своё сообщение у обеих сторон.
func (a *App) handleDeleteMessage(w http.ResponseWriter, r *http.Request) {
	login := a.getSessionLogin(r)
	if login == "" {
		http.Error(w, "Unauthorized", http.StatusUnauthorized)
		return
	}
	if r.Method != http.MethodPost {
		http.Error(w, "Метод не поддерживается", http.StatusMethodNotAllowed)
		return
	}

	messageID, _ := strconv.Atoi(r.FormValue("message_id"))
	if messageID <= 0 {
		http.Error(w, "Bad request", http.StatusBadRequest)
		return
	}

	convID, otherLogin, ok := a.msgAccess(login, messageID)
	if !ok {
		http.Error(w, "Нет доступа к этому сообщению", http.StatusForbidden)
		return
	}

	// Если удаляемое сообщение закреплено — снимаем закреп, чтобы не осталось
	// ссылки в никуда (FK сделает это и сам, но так честнее и понятнее).
	a.db.Exec(
		"UPDATE messenger.conversations SET pinned_message_id = NULL WHERE id = $1 AND pinned_message_id = $2",
		convID, messageID,
	)

	if _, err := a.db.Exec("DELETE FROM messenger.messages WHERE id = $1", messageID); err != nil {
		http.Error(w, "Error", http.StatusInternalServerError)
		return
	}

	a.broadcastMessageDelete(login, otherLogin, messageID)

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]interface{}{"success": true})
}

// broadcastMessageEdit рассылает правку на все устройства обеих сторон.
func (a *App) broadcastMessageEdit(fromLogin, toLogin string, messageID int, text, editedAt string) {
	payload := map[string]interface{}{
		"message_id": messageID,
		"from":       fromLogin,
		"text":       text,
		"edited_at":  editedAt,
	}
	data, _ := json.Marshal(payload)
	a.sendToBoth(fromLogin, toLogin, "editmsg:", data)
}

// broadcastMessageDelete рассылает удаление на все устройства обеих сторон.
func (a *App) broadcastMessageDelete(fromLogin, toLogin string, messageID int) {
	payload := map[string]interface{}{
		"message_id": messageID,
		"from":       fromLogin,
	}
	data, _ := json.Marshal(payload)
	a.sendToBoth(fromLogin, toLogin, "delmsg:", data)
}

// sendToBoth отправляет событие всем активным соединениям обеих сторон диалога.
func (a *App) sendToBoth(fromLogin, toLogin, prefix string, data []byte) {
	a.mu.Lock()
	var targets []*Client
	for _, l := range []string{strings.ToLower(fromLogin), strings.ToLower(toLogin)} {
		for c := range a.clients[l] {
			targets = append(targets, c)
		}
	}
	a.mu.Unlock()

	for _, c := range targets {
		c.trySend(append([]byte(prefix), data...))
	}
}

// ─────────────────────────────────────────────────────────────────────────────
// Пакетное удаление (множественный выбор сообщений)
//
// Два режима:
//   for_all=1 — «удалить у всех»: физическое удаление строки. Разрешено для
//               ЛЮБОГО сообщения диалога — и своего, и собеседника. Единственная
//               проверка — что удаляющий является участником этого диалога.
//   for_all=0 — «удалить только у меня»: строка остаётся, но помечается скрытой
//               лично для меня (таблица message_deletions), собеседник её видит.
// ─────────────────────────────────────────────────────────────────────────────

// handleDeleteMessages — POST /delete-messages (form: message_ids="1,2,3", for_all=0|1)
func (a *App) handleDeleteMessages(w http.ResponseWriter, r *http.Request) {
	login := a.getSessionLogin(r)
	if login == "" {
		http.Error(w, "Unauthorized", http.StatusUnauthorized)
		return
	}
	if r.Method != http.MethodPost {
		http.Error(w, "Метод не поддерживается", http.StatusMethodNotAllowed)
		return
	}

	forAll := r.FormValue("for_all") == "1"
	idsRaw := r.FormValue("message_ids")
	if idsRaw == "" {
		http.Error(w, "Bad request", http.StatusBadRequest)
		return
	}

	var myID int
	if err := a.db.QueryRow(
		"SELECT id FROM messenger.users WHERE LOWER(login) = LOWER($1)", login,
	).Scan(&myID); err != nil {
		http.Error(w, "Error", http.StatusInternalServerError)
		return
	}

	// Ограничение на размер пакета — защита от случайного «удалить всё».
	const maxBatch = 50

	deletedForAll := []int{}
	hiddenForMe := []int{}
	otherLogin := ""

	for i, part := range strings.Split(idsRaw, ",") {
		if i >= maxBatch {
			break
		}
		messageID, err := strconv.Atoi(strings.TrimSpace(part))
		if err != nil || messageID <= 0 {
			continue
		}

		// Проверяем, что сообщение из диалога с участием текущего пользователя
		var convID, senderID int
		if err := a.db.QueryRow(
			"SELECT conversation_id, sender_id FROM messenger.messages WHERE id = $1", messageID,
		).Scan(&convID, &senderID); err != nil {
			continue
		}
		var u1, u2 sql.NullInt64
		a.db.QueryRow(
			"SELECT user1_id, user2_id FROM messenger.conversations WHERE id = $1", convID,
		).Scan(&u1, &u2)
		if int64(myID) != u1.Int64 && int64(myID) != u2.Int64 {
			continue
		}
		if otherLogin == "" {
			otherID := u1.Int64
			if otherID == int64(myID) {
				otherID = u2.Int64
			}
			a.db.QueryRow("SELECT login FROM messenger.users WHERE id = $1", otherID).Scan(&otherLogin)
		}

		if forAll {
			// Удалять у обоих можно любое сообщение диалога — и своё, и
			// собеседника. Проверка участия в диалоге уже выполнена выше,
			// её достаточно: посторонний чужую переписку не тронет.
			_ = senderID
			a.db.Exec(
				"UPDATE messenger.conversations SET pinned_message_id = NULL WHERE id = $1 AND pinned_message_id = $2",
				convID, messageID,
			)
			if _, err := a.db.Exec("DELETE FROM messenger.messages WHERE id = $1", messageID); err == nil {
				deletedForAll = append(deletedForAll, messageID)
			}
		} else {
			if _, err := a.db.Exec(`
				INSERT INTO messenger.message_deletions (message_id, user_id)
				VALUES ($1, $2) ON CONFLICT DO NOTHING
			`, messageID, myID); err == nil {
				hiddenForMe = append(hiddenForMe, messageID)
			}
		}
	}

	// Удаление у всех — событие обеим сторонам.
	for _, id := range deletedForAll {
		a.broadcastMessageDelete(login, otherLogin, id)
	}
	// Скрытие у себя — событие только на МОИ устройства (собеседника не трогаем).
	for _, id := range hiddenForMe {
		payload, _ := json.Marshal(map[string]interface{}{"message_id": id, "from": login})
		a.sendToBoth(login, login, "delmsg:", payload)
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]interface{}{
		"success":         true,
		"deleted_for_all": len(deletedForAll),
		"hidden_for_me":   len(hiddenForMe),
	})
}
