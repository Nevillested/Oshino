package main

import (
	"encoding/json"
	"net/http"
	"strings"
	"time"
)

// ─────────────────────────────────────────────────────────────────────────────
// Действия над диалогом: закрепить, очистить историю, удалить чат.
//
// Логика «у себя / у обоих» такая же, как у сообщений:
//   • закрепление — всегда персональное (у собеседника ничего не меняется);
//   • очистка/удаление без галочки — только у меня, собеседник видит всё как было;
//   • с галочкой — у обоих.
//
// Разница между очисткой и удалением:
//   очистка  — сообщения уходят, диалог остаётся в списке (пустой);
//   удаление — уходит и диалог вместе с сообщениями.
// ─────────────────────────────────────────────────────────────────────────────

// dialogCtx — общие данные для всех действий над диалогом.
type dialogCtx struct {
	myID       int
	myLogin    string
	otherLogin string
	convID     int
}

// resolveDialog проверяет доступ и возвращает контекст диалога с собеседником.
func (a *App) resolveDialog(r *http.Request) (dialogCtx, bool) {
	var d dialogCtx

	d.myLogin = a.getSessionLogin(r)
	if d.myLogin == "" {
		return d, false
	}
	d.otherLogin = strings.TrimSpace(r.FormValue("with"))
	if d.otherLogin == "" {
		return d, false
	}

	if err := a.db.QueryRow(
		"SELECT id FROM messenger.users WHERE LOWER(login) = LOWER($1)", d.myLogin,
	).Scan(&d.myID); err != nil {
		return d, false
	}

	convID, err := a.getOrCreateConversation(d.myLogin, d.otherLogin)
	if err != nil {
		return d, false
	}
	d.convID = convID
	return d, true
}

// refreshDialogsFor рассылает обновлённый список диалогов на все устройства
// перечисленных пользователей (после закрепления/очистки/удаления).
func (a *App) refreshDialogsFor(logins ...string) {
	a.mu.Lock()
	var targets []*Client
	for _, l := range logins {
		for c := range a.clients[strings.ToLower(l)] {
			targets = append(targets, c)
		}
	}
	a.mu.Unlock()

	for _, c := range targets {
		a.sendDialogsTo(c)
	}
}

// notifyDialogChanged сообщает клиентам, что содержимое диалога изменилось,
// чтобы открытый чат перечитал историю (или закрылся при удалении).
func (a *App) notifyDialogChanged(event string, forLogin string, peerLogin string) {
	payload, _ := json.Marshal(map[string]string{"with": peerLogin})

	a.mu.Lock()
	var targets []*Client
	for c := range a.clients[strings.ToLower(forLogin)] {
		targets = append(targets, c)
	}
	a.mu.Unlock()

	for _, c := range targets {
		c.trySend(append([]byte(event), payload...))
	}
}

// handleDialogPin — POST /dialog/pin (form: with, pinned=0|1).
// Закрепление персональное: у собеседника порядок диалогов не меняется.
func (a *App) handleDialogPin(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "Метод не поддерживается", http.StatusMethodNotAllowed)
		return
	}
	d, ok := a.resolveDialog(r)
	if !ok {
		http.Error(w, "Bad request", http.StatusBadRequest)
		return
	}

	pinned := r.FormValue("pinned") == "1"
	if _, err := a.db.Exec(`
		INSERT INTO messenger.dialog_states (user_id, conversation_id, pinned)
		VALUES ($1, $2, $3)
		ON CONFLICT (user_id, conversation_id) DO UPDATE SET pinned = EXCLUDED.pinned
	`, d.myID, d.convID, pinned); err != nil {
		http.Error(w, "Error", http.StatusInternalServerError)
		return
	}

	a.refreshDialogsFor(d.myLogin)

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]interface{}{"success": true, "pinned": pinned})
}

// handleDialogClear — POST /dialog/clear (form: with, for_all=0|1).
// Сообщения удаляются, сам диалог остаётся в списке (пустым).
func (a *App) handleDialogClear(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "Метод не поддерживается", http.StatusMethodNotAllowed)
		return
	}
	d, ok := a.resolveDialog(r)
	if !ok {
		http.Error(w, "Bad request", http.StatusBadRequest)
		return
	}
	forAll := r.FormValue("for_all") == "1"

	if forAll {
		// Снимаем закреп сообщения и физически удаляем всю переписку
		a.db.Exec("UPDATE messenger.conversations SET pinned_message_id = NULL WHERE id = $1", d.convID)
		if _, err := a.db.Exec("DELETE FROM messenger.messages WHERE conversation_id = $1", d.convID); err != nil {
			http.Error(w, "Error", http.StatusInternalServerError)
			return
		}
		a.refreshDialogsFor(d.myLogin, d.otherLogin)
		a.notifyDialogChanged("dialogcleared:", d.myLogin, d.otherLogin)
		a.notifyDialogChanged("dialogcleared:", d.otherLogin, d.myLogin)
	} else {
		// Прячем всю переписку только у себя — строки остаются для собеседника
		if _, err := a.db.Exec(`
			INSERT INTO messenger.message_deletions (message_id, user_id)
			SELECT id, $2 FROM messenger.messages WHERE conversation_id = $1
			ON CONFLICT DO NOTHING
		`, d.convID, d.myID); err != nil {
			http.Error(w, "Error", http.StatusInternalServerError)
			return
		}
		a.refreshDialogsFor(d.myLogin)
		a.notifyDialogChanged("dialogcleared:", d.myLogin, d.otherLogin)
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]interface{}{"success": true})
}

// handleDialogDelete — POST /dialog/delete (form: with, for_all=0|1).
// Диалог пропадает из списка вместе с сообщениями.
func (a *App) handleDialogDelete(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "Метод не поддерживается", http.StatusMethodNotAllowed)
		return
	}
	d, ok := a.resolveDialog(r)
	if !ok {
		http.Error(w, "Bad request", http.StatusBadRequest)
		return
	}
	forAll := r.FormValue("for_all") == "1"

	if forAll {
		// Полное удаление: сначала сообщения, потом сам диалог
		// (внешние ключи на conversations не каскадные — порядок важен).
		a.db.Exec("UPDATE messenger.conversations SET pinned_message_id = NULL WHERE id = $1", d.convID)
		if _, err := a.db.Exec("DELETE FROM messenger.messages WHERE conversation_id = $1", d.convID); err != nil {
			http.Error(w, "Error", http.StatusInternalServerError)
			return
		}
		if _, err := a.db.Exec("DELETE FROM messenger.conversations WHERE id = $1", d.convID); err != nil {
			http.Error(w, "Error", http.StatusInternalServerError)
			return
		}
		a.refreshDialogsFor(d.myLogin, d.otherLogin)
		a.notifyDialogChanged("dialogdeleted:", d.myLogin, d.otherLogin)
		a.notifyDialogChanged("dialogdeleted:", d.otherLogin, d.myLogin)
	} else {
		// Удаление у себя: прячем переписку и сам диалог. При новом сообщении
		// диалог вернётся в список автоматически (см. hidden_at в загрузке).
		a.db.Exec(`
			INSERT INTO messenger.message_deletions (message_id, user_id)
			SELECT id, $2 FROM messenger.messages WHERE conversation_id = $1
			ON CONFLICT DO NOTHING
		`, d.convID, d.myID)

		if _, err := a.db.Exec(`
			INSERT INTO messenger.dialog_states (user_id, conversation_id, hidden_at, pinned)
			VALUES ($1, $2, $3, false)
			ON CONFLICT (user_id, conversation_id)
			DO UPDATE SET hidden_at = EXCLUDED.hidden_at, pinned = false
		`, d.myID, d.convID, time.Now().UTC()); err != nil {
			http.Error(w, "Error", http.StatusInternalServerError)
			return
		}
		a.refreshDialogsFor(d.myLogin)
		a.notifyDialogChanged("dialogdeleted:", d.myLogin, d.otherLogin)
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]interface{}{"success": true})
}
